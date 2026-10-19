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
                previewVM.captionHistory = [
                    CaptionEntry(timestamp: .distantPast, englishText: "We want to give you a little background on who we are and what we do.", chineseText: "我们先介绍一下团队是谁，以及平时在做什么。"),
                    CaptionEntry(timestamp: .distantPast, englishText: "The goal is to show how AI can help with the repetitive work we do every day.", chineseText: "这次想通过具体例子，说明 AI 如何帮助处理每天重复的工作。"),
                    CaptionEntry(timestamp: .distantPast, englishText: "Start with a task you repeat. Then decide which steps would benefit from AI.", chineseText: "先找一项反复做的任务，再判断哪些步骤适合交给 AI。"),
                    CaptionEntry(timestamp: .distantPast, englishText: "The point is to free up your time, so you can focus on work that needs your judgment.", chineseText: "目的是把时间还给你，让你专注于真正需要自己判断的事情。")
                ]
                previewVM.isModelReady = true
                previewVM.isTranslationReady = true
                let summaryHost = FloatingPanelHostingView(rootView: FloatingCaptionView(onMinimize: {})
                    .environment(previewVM).environment(CaptionSettings(defaults: defaults)))
                panel.contentView = summaryHost
                summary.isExpanded = true
                summary.generate(sourceRevision: 0) { Array(vm.captionHistory.suffix(4)) }
                for _ in 0..<100 {
                    if !summary.isGenerating { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                for (width, height) in [(980.0, 420.0), (780.0, 360.0), (620.0, 360.0), (300.0, 360.0), (980.0, 640.0)] {
                    panel.setContentSize(NSSize(width: width, height: height))
                    try await Task.sleep(for: .milliseconds(100))
                    let suffix = "-\(Int(height))"
                    try screenshot(summaryHost, to: output.appendingPathComponent("summary-\(Int(width))\(suffix).png"))
                    if width >= 780 {
                        let fields = descendants(of: summaryHost).compactMap { $0 as? NSTextField }
                        let outlineTexts = Set(summary.map.topics.flatMap(\.branches).flatMap(\.points).map(\.text))
                        guard let point = fields.first(where: { outlineTexts.contains($0.stringValue) }) else {
                            print("FAIL: no selectable outline text in split preview")
                            throw CocoaError(.validationMissingMandatoryProperty)
                        }
                        do {
                            let summaryX = point.convert(point.bounds, to: summaryHost).minX
                            for text in previewVM.captionHistory {
                                for field in fields where field.stringValue == text.englishText || field.stringValue == text.chineseText {
                                    guard field.convert(field.bounds, to: summaryHost).maxX < summaryX else {
                                        throw CocoaError(.validationMissingMandatoryProperty)
                                    }
                                }
                            }
                            print("SPLIT NONOVERLAP width=\(width)")
                        }
                    }
                    if width == 300,
                       let segmented = descendants(of: summaryHost).compactMap({ $0 as? NSSegmentedControl }).first {
                        segmented.selectedSegment = 0
                        _ = segmented.sendAction(segmented.action, to: segmented.target)
                        try await Task.sleep(for: .milliseconds(100))
                        try screenshot(summaryHost, to: output.appendingPathComponent("compact-captions-300.png"))
                        segmented.selectedSegment = 1
                        _ = segmented.sendAction(segmented.action, to: segmented.target)
                    }
                }
                panel.setContentSize(NSSize(width: 300, height: 360))
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
                        case "loading": ready = stateModel.progress.hasPrefix("正在准备脑图服务")
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
                    if state == "streaming" {
                        for width in [980.0, 620.0, 300.0, 980.0, 300.0] {
                            panel.setContentSize(NSSize(width: width, height: 360))
                            try await Task.sleep(for: .milliseconds(40))
                            guard stateModel.isExpanded && stateModel.isGenerating else { throw CocoaError(.validationMissingMandatoryProperty) }
                        }
                        print("REFLOW preserves in-flight summary across wide/compact layouts")
                    }
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
    var state: String
    var backendDescription: String { "AI 脑图 · 云端总结" }
    init(state: String = "normal") { self.state = state }
    func prepare() async throws {
        if state == "loading" { try await Task.sleep(for: .seconds(60)) }
        if state == "error" { throw SummaryError.modelUnavailable }
    }
    func summarize(_ text: String, previous: String, onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        let outline = #"{"topic":"new:1","kind":"advertisement","title":"片头赞助与优惠信息","branch":"优惠","text":"片头介绍赞助商及听众优惠。","sources":[1]}"# + "\n"
            + #"{"topic":"new:2","kind":"discussion","title":"直播的目标","branch":"要点","text":"这场对话先介绍团队与直播目标：通过具体例子，说明 AI 如何减少重复工作，让人把时间留给更有价值的任务。","sources":[1]}"# + "\n"
            + #"{"topic":"new:3","kind":"discussion","title":"AI 如何融入日常工作","branch":"要点","text":"讨论转向实际使用方式。先识别每天重复的环节，再判断哪些步骤适合交给 AI，避免为了使用工具而增加工作。","sources":[1]}"#

        if state == "streaming" {
            onUpdate(outline)
            try await Task.sleep(for: .seconds(60))
        }
        return outline
    }
    func cancel() {}
}
