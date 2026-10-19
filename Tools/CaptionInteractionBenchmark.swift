import AppKit
import SwiftUI

/// Synthetic UI-only replay. Does not start capture, load models, or use the
/// app's preferences/log. Run separately for each history size to isolate RSS.
@main
enum CaptionInteractionBenchmark {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor private static func run() async {
        let count = Int(CommandLine.arguments.dropFirst().first ?? "100") ?? 100
        let suite = "StreamTranslate.interaction-bench.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = CaptionViewModel()
        vm.captionHistory = (0..<count).map { index in
            CaptionEntry(timestamp: .distantPast,
                englishText: "Sentence \(index). The next speaker explains how the project works and what we should do next.",
                chineseText: "第\(index)句。下一位发言者介绍项目的运行方式，以及我们接下来应该做什么。")
        }
        vm.isModelReady = true
        vm.isTranslationReady = true
        let panel = FloatingPanel(contentRect: NSRect(x: 80, y: 80, width: 620, height: 300))
        let host = FloatingPanelHostingView(rootView: FloatingCaptionView(onMinimize: {})
            .environment(vm).environment(CaptionSettings(defaults: defaults)))
        let initialStart = CACurrentMediaTime()
        panel.contentView = host
        panel.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let initialMS = (CACurrentMediaTime() - initialStart) * 1000
        try? await Task.sleep(for: .milliseconds(500))

        var resizeMS: [Double] = []
        var hoverMS: [Double] = []
        for index in 0..<20 {
            let start = CACurrentMediaTime()
            panel.setContentSize(NSSize(width: index.isMultiple(of: 2) ? 600 : 620, height: 300))
            host.layoutSubtreeIfNeeded()
            resizeMS.append((CACurrentMediaTime() - start) * 1000)
            let hoverStart = CACurrentMediaTime()
            if let event = NSEvent.mouseEvent(with: .mouseMoved,
                location: NSPoint(x: 100 + index, y: 100), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: index,
                clickCount: 0, pressure: 0) {
                panel.sendEvent(event)
            }
            host.layoutSubtreeIfNeeded()
            hoverMS.append((CACurrentMediaTime() - hoverStart) * 1000)
            try? await Task.sleep(for: .milliseconds(20))
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
        print(String(format: "INTERACTION history=%d initial_ms=%.1f resize_p95_ms=%.1f hover_p95_ms=%.1f",
            count, initialMS, p95(resizeMS), p95(hoverMS)))
        fflush(stdout)
        if CommandLine.arguments.count > 2 {
            let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for width in [620.0, 300.0] {
                    panel.setContentSize(NSSize(width: width, height: 300))
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    if let latest = vm.captionHistory.last?.englishText {
                        let fields = descendants(of: host).compactMap { $0 as? NSTextField }
                        let visible = fields.contains {
                            $0.stringValue == latest && $0.convert($0.bounds, to: host).intersects(host.bounds)
                        }
                        guard visible else {
                            print("FOLLOW FAILED: latest caption not visible after resize to \(width)")
                            throw CocoaError(.validationMissingMandatoryProperty)
                        }
                    }
                    try screenshot(host, to: output.appendingPathComponent("floating-\(Int(width)).png"))
                }
                vm.conversationSummary.isExpanded = true
                // No model is started by this visual fixture. A separate
                // production-service probe verifies actual inference.
                let summary = ConversationSummaryModel { SummaryPreviewProvider() }
                let previewVM = CaptionViewModel(conversationSummary: summary)
                previewVM.captionHistory = vm.captionHistory
                let summaryHost = FloatingPanelHostingView(rootView: FloatingCaptionView(onMinimize: {})
                    .environment(previewVM).environment(CaptionSettings(defaults: defaults)))
                panel.contentView = summaryHost
                summary.isExpanded = true
                summary.generate(sourceRevision: 0) { Array(vm.captionHistory.suffix(4)) }
                for _ in 0..<100 {
                    if !summary.isGenerating { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                for width in [620.0, 300.0] {
                    panel.setContentSize(NSSize(width: width, height: 300))
                    try await Task.sleep(for: .milliseconds(100))
                    try screenshot(summaryHost, to: output.appendingPathComponent("summary-\(Int(width)).png"))
                }
                // The panel stays dark even when the surrounding system is Light.
                panel.appearance = NSAppearance(named: .aqua)
                for state in ["empty", "loading", "streaming", "paused", "error"] {
                    let stateModel = ConversationSummaryModel { SummaryPreviewProvider(state: state) }
                    let stateVM = CaptionViewModel(conversationSummary: stateModel)
                    stateVM.captionHistory = vm.captionHistory
                    if state != "empty" { stateVM.addCaption(english: "Synthetic current conversation.", chinese: "") }
                    let stateHost = FloatingPanelHostingView(rootView: FloatingCaptionView(onMinimize: {})
                        .environment(stateVM).environment(CaptionSettings(defaults: defaults)))
                    panel.contentView = stateHost
                    stateModel.isExpanded = true
                    if state != "empty" {
                        stateModel.generate(sourceRevision: 0) { Array(vm.captionHistory.suffix(4)) }
                    }
                    var ready = false
                    for _ in 0..<200 {
                        switch state {
                        case "loading": ready = stateModel.progress == "正在准备本地 AI…"
                        case "streaming": ready = !stateModel.draftText.isEmpty
                        case "paused": ready = !stateModel.isGenerating && !stateModel.text.isEmpty
                        case "error": ready = stateModel.errorMessage != nil
                        default: ready = true
                        }
                        if ready { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard ready else { throw CocoaError(.validationMissingMandatoryProperty) }
                    if state == "paused" { stateModel.pauseAutomaticUpdates() }
                    try await Task.sleep(for: .milliseconds(100))
                    try screenshot(stateHost, to: output.appendingPathComponent("summary-300-\(state)-light.png"))
                    stateModel.collapse()
                }
                let archiveURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("StreamTranslate.history-preview.\(UUID())")
                defer { try? FileManager.default.removeItem(at: archiveURL) }
                let store = CaptionHistoryStore(directory: archiveURL)
                for index in 0..<2 {
                    let session = UUID()
                    for entry in vm.captionHistory.suffix(130) {
                        store.record(entry, sessionID: session,
                            startedAt: Date().addingTimeInterval(-Double(index) * 3600))
                    }
                }
                try await store.flush()
                let history = NSHostingView(rootView: CaptionHistoryView(store: store).environment(vm))
                let historyWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 820, height: 560),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                historyWindow.isReleasedWhenClosed = false
                historyWindow.appearance = NSAppearance(named: .darkAqua)
                historyWindow.contentView = history
                historyWindow.makeKeyAndOrderFront(nil)
                for (name, size) in [("history-820", NSSize(width: 820, height: 560)),
                                     ("history-640", NSSize(width: 640, height: 400))] {
                    historyWindow.setContentSize(size)
                    var loaded = false
                    for _ in 0..<100 {
                        try await Task.sleep(for: .milliseconds(20))
                        history.layoutSubtreeIfNeeded()
                        loaded = descendants(of: history).compactMap { $0 as? NSTextField }
                            .contains { $0.isSelectable && $0.stringValue.hasPrefix("Sentence ") }
                        if loaded { break }
                    }
                    guard loaded else { throw CocoaError(.validationMissingMandatoryProperty) }
                    try screenshot(history, to: output.appendingPathComponent("\(name).png"))
                }
                vm.clearHistory()
                try await store.clear()
                try await Task.sleep(for: .milliseconds(100))
                try screenshot(history, to: output.appendingPathComponent("history-empty.png"))
                historyWindow.close()
            } catch { print("PREVIEW FAILED: \(error)"); exit(1) }
        }
        panel.orderOut(nil)
        panel.close()
    }

    @MainActor private static func screenshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    @MainActor private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

@MainActor private final class SummaryPreviewProvider: ConversationSummaryProviding {
    let state: String
    init(state: String = "normal") { self.state = state }
    func prepare() async throws {
        if state == "loading" { try await Task.sleep(for: .seconds(60)) }
        if state == "error" { throw SummaryError.modelUnavailable }
    }
    func summarize(_ text: String, previous: String, onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        if state == "streaming" {
            onUpdate("在聊什么\n讨论字幕体验，以及如何更容易跟上对话。\n\n主要内容\n新字幕产生后自动更新总结，生成中的文字逐步显示。")
            try await Task.sleep(for: .seconds(60))
        }
        return "在聊什么\n讨论长时间使用后字幕卡顿，以及如何更容易跟上对话。\n\n主要内容\n悬浮窗只保留100条字幕，完整记录保存在本机。右侧增加可折叠的中文总结，展开时自动更新。静默停字幕的原因仍需排查。"
    }
    func cancel() {}
}
