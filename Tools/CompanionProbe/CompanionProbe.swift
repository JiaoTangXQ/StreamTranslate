import Foundation
import CompanionKit
import Security

/// Runs only with an explicit flag. The loopback suite never uses Bonjour;
/// the separate simulator fixture explicitly advertises synthetic captions.
/// Both use isolated test credentials and never capture audio.
@main enum CompanionProbe {
    @MainActor static func main() async {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--remote-fixture" {
            await runRemoteFixture(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        if CommandLine.arguments.count == 3, ["--web-fixture", "--web-quick-fixture"].contains(CommandLine.arguments[1]) {
            await runWebFixture(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                                transport: CommandLine.arguments[1] == "--web-quick-fixture" ? .trustedLAN : .secure)
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--simulator-fixture" {
            await runSimulatorFixture(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        guard CommandLine.arguments.contains("--loopback") else {
            print("Usage: swift run -c release CompanionProbe --loopback")
            print("Creates isolated test credentials and a loopback-only TLS listener; no audio.")
            print("Or: CompanionProbe --simulator-fixture NEW_PRIVATE_DIRECTORY")
            print("The fixture advertises Bonjour for up to four minutes; synthetic text only.")
            return
        }
        let vault = CompanionVault(service: "com.jiaotangxq.StreamTranslate.companion.probe.\(UUID())")
        let server = CompanionServer(vault: vault)
        let client = CompanionClient(vault: vault)
        var identityID: UUID?
        var failed = false
        do {
            server.start(loopbackOnly: true)
            try await until("TLS server ready", timeout: 12) { server.isRunning }
            guard let port = server.port else { throw ProbeFailure("Missing listener port: \(server.status)") }
            server.createInvitation()
            let invitation = try CompanionInvitation.parse(server.pairingURL)
            identityID = invitation.serverID

            let wrongPinClient = CompanionClient(vault: vault)
            wrongPinClient.useDirectAddress(host: "127.0.0.1", port: port)
            var wrongPin = invitation
            wrongPin.fingerprint = String(repeating: "0", count: 64)
            try wrongPinClient.pair(url: wrongPin.url())
            try await until("Wrong TLS pin rejected", timeout: 12) { wrongPinClient.state == .retrying }
            try require(wrongPinClient.snapshot == nil && !server.isConnected, "Wrong pin received no captions")
            wrongPinClient.pause()

            let wrongTokenClient = CompanionClient(vault: vault)
            wrongTokenClient.useDirectAddress(host: "127.0.0.1", port: port)
            var wrongToken = invitation
            wrongToken.secret = try CompanionSecrets.random()
            try wrongTokenClient.pair(url: wrongToken.url())
            try await until("Wrong invitation rejected", timeout: 12) {
                wrongTokenClient.status.contains("配对已失效")
            }
            try require(wrongTokenClient.snapshot == nil && !server.isConnected, "Unauthorized client received no captions")
            wrongTokenClient.pause()

            client.useDirectAddress(host: "127.0.0.1", port: port)
            try client.pair(url: invitation.url())
            try await until("Secure pairing and initial snapshot", timeout: 12) { client.state == .live && server.isConnected }
            try require(client.negotiatedTLS13, "TLS 1.3 negotiated")
            try require(server.pairingURL.isEmpty, "Invitation consumed")
            let row = CompanionCaption(id: UUID(), timestamp: Date(), original: "Private presentation",
                                       translation: "私密演示", language: "en")
            var snapshot = CompanionSnapshot(captions: [row], status: .listening)
            server.publish(snapshot)
            try await until("Caption delivered") { client.snapshot?.captions.first?.id == row.id }
            snapshot.captions[0].translation = "仅在手机阅读的私密演示"
            server.publish(snapshot)
            try await until("Refinement replaces existing line") {
                client.snapshot?.captions.count == 1 && client.snapshot?.captions.first?.translation == snapshot.captions[0].translation
            }
            for iteration in 1...10 {
                client.pause()
                try require(!client.negotiatedTLS13 && client.snapshot == nil, "Paused client clears live security/text state")
                client.start()
                try await until("Reconnect \(iteration)/10 restores snapshot") {
                    client.state == .live && client.snapshot?.captions.first?.id == row.id
                }
            }
            try await Task.sleep(for: .seconds(18))
            try require(client.state == .live && server.isConnected, "Heartbeat survives 18 seconds without speech")
            snapshot = CompanionSnapshot(status: .stopped)
            server.publish(snapshot)
            try await until("Clear/new session resets phone") {
                client.snapshot?.sessionID == snapshot.sessionID && client.snapshot?.captions.isEmpty == true
            }
            server.revokePairing()
            try await until("Revocation disconnects reader") { client.state == .retrying }
            try require(!client.negotiatedTLS13, "Disconnected client clears negotiated TLS state")
            client.reconnect()
            try await until("Revoked credential cannot reconnect", timeout: 12) {
                client.status.contains("配对已失效")
            }
            try require(!server.isConnected, "No authorized peer after revocation")
        } catch {
            print("FAIL: \(error.localizedDescription); server status: \(server.status)")
            failed = true
        }
        client.pause()
        server.stop()
        // Delete only this run's explicitly named test records and key.
        do {
            try vault.delete(account: "phone-pairing-v1")
            try vault.delete(account: "clients-v1")
            try vault.delete(account: "server-identity-v1")
            if let identityID {
                let label = "StreamTranslate Companion \(identityID.uuidString)"
                let status = SecItemDelete([kSecClass: kSecClassKey,
                    kSecAttrApplicationTag: Data(label.utf8)] as CFDictionary)
                try require(status == errSecSuccess || status == errSecItemNotFound, "Isolated test key cleaned up")
            }
        } catch { print("FAIL cleanup: \(error.localizedDescription)"); failed = true }
        print(failed ? "COMPANION LOOPBACK FAILED" : "COMPANION LOOPBACK PASSED (not an iPhone/Wi-Fi benchmark)")
        exit(failed ? 1 : 0)
    }

    @MainActor private static func until(_ label: String, timeout: Double = 5, condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int(timeout * 1000)))
        while !condition() {
            guard ContinuousClock.now < end else { throw ProbeFailure("Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(25))
        }
        print("PASS: \(label)")
    }
    private static func require(_ value: Bool, _ label: String) throws {
        guard value else { throw ProbeFailure(label) }
        print("PASS: \(label)")
    }
    private struct ProbeFailure: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
