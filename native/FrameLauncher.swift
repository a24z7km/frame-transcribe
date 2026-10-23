import AppKit
import Foundation

@MainActor
final class Launcher: NSObject, NSApplicationDelegate {
    var process: Process?
    var project: URL!
    var launchStarted = false
    var requestedMode = "open"
    let address = URL(string: "http://127.0.0.1:18764")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "FrameProjectRoot") as? String else {
            fail("アプリの場所を読み込めませんでした。")
            return
        }
        project = URL(fileURLWithPath: root, isDirectory: true)
        if CommandLine.arguments.contains("--live") { requestedMode = "live" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.beginLaunch() }
    }

    // Accept only the fixed launch command. URL parameters never become paths or commands.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "frame-transcribe" && ["open", "live"].contains($0.host ?? "") && ($0.path.isEmpty || $0.path == "/") && $0.query == nil && $0.fragment == nil && $0.user == nil && $0.password == nil && $0.port == nil }) else { return }
        requestedMode = url.host ?? "open"
        if project != nil { beginLaunch() }
    }

    func beginLaunch() {
        guard !launchStarted else { return }
        launchStarted = true
        Task { await launch() }
    }

    func health() async -> Int {
        var request = URLRequest(url: address.appendingPathComponent("api/health"))
        request.timeoutInterval = 1
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["app"] as? String == "frame-local",
                  value["root"] as? String == project.path else { return -1 }
            return 1
        } catch { return 0 }
    }

    func launch() async {
        if requestedMode == "live" {
            let installed = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Frame Live.app")
            let local = project.appendingPathComponent("native/FrameLive.app")
            let application = FileManager.default.fileExists(atPath: installed.path) ? installed : local
            guard FileManager.default.fileExists(atPath: application.path), NSWorkspace.shared.open(application) else {
                fail("Frame Liveが見つかりません。アプリケーションフォルダを確認してください。")
                return
            }
            NSApplication.shared.terminate(nil)
            return
        }
        let state = await health()
        if state == 1 { openBrowser(); return }
        if state == -1 {
            fail("ポート18764を別のアプリが使っています。以前のFrameをターミナルで起動している場合は、Ctrl+Cで終了してから、このアイコンを開き直してください。")
            return
        }
        let python = project.appendingPathComponent(".venv/bin/python")
        let server = project.appendingPathComponent("server.py")
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: server.path) else {
            fail("Frame本体が見つかりません。元のkoe-memoフォルダは移動せずに残してください。")
            return
        }
        do {
            let runtime = project.appendingPathComponent(".runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
            let log = runtime.appendingPathComponent("launcher.log")
            FileManager.default.createFile(atPath: log.path, contents: Data())
            let output = try FileHandle(forWritingTo: log)
            let child = Process()
            child.executableURL = python
            child.arguments = [server.path, "--no-open"]
            child.currentDirectoryURL = project
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PORT"] = "18764"
            child.environment = environment
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = output
            child.standardError = output
            try child.run()
            try output.close()
            process = child
            for _ in 0..<60 {
                if await health() == 1 { openBrowser(); return }
                if !child.isRunning { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            if child.isRunning { child.terminate() }
            fail("Frameを起動できませんでした。詳しくは元のアプリフォルダの .runtime/launcher.log を確認してください。")
        } catch {
            fail("Frameを起動できませんでした。元のアプリフォルダが利用できるか確認してください。")
        }
    }

    func openBrowser() {
        if NSWorkspace.shared.open(address) {
            NSApplication.shared.terminate(nil)
        } else {
            fail("ブラウザを開けませんでした。http://127.0.0.1:18764 をブラウザで開いてください。")
        }
    }

    func fail(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Frameを開けませんでした"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "閉じる")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}

@main
struct FrameLauncher {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let launcher = Launcher()
        application.delegate = launcher
        withExtendedLifetime(launcher) { application.run() }
    }
}
