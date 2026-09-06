import SwiftUI

/// Explicit, synthetic off-screen layout check. Never starts capture, loads
/// models, enables listeners or replaces the running app's preferences/log.
@MainActor enum ReaderControlsPreview {
    static func run(directory: URL) async {
        let suite = "StreamTranslate.reader-preview.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw NSError(domain: "ReaderPreview", code: 1)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let settings = CaptionSettings(defaults: defaults)
            let vm = CaptionViewModel()
            vm.isRecording = true; vm.isModelReady = true; vm.isTranslationReady = true
            vm.streamingEnglish = "Move the pointer to change how you listen."
            vm.streamingChinese = "移动鼠标，就能切换收音方式。"
            for width in [620.0, 300.0] {
                let panel = FloatingPanel(contentRect: NSRect(x: -8000, y: -8000, width: width, height: 220))
                let view = FloatingPanelHostingView(rootView: FloatingCaptionView(onMinimize: {})
                    .environment(vm).environment(settings))
                panel.contentView = view
                panel.orderFront(nil)
                panel.setFrameOrigin(NSPoint(x: -8000, y: -8000))
                for (name, wait) in [("controls", 0.5), ("reading", 3.8)] {
                    try await Task.sleep(for: .seconds(wait))
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "ReaderPreview", code: 2) }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "ReaderPreview", code: 3) }
                    try png.write(to: directory.appendingPathComponent("\(Int(width))-\(name).png"))
                }
                panel.orderOut(nil); panel.close()
            }
            print("READER PREVIEW: synthetic wide/narrow controls and idle screenshots exported")
            defaults.removePersistentDomain(forName: suite)
            exit(0)
        } catch { defaults.removePersistentDomain(forName: suite); print("READER PREVIEW FAILED: \(error.localizedDescription)"); exit(1) }
    }
}
