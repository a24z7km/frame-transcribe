import AppKit
import CryptoKit
import Foundation

// Finder custom icons live in file metadata, so app binaries, bundle signatures,
// and existing macOS audio-capture permission identities stay unchanged.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let apps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
for (name, icon, executable) in [("Frame 文字起こし.app", "frame", "Frame"),
                                 ("Frame Live.app", "frame-live", "FrameLive")] {
    let target = apps.appendingPathComponent(name)
    let binary = target.appendingPathComponent("Contents/MacOS/\(executable)")
    let info = target.appendingPathComponent("Contents/Info.plist")
    let beforeBinary = try Data(contentsOf: binary)
    let beforeInfo = try Data(contentsOf: info)
    guard let image = NSImage(contentsOf: root.appendingPathComponent("\(icon).icns")),
          NSWorkspace.shared.setIcon(image, forFile: target.path, options: []) else {
        fatalError("Could not set icon: \(name)")
    }
    guard try Data(contentsOf: binary) == beforeBinary,
          try Data(contentsOf: info) == beforeInfo else {
        fatalError("Unexpected app content change")
    }
    print("Icon set; binary and Info.plist unchanged: \(name)")
}
