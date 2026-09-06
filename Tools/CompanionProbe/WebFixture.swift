import Foundation
import CompanionKit
import Darwin

extension CompanionProbe {
    @MainActor static func runWebFixture(directory: URL, transport: WebTransport = .secure) async {
        let vault = CompanionVault(service: "com.jiaotangxq.StreamTranslate.web-fixture.\(UUID())")
        let server = WebCaptionServer(vault: vault)
        let life = WebFixtureLifetime()
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in life.done = true } }
            source.activate(); return source
        }
        var failed = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if transport == .trustedLAN {
                // Deliberately not a decodable HTTPS-client array: quick mode
                // must not read, replace or revoke another transport's vault.
                try vault.save("isolated-https-sentinel", account: "web-clients-v1")
            }
            server.start(port: transport == .secure ? 18445 : 18446, transport: transport)
            for _ in 0..<200 {
                if server.isRunning || life.done { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard server.isRunning else { throw WebError(server.status) }
            if let root = server.rootCertificate {
            let pem = "-----BEGIN CERTIFICATE-----\n" + root.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END CERTIFICATE-----\n"
            try Data(pem.utf8).write(to: directory.appendingPathComponent("root.pem"))
            try root.write(to: directory.appendingPathComponent("root.cer"))
            try server.certificateProfile().write(to: directory.appendingPathComponent("setup.mobileconfig"))
            } else if transport == .secure { throw WebError("Missing test TLS identity") }
            try Data(server.address.utf8).write(to: directory.appendingPathComponent("address.txt"))
            func invitation() throws {
                server.createInvitation()
                try Data(server.pairingURL.utf8).write(to: directory.appendingPathComponent("invitation.txt"))
                try Data(server.pairingCode.utf8).write(to: directory.appendingPathComponent("code.txt"))
            }
            try invitation()
            print("WEB_FIXTURE_READY: \(server.address), synthetic text only; invitation in private directory"); fflush(nil)
            let firstID = UUID()
            let baseline = CompanionSnapshot(captions: [
                .init(id: firstID, timestamp: .now, original: "Your slides stay on the Mac. Your subtitles stay private.", translation: "演示留在电脑，字幕只给自己看。", language: "en"),
                .init(id: UUID(), timestamp: .now, original: "Synthetic test: <script>alert('unsafe')</script>", translation: "这是合成测试，没有录制音频。", language: "en")], status: .listening)
            var snapshot = baseline
            let draftID = UUID()
            var connected = false, lastCommand = "", updatesPaused = false, growingDraft = false, growthStep = 0
            for second in 0..<900 {
                if life.done { break }
                let command = (try? String(contentsOf: directory.appendingPathComponent("command.txt"), encoding: .utf8)) ?? ""
                if command != lastCommand {
                    lastCommand = command
                    switch command.trimmingCharacters(in: .whitespacesAndNewlines) {
                    case "reset": growingDraft = false; snapshot = CompanionSnapshot(captions: baseline.captions, status: .listening); server.revokePairings(); print("WEB_FIXTURE_RESET")
                    case "invite": try invitation(); print("WEB_FIXTURE_INVITATION_RENEWED")
                    case "revoke": server.revokePairings(); print("WEB_FIXTURE_REVOKED")
                    case "new-session": growingDraft = false; snapshot = CompanionSnapshot(status: .listening); print("WEB_FIXTURE_NEW_SESSION")
                    case "long-history":
                        snapshot.captions = (1...20).map { index in
                            .init(id: UUID(), timestamp: .now, original: "Synthetic presentation sentence \(index). Read at your own pace.", translation: "第 \(index) 句合成字幕：演示继续播放，你可以安心回看前面的内容。", language: "en")
                        }
                    case "grow-draft": growingDraft = true; growthStep = 0
                    case "refine": snapshot.captions.firstIndex(where: { $0.id == firstID }).map { snapshot.captions[$0].translation = "完整演示留在电脑，精修字幕仅供自己阅读。" }; print("WEB_FIXTURE_REFINED")
                    case "pause-updates": updatesPaused = true
                    case "resume-updates": updatesPaused = false
                    case "stop": server.stop(); print("WEB_FIXTURE_SERVER_STOPPED")
                    case "start": server.start(port: transport == .secure ? 18445 : 18446, transport: transport); print("WEB_FIXTURE_SERVER_RESTARTED")
                    default: break
                    }
                    fflush(nil)
                }
                if server.isConnected != connected { connected = server.isConnected; print("WEB_FIXTURE_READER_VISIBLE=\(connected)"); fflush(nil) }
                if growingDraft { growthStep += 1 }
                let growth = growingDraft ? String(repeating: "，这段字幕正在连续增长", count: growthStep % 12) : ""
                snapshot.streaming = .init(id: draftID, timestamp: Date(timeIntervalSince1970: 0), original: "Live update \(second)", translation: "实时更新 \(second)\(growth)", language: "en")
                if !updatesPaused { server.publish(snapshot) }
                try await Task.sleep(for: .seconds(1))
            }
        } catch { failed = true; print("WEB_FIXTURE_ERROR: \(error.localizedDescription)") }
        server.stop()
        if transport == .trustedLAN {
            do {
                guard try vault.read(String.self, account: "web-clients-v1") == "isolated-https-sentinel",
                      try vault.read(String.self, account: "web-identity-v1") == nil else {
                    throw WebError("Quick mode modified encrypted credentials or created an identity")
                }
                print("WEB_FIXTURE_QUICK_ISOLATION_PASSED")
            } catch { failed = true; print("WEB_FIXTURE_QUICK_ISOLATION_FAILED") }
        }
        do { try vault.delete(account: "web-clients-v1"); try vault.delete(account: "web-identity-v1") }
        catch { failed = true; print("WEB_FIXTURE_CLEANUP_ERROR") }
        signals.forEach { $0.cancel() }
        print("WEB_FIXTURE_STOPPED: isolated signing key and browser credentials removed")
        exit(failed ? 1 : 0)
    }
}
@MainActor private final class WebFixtureLifetime { var done = false }
