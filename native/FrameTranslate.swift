import AppKit
import SwiftUI
import Translation
import Foundation

struct TranslationInput: Decodable { let chunks: [String] }

func emit(_ event: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: event), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

@MainActor
struct TranslationView: View {
    let chunks: [String]
    @State private var started = false
    @State private var message = "初回は英語・日本語のダウンロードを許可してください。"
    @State private var configuration: TranslationSession.Configuration? = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ja"))

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Frame · Mac内で翻訳").font(.title2).bold()
            Text(message).font(.body)
            ProgressView().controlSize(.small)
            Text("英文を外部の翻訳サービスへ送信しません。\n言語モデルの取得後は、ネット接続なしで使えます。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(30).frame(width: 440, height: 220)
        .translationTask(configuration) { session in
            guard !started else { return }
            started = true
            do {
                emit(["state": "preparing", "message": "Apple翻訳を準備しています。初回は別ウィンドウで言語のダウンロードを許可してください。"])
                try await session.prepareTranslation()
                // prepareTranslation may return while language assets are still downloading.
                let availability = LanguageAvailability()
                var ready = false
                for attempt in 0..<600 {
                    let status = await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ja"))
                    if status == .installed { ready = true; break }
                    if status == .unsupported { break }
                    if attempt == 0 {
                        message = "言語モデルをダウンロードしています。完了までお待ちください。"
                        emit(["state": "preparing", "message": "英語・日本語モデルをダウンロードしています。Macの準備画面で進捗を確認できます。"])
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard ready else { throw NSError(domain: "FrameTranslate.ModelsNotReady", code: 4) }
                message = "Mac内で日本語に翻訳しています…"
                emit(["state": "translating", "message": "Mac内で日本語に翻訳しています"])
                var translated = Array(repeating: "", count: chunks.count)
                var completed = 0
                // Keep batches bounded while preserving source order via identifiers.
                for base in stride(from: 0, to: chunks.count, by: 12) {
                    let end = min(base + 12, chunks.count)
                    let requests = (base..<end).map { TranslationSession.Request(sourceText: chunks[$0], clientIdentifier: String($0)) }
                    for try await response in session.translate(batch: requests) {
                        guard let id = response.clientIdentifier, let index = Int(id), translated.indices.contains(index), !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw NSError(domain: "FrameTranslate", code: 2)
                        }
                        if translated[index].isEmpty { completed += 1 }
                        translated[index] = response.targetText
                        // Only expose the contiguous prefix, never reorder incomplete batches.
                        let prefix = translated.prefix(while: { !$0.isEmpty }).joined(separator: "\n\n")
                        emit(["state": "translating", "text": prefix, "completed": completed, "total": chunks.count,
                              "progress": chunks.isEmpty ? 100 : Int(Double(completed) / Double(chunks.count) * 100)])
                    }
                }
                guard completed == chunks.count else { throw NSError(domain: "FrameTranslate", code: 3) }
                emit(["state": "done", "text": translated.joined(separator: "\n\n"), "progress": 100,
                      "completed": completed, "total": chunks.count, "message": chunks.isEmpty ? "翻訳モデルの準備ができました。" : "日本語への翻訳が完了しました。"])
                NSApplication.shared.terminate(nil)
            } catch {
                emit(["state": "error", "message": "Apple翻訳を完了できませんでした。言語モデルのダウンロードを確認し、もう一度お試しください。"])
                fputs("\(error)\n", stderr)
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let chunks: [String]
    init(chunks: [String]) { self.chunks = chunks }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Frame — Apple翻訳"
        window.contentView = NSHostingView(rootView: TranslationView(chunks: chunks))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FrameTranslate {
    @MainActor static func main() {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let input = try JSONDecoder().decode(TranslationInput.self, from: data)
            guard input.chunks.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 2000 }) else {
                throw NSError(domain: "FrameTranslate", code: 1)
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = AppDelegate(chunks: input.chunks)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            emit(["state": "error", "message": "翻訳データを読み込めませんでした。"])
            exit(1)
        }
    }
}
