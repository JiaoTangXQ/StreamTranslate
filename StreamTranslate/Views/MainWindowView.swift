import SwiftUI

struct MainWindowView: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @Environment(CaptionSettings.self) private var settings
    @State private var autoScrollState = CaptionAutoScrollState()
    private static let transcriptBottomID = "main-transcript-bottom"

    var body: some View {
        @Bindable var vm = viewModel
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcriptList
        }
        .frame(minWidth: 500, minHeight: 300)
        .preferredColorScheme(.dark)
    }

    private var toolbar: some View {
        HStack {
            Button(action: {
                viewModel.toggleCapture(
                    source: settings.audioInputSource,
                    sensitivity: settings.speechDetectionSensitivity,
                    recognitionMode: settings.recognitionLanguageMode,
                    recognitionVocabulary: settings.recognitionVocabulary,
                    captureDiagnosticsEnabled: settings.captureDiagnosticsEnabled
                )
            }) {
                HStack(spacing: 6) {
                    if viewModel.isLoading
                        || viewModel.isPreparingTranslation
                        || viewModel.isStartingCapture {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Circle()
                            .fill(viewModel.isRecording ? .green : .gray)
                            .frame(width: 8, height: 8)
                    }
                    Text(toolbarButtonLabel)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(viewModel.isRecording
                              ? Color.green.opacity(0.15)
                              : Color.gray.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .disabled(
                viewModel.isLoading
                    || viewModel.isPreparingTranslation
                    || !viewModel.isTranslationReady
                    || viewModel.isStartingCapture
            )

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Label(settings.audioInputSource.displayName, systemImage: inputIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(settings.recognitionLanguageMode.displayName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("Cmd+Shift+T")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var toolbarButtonLabel: String {
        if viewModel.isLoading { return "Loading..." }
        if viewModel.isPreparingTranslation { return "Preparing translation..." }
        if viewModel.isStartingCapture { return "Starting..." }
        if viewModel.isRecording { return "Recording" }
        return "Start"
    }

    private var inputIcon: String {
        settings.audioInputSource == .microphone ? "mic" : "speaker.wave.2"
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.captionHistory) { entry in
                        CaptionRow(entry: entry)
                            .id(entry.id)
                    }

                    // Current streaming line (live)
                    if viewModel.hasStreamingText {
                        StreamingRow(
                            original: viewModel.streamingOriginalText,
                            translation: viewModel.streamingTranslatedText,
                            stableOriginal: viewModel.streamingStableOriginal,
                            draftOriginal: viewModel.streamingDraftOriginal
                        )
                        .id("streaming")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.transcriptBottomID)
                }
                .padding(16)
                .textSelection(.enabled)
            }
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
                proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
            }
            .onChange(of: viewModel.captionContentRevision) {
                Task { @MainActor in
                    await Task.yield()
                    guard autoScrollState.shouldFollowContentChanges else {
                        return
                    }
                    proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
                }
            }
        }
    }

    private static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        let tolerance: CGFloat = 8
        return geometry.contentSize.height <= geometry.containerSize.height
            || geometry.visibleRect.maxY >= geometry.contentSize.height - tolerance
    }
}

private struct CaptionRow: View {
    let entry: CaptionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.6))
            if entry.sourceLanguage == .english {
                originalText(entry.englishText)
                translatedText(entry.chineseText)
            } else {
                originalText(entry.chineseText)
                translatedText(entry.englishText)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.3)
        }
    }

    private func originalText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.9))
    }

    private func translatedText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color(red: 0.47, green: 0.78, blue: 1.0).opacity(0.8))
    }
}

private struct StreamingRow: View {
    let original: String
    let translation: String
    let stableOriginal: String
    let draftOriginal: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.8))
            }
            LiveCaptionTextView(
                original: original,
                stableOriginal: stableOriginal,
                draftOriginal: draftOriginal,
                translation: translation,
                originalFontSize: 14,
                translationFontSize: 13,
                translationColor: Color(
                    red: 0.47,
                    green: 0.78,
                    blue: 1.0
                )
            )
        }
        .padding(.vertical, 10)
        .transaction { $0.animation = nil }
    }
}
