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
    @State private var compactPage = "summary"
    @State private var sidebarWidth: CGFloat = CaptionWorkspaceStyle.sidebarWidth
    @State private var dividerStart: CGFloat?
    @State private var controlsHeight: CGFloat = 58
    @FocusState private var summaryButtonFocused: Bool
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

    private var transcript: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // The live history is capped at 100 rows. Eager layout of
                    // this bounded slice keeps bottom-following accurate with
                    // variable-height selectable text, including after resize.
                    VStack(alignment: .leading, spacing: 18) {
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
                                originalOpacity: isLatest ? 0.97 : 0.76,
                                translationOpacity: isLatest ? 0.98 : 0.80
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
                        Color.clear.frame(height: max(62, controlsHeight + 4))
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                    }
                    .padding(.horizontal, 22)
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
                .onChange(of: controlsHeight) {
                    if autoScrollState.shouldFollowContentChanges { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
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
        .overlay(alignment: .bottom) {
            CaptionQuickControls(onEngagement: { interactingWithControls = $0 },
                onSettings: onSettings, onPhone: onPhone, onMinimize: onMinimize,
                onHistory: onHistory)
                .padding(8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controlsVisible)
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
    }

    // THESIS: subtitles retain a real reading column; the outline supports them.
    // WORLD: native dark reading surfaces, SF type, one blue translation accent.
    // PATH: scan topic → named branches → short nodes; expand explanations on demand.
    // FIRST VIEWPORT: shared quiet toolbar; wide split, compact content switch.
    // FORM: native tree diagram with real sibling edges; repeated meanings reuse nodes, captions keep their own column.
    // FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md
    var body: some View {
        GeometryReader { geometry in
            let expanded = viewModel.conversationSummary.isExpanded
            let split = expanded && geometry.size.width >= CaptionWorkspaceStyle.splitMinimum
            let summaryWidth = min(sidebarWidth, max(300, geometry.size.width - 369))
            let captionWidth = split ? geometry.size.width - summaryWidth - 9 : geometry.size.width
            let showsCaptions = !expanded || split || compactPage == "captions"
            let showsSummary = expanded && (split || compactPage == "summary")
            VStack(spacing: 0) {
                workspaceToolbar(compact: expanded && !split)
                Rectangle().fill(CaptionWorkspaceStyle.line).frame(height: 1)
                ZStack(alignment: .leading) {
                    // Keep one transcript instance and its scroll/selection identity
                    // across wide/compact transitions. Hidden panes cannot take focus.
                    transcript
                        .frame(width: captionWidth)
                        .opacity(showsCaptions ? 1 : 0)
                        .allowsHitTesting(showsCaptions)
                        .disabled(!showsCaptions)
                        .accessibilityHidden(!showsCaptions)
                    if expanded {
                        ConversationSummaryView()
                            .frame(width: split ? summaryWidth : geometry.size.width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .opacity(showsSummary ? 1 : 0)
                            .allowsHitTesting(showsSummary)
                            .disabled(!showsSummary)
                            .accessibilityHidden(!showsSummary)
                    }
                    if split {
                        Rectangle().fill(CaptionWorkspaceStyle.line).frame(width: 1)
                            .frame(width: 9, height: geometry.size.height - 41)
                            .contentShape(Rectangle())
                            .offset(x: captionWidth)
                            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                                if dividerStart == nil { dividerStart = sidebarWidth }
                                sidebarWidth = min(440, max(300, (dividerStart ?? sidebarWidth) - value.translation.width))
                            }.onEnded { _ in dividerStart = nil })
                            .help("拖动分隔线以调整两栏宽度")
                            .accessibilityLabel("调整字幕和脑图的宽度")
                            .accessibilityAdjustableAction { direction in
                                sidebarWidth = min(440, max(300, sidebarWidth + (direction == .increment ? 20 : -20)))
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .background(CaptionWorkspaceStyle.surface.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onChange(of: expanded) { _, value in
                compactPage = value ? "summary" : "captions"
                if !value { summaryButtonFocused = true }
                onSummaryExpansion(value)
            }
        }
        .frame(minWidth: 288, minHeight: 132)
        .padding(FloatingPanel.resizeInteractionInset)
        .background(RoundedRectangle(cornerRadius: 16).fill(CaptionWorkspaceStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.13), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onKeyPress(.escape) {
            guard viewModel.conversationSummary.isExpanded else { return .ignored }
            viewModel.conversationSummary.collapse(); return .handled
        }
    }

    private func workspaceToolbar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if compact {
                Picker("阅读内容", selection: $compactPage) {
                    Text("字幕").tag("captions")
                    Text("脑图").tag("summary")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 156)
            } else {
                Image(systemName: "captions.bubble").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CaptionWorkspaceStyle.accent)
                Text("实时字幕").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CaptionWorkspaceStyle.foreground)
                if viewModel.isRecording {
                    Circle().fill(CaptionWorkspaceStyle.accent).frame(width: 5, height: 5)
                        .accessibilityLabel("正在收音")
                }
            }
            Spacer(minLength: 4)
            Button {
                if viewModel.conversationSummary.isExpanded { viewModel.conversationSummary.collapse() }
                else { compactPage = "summary"; viewModel.expandConversationSummary() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sidebar.right")
                    if !compact { Text(viewModel.conversationSummary.isExpanded ? "收起脑图" : "对话脑图") }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(viewModel.conversationSummary.isExpanded ? CaptionWorkspaceStyle.accent : CaptionWorkspaceStyle.secondary)
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).focused($summaryButtonFocused)
            .accessibilityLabel(viewModel.conversationSummary.isExpanded ? "收起对话脑图" : "展开对话脑图")
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 14).frame(height: 38)
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
        VStack(alignment: .leading, spacing: 5) {
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
