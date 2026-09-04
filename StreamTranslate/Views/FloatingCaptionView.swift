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
    let original: String
    let translation: String
}

struct FloatingCaptionView: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @Environment(CaptionSettings.self) private var settings
    @State private var autoScrollState = CaptionAutoScrollState()

    let onMinimize: () -> Void

    private static let chineseColor = Color(red: 0.47, green: 0.78, blue: 1.0)
    private static let bottomID = "floating-caption-bottom"

    private var contentRevision: FloatingCaptionContentRevision {
        FloatingCaptionContentRevision(
            historyCount: viewModel.captionHistory.count,
            original: viewModel.streamingOriginalText,
            translation: viewModel.streamingTranslatedText
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                minimizeButton
            }
            .frame(height: 38)
            .padding(.horizontal, 10)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        // All completed captions (scrollable history)
                        ForEach(viewModel.captionHistory) { entry in
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

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .textSelection(.enabled)
                }
                .scrollIndicators(.hidden)
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
                .task {
                    await Task.yield()
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
            minHeight: 104 - FloatingPanel.resizeInteractionInset * 2,
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
        .padding(FloatingPanel.resizeInteractionInset)
    }

    private static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        let tolerance: CGFloat = 8
        return geometry.contentSize.height <= geometry.containerSize.height
            || geometry.visibleRect.maxY >= geometry.contentSize.height - tolerance
    }

    private var minimizeButton: some View {
        Button(action: onMinimize) {
            Image(systemName: "minus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .background(.white.opacity(0.14), in: Circle())
        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        .help("Minimize StreamTranslate to the Dock")
        .accessibilityLabel("Minimize StreamTranslate")
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
