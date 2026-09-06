import Foundation
import CompanionKit

/// Explicit synthetic public-network fixture. Never opens audio, models or app preferences.
@MainActor func runRemoteFixture(directory: URL) async {
    let relay = RemoteCaptionRelay()
    guard relay.configured, !FileManager.default.fileExists(atPath: directory.path) else {
        print("Remote fixture requires configured relay and a new directory"); return
    }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        func write(_ name: String, _ value: String) throws {
            let file = directory.appendingPathComponent(name)
            try Data(value.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        relay.createInvitation(); relay.start()
        let sessionID = UUID(), rowID = UUID()
        var wroteInvitation = false
        for iteration in 0..<180 {
            if (try? String(contentsOf: directory.appendingPathComponent("command.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "stop" { break }
            let row = CompanionCaption(id: rowID, timestamp: Date(timeIntervalSince1970: 0),
                original: "Private subtitles from Mac · test \(iteration / 3)",
                translation: "跨网络加密字幕测试 · \(iteration / 3)\n电脑负责翻译，手机安静地看。", language: "en")
            relay.publish(.init(sessionID: sessionID, captions: [row], status: .listening))
            if !wroteInvitation, !relay.pairingURL.isEmpty {
                try write("invitation.txt", relay.pairingURL); wroteInvitation = true
                print("Remote fixture invitation ready (private file only)")
            }
            try write("connected.txt", relay.isConnected ? "yes" : "no")
            try await Task.sleep(for: .seconds(1))
        }
        relay.stop()
        try await Task.sleep(for: .seconds(2))
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("invitation.txt").path) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("invitation.txt"))
        }
        print("Remote fixture stopped; invitation file removed")
    } catch { relay.stop(); print("Remote fixture failed (no sensitive details logged)") }
}
