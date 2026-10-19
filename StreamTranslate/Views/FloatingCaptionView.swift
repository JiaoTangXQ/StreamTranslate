import SwiftUI

struct CaptionAutoScrollState: Equatable {
    private(set) var shouldFollowContentChanges = true
    private var isUserScrolling = false

    mutating func userScrollBegan() {
        isUserScrolling = true
        shouldFollowContentChanges = false
    }

    mutating func userScrollEnded(isAtBottom: Bool) {
        guard isUserScrolling else { return }
        isUserScrolling = false
        shouldFollowContentChanges = isAtBottom
    }
}

private struct FloatingCaptionContentRevision: Equatable {
    let historyCount: Int
    let historyRevision: Int
    let original: String
    let translation: String
}

struct FloatingCaptionView: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @Environment(CaptionSettings.self) private var settings
    @State private var autoScrollState = CaptionAutoScrollState()
    @State private var controls = CaptionControlsVisibility()
    @State private var interactingWithControls = false
    @State private var viewportSize = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onMinimize: () -> Void
    var onSettings: () -> Void = {}
    var onPhone: () -> Void = {}
    var onHistory: () -> Void = {}
    var onSummaryExpansion: (Bool) -> Void = { _ in }

    private var controlsVisible: Bool {
        controls.isVisible || !viewModel.isRecording || viewModel.isChangingCaptureConfiguration
    }

    private static let chineseColor = Color(red: 0.47, green: 0.78, blue: 1.0)
    private static let bottomID = "floating-caption-bottom"

    private var contentRevision: FloatingCaptionContentRevision {
        FloatingCaptionContentRevision(
            historyCount: viewModel.captionHistory.count,
            historyRevision: viewModel.historyRevision,
            original: viewModel.streamingOriginalText,
            translation: viewModel.streamingTranslatedText
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // The live history is capped at 100 rows. Eager layout of
                    // this bounded slice keeps bottom-following accurate with
                    // variable-height selectable text, including after resize.
                    VStack(alignment: .leading, spacing: 14) {
                        if viewModel.captionHistory.isEmpty && !viewModel.hasStreamingText {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(viewModel.isRecording ? "正在聆听…" : "准备好，听懂眼前的内容")
                                    .font(.headline).foregroundStyle(.white.opacity(0.9))
                                Text(viewModel.statusMessage.isEmpty ? "选择麦克风或电脑音频，点击 ▶ 开始。移动鼠标可随时显示快捷控制。" : viewModel.statusMessage)
                                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        // All completed captions (scrollable history)
                        ForEach(viewModel.floatingCaptionHistory) { entry in
                            let isLatest = entry.id == viewModel.captionHistory.last?.id
                                && !viewModel.hasStreamingText
                            captionPair(
                                english: entry.englishText,
                                chinese: entry.chineseText,
                                sourceLanguage: entry.sourceLanguage,
                                originalOpacity: isLatest ? 0.95 : 0.55,
                                translationOpacity: isLatest ? 0.9 : 0.5
                            )
                            .id(entry.id)
                        }

                        // Current streaming / completed line
                        if viewModel.hasStreamingText {
                            streamingCaptionPair
                            .id("streaming")
                        }

                        // A fixed reading margin avoids covering the newest
                        // line or making the transcript jump as controls fade.
                        Color.clear.frame(height: 52)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                    }
                    .padding(.horizontal, 20)
                    .padding(.trailing, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .textSelection(.enabled)
                }
                .scrollIndicators(.hidden)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
                .onScrollPhaseChange { _, newPhase, context in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        autoScrollState.userScrollBegan()
                    case .idle:
                        autoScrollState.userScrollEnded(
                            isAtBottom: Self.isAtBottom(context.geometry)
                        )
                    case .animating:
                        break
                    }
                }
                .task(id: viewportSize) {
                    await Task.yield()
                    guard !Task.isCancelled, autoScrollState.shouldFollowContentChanges else { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .onChange(of: contentRevision) {
                    Task { @MainActor in
                        await Task.yield()
                        guard autoScrollState.shouldFollowContentChanges else {
                            return
                        }
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(
            minWidth: 300 - FloatingPanel.resizeInteractionInset * 2,
            maxWidth: .infinity,
            minHeight: 144 - FloatingPanel.resizeInteractionInset * 2,
            maxHeight: .infinity
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.85))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            CaptionQuickControls(onEngagement: { interactingWithControls = $0 },
                onSettings: onSettings, onPhone: onPhone, onMinimize: onMinimize,
                onHistory: onHistory)
                .padding(8)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controlsVisible)
        }
        .overlay { ConversationSummaryView() }
        .onChange(of: viewModel.conversationSummary.isExpanded) { _, expanded in
            onSummaryExpansion(expanded)
        }
        .onContinuousHover { phase in if case .active = phase { controls.reveal() } }
        .simultaneousGesture(TapGesture().onEnded { controls.reveal() })
        .onKeyPress(.tab) { controls.reveal(); return .ignored }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                controls.update(keepVisible: interactingWithControls || NSWorkspace.shared.isVoiceOverEnabled)
            }
        }
        .padding(FloatingPanel.resizeInteractionInset)
        // WindowServer ignores fully transparent pixels. Paint the resize
        // inset so a drag on the actual outer edge reaches FloatingPanel.
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.16), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 12, height: 12).padding(7)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        let tolerance: CGFloat = 8
        return geometry.contentSize.height <= geometry.containerSize.height
            || geometry.visibleRect.maxY >= geometry.contentSize.height - tolerance
    }

    private var streamingCaptionPair: some View {
        LiveCaptionTextView(
            original: viewModel.streamingOriginalText,
            stableOriginal: viewModel.streamingStableOriginal,
            draftOriginal: viewModel.streamingDraftOriginal,
            translation: viewModel.streamingTranslatedText,
            originalFontSize: settings.fontSize,
            translationFontSize: settings.fontSize - 1,
            translationColor: Self.chineseColor.opacity(0.9)
        )
    }

    private func captionPair(
        english: String,
        chinese: String,
        sourceLanguage: SpokenLanguage,
        originalOpacity: Double,
        translationOpacity: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if sourceLanguage == .english {
                Text(english)
                    .font(.system(size: settings.fontSize))
                    .foregroundStyle(.white.opacity(originalOpacity))
                    .fixedSize(horizontal: false, vertical: true)
                if !chinese.isEmpty {
                    Text(chinese)
                        .font(.system(size: settings.fontSize - 1))
                        .foregroundStyle(Self.chineseColor.opacity(translationOpacity))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(chinese)
                    .font(.system(size: settings.fontSize))
                    .foregroundStyle(.white.opacity(originalOpacity))
                    .fixedSize(horizontal: false, vertical: true)
                if !english.isEmpty {
                    Text(english)
                        .font(.system(size: settings.fontSize - 1))
                        .foregroundStyle(Self.chineseColor.opacity(translationOpacity))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
