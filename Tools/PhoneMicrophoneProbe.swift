import Foundation
import AppKit
@preconcurrency import Translation
import CompanionKit

/// Fixture for Relay/phone-mac.e2e.mjs: the production Mac path for phone
/// audio (relay client, coordinator, caption pipeline, publisher) against a
/// loopback relay. Uses an isolated keychain service and preferences; never
/// the user's provisioning file, saved room or captured audio.
///   PhoneMicrophoneProbe <http://127.0.0.1:port> <publisher token> <work dir>
@main enum PhoneMicrophoneProbe {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, #available(macOS 26.4, *) else { print("usage: PhoneMicrophoneProbe ORIGIN TOKEN DIR"); exit(2) }
        let directory = URL(fileURLWithPath: args[3], isDirectory: true)
        let vault = CompanionVault(service: "com.jiaotangxq.StreamTranslate.probe.\(UUID().uuidString)")
        defer { try? vault.delete(account: "remote-relay-room") }
        let suite = "StreamTranslate.phone-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CaptionSettings(defaults: defaults)
        settings.recognitionLanguageMode = .automatic
        settings.phoneMicrophoneEnabled = true
        let viewModel = CaptionViewModel()
        viewModel.preloadModel(modelId: settings.selectedModelId)
        for direction in TranslationDirection.allCases {
            let (source, target) = direction == .englishToChinese ? ("en", "zh-Hans") : ("zh-Hans", "en")
            viewModel.translationService.setSession(TranslationSession(installedSource: .init(identifier: source),
                target: .init(identifier: target), preferredStrategy: .lowLatency), for: direction)
            viewModel.translationPreparationSucceeded(direction)
        }
        while !viewModel.isModelReady { try await Task.sleep(for: .milliseconds(100)) }
        print("PROBE model ready: \(settings.selectedModelId)")
        let relay = args[1] == "provisioned"
            // The real provisioning file and public relay, still with an
            // isolated keychain room that is deleted afterwards.
            ? RemoteCaptionRelay(vault: vault)
            : RemoteCaptionRelay(loopbackOrigin: args[1], token: args[2], vault: vault)
        guard relay.configured else { print("PROBE relay not configured"); exit(3) }
        let phone = PhoneMicrophoneCoordinator(relay: relay, viewModel: viewModel, settings: settings)
        let publisher = CompanionCaptionPublisher()
        // The publisher only holds these weakly, as the app delegate owns them.
        let lanServer = CompanionServer(vault: vault), webServer = WebCaptionServer(vault: vault)
        relay.start(); phone.update()
        publisher.start(viewModel: viewModel, server: lanServer, webServer: webServer, remote: relay, phone: phone)
        relay.createInvitation()
        while relay.pairingURL.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        try relay.pairingURL.write(to: directory.appendingPathComponent("invitation.txt"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            let status: [String: Any] = [
                "recording": viewModel.isRecording, "source": viewModel.activeCaptureSource?.rawValue ?? "",
                "phone": phone.state.rawValue, "paired": relay.pairedDeviceCount,
                "captions": viewModel.captionHistory.map { ["original": $0.originalText, "translation": $0.translatedText] }
            ]
            try JSONSerialization.data(withJSONObject: status).write(to: directory.appendingPathComponent("status.json"))
            if (try? String(contentsOf: directory.appendingPathComponent("command.txt"), encoding: .utf8)) == "stop" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        publisher.stop(); phone.stop(); relay.stop()
        withExtendedLifetime((lanServer, webServer)) {}
        if viewModel.isRecording { viewModel.stopCapture(gracefully: false) }
        print("PROBE finished")
        exit(0)
    }
}
