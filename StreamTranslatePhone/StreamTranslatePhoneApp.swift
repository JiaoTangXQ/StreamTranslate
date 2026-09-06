import SwiftUI
import CompanionKit

@main
struct StreamTranslatePhoneApp: App {
    @State private var client: CompanionClient

    init() {
        // Deterministic UI tests only on a simulator Debug build. Never reset
        // preferences or Keychain on a physical device or in a release build.
        #if DEBUG && targetEnvironment(simulator)
        let reset = CommandLine.arguments.contains("--ui-testing-reset")
        if reset, let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        #endif
        let client = CompanionClient()
        #if DEBUG && targetEnvironment(simulator)
        if reset { try? client.forget() }
        #endif
        _client = State(initialValue: client)
    }
    var body: some Scene {
        WindowGroup { CompanionReaderView(client: client) }
    }
}
