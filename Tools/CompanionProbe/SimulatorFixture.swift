import Foundation
import CompanionKit
import Darwin

extension CompanionProbe {
    /// Explicit development fixture for the actual iPhone simulator app.
    /// Uses normal Bonjour, pinned TLS and one-time pairing, not a mock client
    /// or a way around authentication. No real transcripts or audio are read.
    @MainActor static func runSimulatorFixture(directory: URL) async {
        let vault = CompanionVault(service: "com.jiaotangxq.StreamTranslate.simulator-fixture.\(UUID())")
        let server = CompanionServer(vault: vault)
        let lifetime = FixtureLifetime()
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in lifetime.finished = true } }
            source.activate()
            return source
        }
        var failed = false
        do {
            // Must be a new directory. Invitation secrets remain inside a
            // private folder and are never printed to stdout.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            server.start()
            for _ in 0..<200 {
                if server.isRunning || lifetime.finished { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard server.isRunning else { throw FixtureError("Fixture server did not start: \(server.status)") }
            server.createInvitation()
            guard !server.pairingURL.isEmpty else { throw FixtureError("No invitation") }
            try Data(server.pairingURL.utf8).write(to: directory.appendingPathComponent("invitation.txt"), options: .atomic)
            print("FIXTURE_READY: synthetic captions, Bonjour/TLS, private invitation file, maximum 240 seconds")
            fflush(nil)
            let rows = [
                CompanionCaption(id: UUID(), timestamp: .now,
                                 original: "The presentation stays on the Mac. Subtitles appear only on your phone.",
                                 translation: "演示内容留在电脑上，翻译字幕只在手机上显示。", language: "en"),
                CompanionCaption(id: UUID(), timestamp: .now,
                                 original: "This is a synthetic development check. No audio is being recorded.",
                                 translation: "这是合成字幕开发测试，没有录制任何音频。", language: "en")
            ]
            var snapshot = CompanionSnapshot(captions: rows, status: .listening)
            let draftID = UUID()
            var wasConnected = false
            for second in 0..<240 {
                if lifetime.finished { break }
                if server.isConnected != wasConnected {
                    wasConnected = server.isConnected
                    print(wasConnected ? "FIXTURE_CONNECTED" : "FIXTURE_DISCONNECTED")
                    fflush(nil)
                }
                if second == 60 {
                    snapshot = CompanionSnapshot(captions: [CompanionCaption(id: UUID(), timestamp: .now,
                        original: "A new meeting starts here. Previous meeting captions are cleared.",
                        translation: "这里开始新一场会议，上一场字幕已清空。", language: "en")], status: .listening)
                    print("FIXTURE_NEW_SESSION")
                    fflush(nil)
                }
                snapshot.streaming = CompanionCaption(id: draftID, timestamp: Date(timeIntervalSince1970: 0),
                    original: "Live connection check \(second + 1)", translation: "实时连接检查 \(second + 1)", language: "en")
                if second == 20 {
                    snapshot.captions[0].translation = "演示内容完整保留在电脑上，翻译字幕仅供你在手机上阅读。"
                    print("FIXTURE_REFINED_SAME_ROW")
                }
                server.publish(snapshot)
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            print("FIXTURE_ERROR: \(error.localizedDescription)")
            failed = true
        }
        server.stop()
        do {
            try vault.delete(account: "clients-v1")
            try vault.delete(account: "server-identity-v1")
        } catch { print("FIXTURE_CLEANUP_ERROR: \(error.localizedDescription)"); failed = true }
        signals.forEach { $0.cancel() }
        print("FIXTURE_STOPPED: listener closed, isolated credentials removed; invitation is no longer usable")
        exit(failed ? 1 : 0)
    }
}

@MainActor private final class FixtureLifetime { var finished = false }
private struct FixtureError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
