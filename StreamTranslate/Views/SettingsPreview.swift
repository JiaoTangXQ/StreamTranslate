import SwiftUI

/// Offscreen native snapshots with isolated preferences; no capture or model loading.
@MainActor enum SettingsPreview {
    static func run(directory: URL) async {
        let suite = "StreamTranslate.settings-preview.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw NSError(domain: "SettingsPreview", code: 1)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settings = CaptionSettings(defaults: defaults)
            settings.audioInputSource = .systemAudio
            let vm = CaptionViewModel()
            for page in SettingsPage.allCases {
                for width in [820.0, 720.0] {
                    let height = width == 820 ? 650.0 : 540.0
                    let window = NSWindow(contentRect: .init(x: -8000, y: -8000, width: width, height: height),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let host = NSHostingView(rootView: SettingsView(initialPage: page).environment(settings).environment(vm))
                    window.contentView = host
                    window.orderFront(nil); window.setFrameOrigin(.init(x: -8000, y: -8000))
                    try await Task.sleep(for: .milliseconds(350))
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        throw NSError(domain: "SettingsPreview", code: 2)
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "SettingsPreview", code: 3)
                    }
                    try data.write(to: directory.appendingPathComponent("\(page.rawValue)-\(Int(width)).png"))
                    window.orderOut(nil); window.close()
                }
            }
            defaults.removePersistentDomain(forName: suite)
            print("SETTINGS PREVIEW: 8 native snapshots; isolated preferences; no audio or model loading")
            exit(0)
        } catch {
            defaults.removePersistentDomain(forName: suite)
            print("SETTINGS PREVIEW FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}
