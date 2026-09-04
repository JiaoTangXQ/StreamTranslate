import AppKit
import SwiftUI
import Testing
@testable import StreamTranslate

@Test @MainActor func liveCaptionReservesSpaceWhileTranslationIsPending() {
    let pending = measuredHeight(translation: "")
    let translated = measuredHeight(translation: "这是稳定的一行翻译。")

    #expect(abs(pending - translated) < 1)
}

@Test func captionAutoScrollPausesForHistoryAndResumesAtBottom() {
    var state = CaptionAutoScrollState()

    #expect(state.shouldFollowContentChanges)

    state.userScrollBegan()
    #expect(!state.shouldFollowContentChanges)
    state.userScrollEnded(isAtBottom: false)
    #expect(!state.shouldFollowContentChanges)

    state.userScrollBegan()
    state.userScrollEnded(isAtBottom: true)
    #expect(state.shouldFollowContentChanges)
}

@Test @MainActor func mainTranscriptExposesSelectionToAccessibility() throws {
    let suiteName = "MainTranscriptSelectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let viewModel = CaptionViewModel()
    viewModel.captionHistory = [
        CaptionEntry(
            timestamp: Date(),
            englishText: "Select this sentence",
            chineseText: "选择这个句子"
        )
    ]
    let settings = CaptionSettings(defaults: defaults)
    let hostingView = NSHostingView(
        rootView: MainWindowView()
            .environment(viewModel)
            .environment(settings)
            .frame(width: 600, height: 500)
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()

    let sourceField = try #require(
        allSubviews(of: hostingView)
            .compactMap { $0 as? NSTextField }
            .first { $0.isSelectable && $0.stringValue == "Select this sentence" }
    )
    #expect(window.makeFirstResponder(sourceField))
    sourceField.selectText(nil)
    let editor = try #require(sourceField.currentEditor() as? NSTextView)
    editor.setSelectedRange(NSRange(location: 0, length: 6))

    #expect(editor.accessibilitySelectedText() == "Select")
}

@MainActor
private func measuredHeight(translation: String) -> CGFloat {
    let view = LiveCaptionTextView(
        original: "The caption remains in the same place.",
        stableOriginal: "The caption remains ",
        draftOriginal: "in the same place.",
        translation: translation,
        originalFontSize: 15,
        translationFontSize: 14,
        translationColor: .cyan
    )
    .frame(width: 420, alignment: .leading)

    let hostingView = NSHostingView(rootView: view)
    hostingView.layoutSubtreeIfNeeded()
    return hostingView.fittingSize.height
}

@MainActor
private func allSubviews(of root: NSView) -> [NSView] {
    root.subviews + root.subviews.flatMap { allSubviews(of: $0) }
}
