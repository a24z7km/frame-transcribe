import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import Translation
import Foundation
import Darwin

struct Caption: Identifiable {
    let id: UUID
    let run: UUID
    let english: String
    var japanese: String = "翻訳中…"
}
struct TranslationItem { let id: UUID; let run: UUID; let english: String }
struct BrowserChoice: Identifiable { let id: String; let name: String }

final class SpeechWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var input: FileHandle?
    private var child: Process?
    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?

    func start(root: URL) throws {
        let process = Process(), source = Pipe(), output = Pipe()
        process.executableURL = root.appendingPathComponent(".venv/bin/python")
        process.arguments = [root.appendingPathComponent("live_worker.py").path]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        process.standardInput = source
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        lock.lock(); child = process; input = source.fileHandleForWriting; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            let handle = output.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]
                    if let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                        self?.onEvent?(event)
                    }
                    buffer.removeSubrange(...end)
                }
                if buffer.count > 1_048_576 { break }
            }
            try? handle.close()
            process.waitUntilExit()
            self?.onExit?(process.terminationStatus)
        }
    }
    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let input else { return }
        try? input.write(contentsOf: data)
    }
    func finishInput() {
        lock.lock(); defer { lock.unlock() }
        try? input?.close(); input = nil
    }
    func stop() {
        lock.lock()
        let process = child
        try? input?.close(); input = nil; child = nil
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
    deinit { stop() }
}

final class AudioSink: NSObject, SCStreamOutput {
    var onAudio: ((Data, Double) -> Void)?
    var onError: (() -> Void)?
    private var warned = false
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid, let description = sample.formatDescription,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return }
        guard format.pointee.mSampleRate == 16000,
              format.pointee.mBitsPerChannel == 32,
              format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            if !warned { warned = true; onError?() }; return
        }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size >= MemoryLayout<AudioBufferList>.size else { return }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &retained)
        guard status == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channels = Int(format.pointee.mChannelsPerFrame)
        guard channels > 0, !buffers.isEmpty else { return }
        var mono = [Float](repeating: 0, count: frames)
        if buffers.count == 1, let data = buffers[0].mData {
            guard Int(buffers[0].mDataByteSize) >= frames * channels * 4 else { return }
            let values = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += values[i * channels + channel] }
                mono[i] = sum / Float(channels)
            }
        } else {
            guard buffers.count >= channels else { return }
            for channel in 0..<channels {
                guard let data = buffers[channel].mData, Int(buffers[channel].mDataByteSize) >= frames * 4 else { return }
                let values = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { mono[i] += values[i] / Float(channels) }
            }
        }
        let rms = sqrt(mono.reduce(0.0) { $0 + Double($1 * $1) } / Double(frames))
        mono.withUnsafeBytes { onAudio?(Data($0), rms) }
    }
}

@MainActor
final class LiveModel: NSObject, ObservableObject, SCStreamDelegate {
    @Published var captions: [Caption] = []
    @Published var status = "準備中…"
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var translationReady = false
    @Published var elapsed = 0
    @Published var level = 0.0
    @Published var selectedBrowser = "com.google.Chrome"
    @Published var browsers: [BrowserChoice] = []
    @Published var error = false
    @Published var testMode = false
    @Published var permissionReady = CGPreflightScreenCaptureAccess()
    let root: URL
    var run = UUID()
    var speech: SpeechWorker?
    var capture: SCStream?
    var sink: AudioSink?
    var chosenFilter: SCContentFilter?
    var timer: Timer?
    var startedAt: Date?
    var translations: AsyncStream<TranslationItem>!
    var translationContinuation: AsyncStream<TranslationItem>.Continuation!
    private var lastLevel = Date.distantPast
    private var testFile: URL?
    private var autoTestStarted = false

    init(root: URL, testFile: URL?) {
        self.root = root; self.testFile = testFile; self.testMode = testFile != nil
        super.init()
        translations = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { translationContinuation = $0 }
        refreshBrowsers()
    }
    func refreshBrowsers() {
        let known: [String: String] = ["com.google.Chrome":"Google Chrome", "com.apple.Safari":"Safari", "com.microsoft.edgemac":"Microsoft Edge", "company.thebrowser.Browser":"Arc", "com.brave.Browser":"Brave"]
        browsers = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let name = known[id] else { return nil }
            return BrowserChoice(id: id, name: name)
        }.sorted { $0.name < $1.name }
        if !browsers.contains(where: { $0.id == selectedBrowser }), let first = browsers.first { selectedBrowser = first.id }
    }
    func ready() {
        translationReady = true
        status = "開始すると、選んだブラウザの英語音声を日本語に翻訳します。"
        if testFile != nil && !autoTestStarted { autoTestStarted = true; start() }
    }
    func start() {
        guard !isRunning && !isStarting && translationReady else { return }
        guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(".venv/bin/python").path) else {
            setError("音声認識の実行環境が見つかりません。"); return
        }
        run = UUID(); isStarting = true; error = false; elapsed = 0
        status = testMode ? "テスト音声で動作確認しています…" : "音声取得を準備しています…"
        let current = run
        Task {
            do {
                if !testMode {
                    permissionReady = CGPreflightScreenCaptureAccess()
                    guard permissionReady else {
                        isStarting = false
                        status = "初回は「音声取得を許可」からMacの権限を設定してください。"
                        return
                    }
                    let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let display = available.displays.first,
                          let browser = available.applications.first(where: { $0.bundleIdentifier == selectedBrowser }) else {
                        throw NSError(domain: "FrameLive.BrowserNotFound", code: 1)
                    }
                    chosenFilter = SCContentFilter(display: display, including: [browser], exceptingWindows: [])
                }
                guard run == current else { return }
                let worker = SpeechWorker()
                worker.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event, run: current) } }
                worker.onExit = { [weak self] code in Task { @MainActor in self?.workerEnded(code, run: current) } }
                speech = worker
                status = "軽量な英語モデルを読み込んでいます…"
                try worker.start(root: root)
            } catch {
                if run == current { setError("音声取得を開始できません。ブラウザを開き、Macの音声取得権限を確認してください。") }
            }
        }
    }
    func handle(_ event: [String: Any], run current: UUID) {
        guard current == run else { return }
        switch event["type"] as? String {
        case "ready": Task { await beginAudio(run: current) }
        case "transcript":
            guard let english = event["english"] as? String, !english.isEmpty else { return }
            let entry = Caption(id: UUID(), run: current, english: english)
            captions.append(entry)
            if captions.count > 600 { captions.removeFirst(captions.count - 600) }
            let yielded = translationContinuation.yield(TranslationItem(id: entry.id, run: current, english: english))
            if case .dropped(let dropped) = yielded {
                setJapanese(id: dropped.id, text: "翻訳が追いつかなかったため、この区間は英語のみです。")
            }
            if isRunning { status = "英語を認識・翻訳しています" }
        case "lag": status = event["message"] as? String ?? "音声処理が遅れています。"
        case "error": setError(event["message"] as? String ?? "音声認識を続けられません。")
        case "finished": if testMode { status = "テスト音声の処理が完了しました。" }
        default: break
        }
    }
    func beginAudio(run current: UUID) async {
        guard current == run && isStarting else { return }
        do {
            if let file = testFile {
                isRunning = true; isStarting = false; beginTimer()
                status = "テスト音声を処理しています（マイク・ブラウザ音声は未取得）"
                feedTestFile(file, run: current)
                return
            }
            guard let filter = chosenFilter else { throw NSError(domain: "FrameLive.Filter", code: 2) }
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.captureMicrophone = false
            configuration.sampleRate = 16000
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true
            configuration.width = 2; configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let sink = AudioSink()
            sink.onAudio = { [weak self, weak worker = speech] data, rms in
                worker?.write(data)
                Task { @MainActor in
                    guard let self, self.run == current else { return }
                    if Date().timeIntervalSince(self.lastLevel) > 0.15 {
                        self.level = min(1, rms * 12); self.lastLevel = Date()
                    }
                }
            }
            sink.onError = { [weak self] in Task { @MainActor in self?.setError("音声形式が対応範囲外です。停止して、ブラウザを開き直してください。") } }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "local.frame.live.audio", qos: .userInitiated))
            self.sink = sink; capture = stream
            try await stream.startCapture()
            guard current == run && isStarting else { try? await stream.stopCapture(); return }
            isRunning = true; isStarting = false; beginTimer()
            status = "音声を待っています。DMM英会話の音声を再生してください。"
        } catch {
            if current == run { setError("ブラウザの音声を取得できません。Macの「画面とシステムオーディオの収録」を確認してください。") }
        }
    }
    func feedTestFile(_ file: URL, run current: UUID) {
        guard let worker = speech else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let decoder = Process(), pipe = Pipe()
            decoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            decoder.arguments = ["-nostdin", "-v", "error", "-i", file.path, "-vn", "-f", "f32le", "-ac", "1", "-ar", "16000", "-"]
            decoder.standardOutput = pipe; decoder.standardError = FileHandle.nullDevice
            do {
                try decoder.run()
                while let data = try pipe.fileHandleForReading.read(upToCount: 6400), !data.isEmpty {
                    worker.write(data)
                    usleep(100_000)
                }
                decoder.waitUntilExit()
            } catch {}
            worker.finishInput()
        }
    }
    func beginTimer() {
        startedAt = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, let date = self.startedAt else { return }; self.elapsed = Int(Date().timeIntervalSince(date)) }
        }
    }
    func workerEnded(_ code: Int32, run current: UUID) {
        guard current == run else { return }
        speech = nil
        if testMode { isRunning = false; isStarting = false; timer?.invalidate(); return }
        if isRunning || isStarting { setError("音声認識が停止しました。「開始」で再開できます。") }
    }
    func stop() {
        isRunning = false; isStarting = false; level = 0
        timer?.invalidate(); timer = nil
        let stream = capture; capture = nil; sink = nil; chosenFilter = nil
        if let stream { Task { try? await stream.stopCapture() } }
        speech?.stop(); speech = nil
        if !error { status = "停止中 · 音声は保存していません。" }
    }
    func setError(_ text: String) { error = true; stop(); status = text }
    func setJapanese(id: UUID, text: String) {
        if let index = captions.firstIndex(where: { $0.id == id }) { captions[index].japanese = text }
    }
    func permitAudio() {
        // Called only from the user's explicit permission button.
        if CGPreflightScreenCaptureAccess() { status = "音声取得の権限は許可されています。「開始」を押してください。"; return }
        permissionReady = CGRequestScreenCaptureAccess()
        status = "Macの設定でFrame Liveの音声取得を許可し、必要ならアプリを開き直してください。"
    }
    func copyCaptions() {
        let text = captions.map { "\($0.english)\n\($0.japanese)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.capture === stream else { return }
            self.setError("音声の取得が停止しました。共有許可とブラウザの状態を確認してください。")
        }
    }
}

struct LiveView: View {
    @ObservedObject var model: LiveModel
    @AppStorage("FrameLiveFontSize") private var fontSize: Double = 18
    @State private var showOptions = false
    @State private var configuration: TranslationSession.Configuration? = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ja"))
    private let green = Color(red: 0.17, green: 0.31, blue: 0.25)
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(green)
                Text("Frame Live").font(.system(size: 15, weight: .semibold))
                Text("DMM英会話").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%02d:%02d / 25:00", model.elapsed / 60, model.elapsed % 60)).monospacedDigit().font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 12)
            HStack(spacing: 10) {
                Picker("音声元", selection: $model.selectedBrowser) {
                    ForEach(model.browsers) { browser in Text(browser.name).tag(browser.id) }
                }.labelsHidden().frame(maxWidth: 160).disabled(model.isRunning || model.isStarting)
                Button { model.refreshBrowsers() } label: { Image(systemName: "arrow.clockwise") }.help("起動中のブラウザを更新").disabled(model.isRunning || model.isStarting)
                Spacer()
                Button(model.isRunning || model.isStarting ? "停止" : "開始") {
                    if model.isRunning || model.isStarting { model.stop() } else { model.start() }
                }.buttonStyle(.borderedProminent).tint(green).disabled(!model.translationReady)
                if !model.permissionReady && !model.testMode {
                    Button("音声取得を許可…") { model.permitAudio() }.font(.system(size: 10))
                }
                Button { fontSize = max(14, fontSize - 2) } label: {
                    Image(systemName: "textformat.size.smaller")
                }.help("文字を小さく").accessibilityLabel("文字を小さく").disabled(fontSize <= 14)
                Button { fontSize = min(26, fontSize + 2) } label: {
                    Image(systemName: "textformat.size.larger")
                }.help("文字を大きく").accessibilityLabel("文字を大きく").disabled(fontSize >= 26)
                Button { showOptions.toggle() } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("その他の操作")
                    .popover(isPresented: $showOptions) {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("音声取得を許可…") { showOptions = false; model.permitAudio() }
                            Button("表示した会話をコピー") { model.copyCaptions(); showOptions = false }
                                .disabled(model.captions.isEmpty)
                        }.padding(16)
                    }
            }.padding(.horizontal, 18).padding(.bottom, 11)
            HStack(spacing: 8) {
                Circle().fill(model.error ? Color.orange : (model.isRunning ? green : Color.gray.opacity(0.4))).frame(width: 6, height: 6)
                Text(model.status).font(.system(size: 10)).foregroundStyle(model.error ? Color.orange : Color.secondary).lineLimit(3)
                Spacer(minLength: 0)
                ProgressView(value: model.level).frame(width: 42).tint(green)
            }.padding(.horizontal, 18).padding(.bottom, 10)
            Divider()
            if model.captions.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "captions.bubble").font(.system(size: 30, weight: .light)).foregroundStyle(green.opacity(0.6))
                    Text("英語を聞いて、日本語で確かめる。").font(.system(size: 16, weight: .medium))
                    Text("相手の英語が上に、日本語訳が下に表示されます。\n開始前に「…」→「音声取得を許可」を設定してください。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(model.captions.suffix(30)) { caption in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(caption.english).font(.system(size: max(12, fontSize - 3))).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text(caption.japanese).font(.system(size: fontSize, weight: .medium)).foregroundStyle(green).textSelection(.enabled).lineSpacing(4)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(caption.id)
                            }
                            Color.clear.frame(height: 1).id("live-bottom")
                        }.padding(20)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                                // Translation and font changes also alter the content height.
                                // Follow after layout, when the new bottom position exists.
                                proxy.scrollTo("live-bottom", anchor: .bottom)
                            }
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: model.captions.last?.id) { _, _ in
                        proxy.scrollTo("live-bottom", anchor: .bottom)
                    }
                }
            }
            Divider()
            HStack {
                Text(model.testMode ? "テスト音声 · 実際の通話音声は取得していません" : "Mac内で処理 · マイク・画面映像・音声ファイルの保存なし").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("常に手前").font(.system(size: 9)).foregroundStyle(green)
            }.padding(.horizontal, 18).padding(.vertical, 10)
            if !model.testMode {
                Text("選んだブラウザ全体が音声元です。ほかのタブの音声は止めてください。")
                    .font(.system(size: 9)).foregroundStyle(.secondary).padding(.bottom, 10)
            }
        }
        .background(Color(red: 0.97, green: 0.98, blue: 0.95))
        .frame(minWidth: 420, minHeight: 300)
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                let availability = LanguageAvailability()
                var installed = false
                for _ in 0..<600 {
                    if await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ja")) == .installed { installed = true; break }
                    model.status = "英語・日本語モデルのダウンロード完了を待っています…"
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard installed else { throw NSError(domain: "FrameLive.Models", code: 1) }
                model.ready()
                for await item in model.translations {
                    guard item.run == model.run else { continue }
                    do {
                        let translated = try await session.translate(item.english)
                        model.setJapanese(id: item.id, text: translated.targetText)
                    } catch {
                        model.setJapanese(id: item.id, text: "翻訳できませんでした。上の英文を確認してください。")
                    }
                }
            } catch {
                model.translationReady = false
                model.setError("Apple翻訳を準備できませんでした。言語モデルを確認して開き直してください。")
            }
        }
    }
}

final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LiveDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: CaptionPanel?
    var model: LiveModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "FrameProjectRoot") as? String else { NSApp.terminate(nil); return }
        let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--test-audio=") })
        let testFile = argument.map { URL(fileURLWithPath: String($0.dropFirst("--test-audio=".count))) }
        let model = LiveModel(root: URL(fileURLWithPath: path), testFile: testFile)
        self.model = model
        let panel = CaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 410), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Frame Live — DMM英会話"
        panel.appearance = NSAppearance(named: .aqua)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 320)
        panel.contentView = NSHostingView(rootView: LiveView(model: model).environment(\.colorScheme, .light))
        panel.delegate = self
        panel.center(); panel.orderFrontRegardless()
        self.panel = panel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}

@main
struct FrameLive {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = LiveDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
