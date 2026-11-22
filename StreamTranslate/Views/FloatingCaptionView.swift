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
    @State private var exportError: String?
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

    private static let bottomID = "floating-caption-bottom"

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
                        // All completed captions (scrollable history). A
                        // separate equatable view: streaming text changes
                        // several times a second and must not re-evaluate
                        // up to 99 completed rows each time.
                        CaptionHistoryRows(
                            entries: viewModel.floatingCaptionHistory,
                            revision: viewModel.historyRevision,
                            latestIsLive: !viewModel.hasStreamingText,
                            fontSize: settings.fontSize
                        )
                        .equatable()

                        // Current streaming / completed line
                        if viewModel.hasStreamingText {
                            StreamingCaptionRow(proxy: proxy, follows: autoScrollState.shouldFollowContentChanges,
                                                bottomID: Self.bottomID)
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
                .onChange(of: viewModel.captionContentRevision) {
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
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "无法导出当前字幕。")
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
            captionExportMenu
            CaptionToolbarButton(title: "清空当前字幕和脑图", symbol: "trash") {
                viewModel.clearCurrentSession()
            }
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

    private var captionExportMenu: some View {
        Menu {
            Button("导出字幕 HTML…") { exportCaptions(.html) }
                .disabled(viewModel.captionHistory.isEmpty)
            Button("导出字幕 PDF…") { exportCaptions(.pdf) }
                .disabled(viewModel.captionHistory.isEmpty)
            Divider()
            Button("清空当前字幕和脑图", role: .destructive) {
                viewModel.clearCurrentSession()
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CaptionWorkspaceStyle.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("导出当前字幕或清空当前字幕和脑图")
        .accessibilityLabel("字幕导出与清空")
    }

    private func exportCaptions(_ format: ConversationExportFormat) {
        Task { @MainActor in
            do {
                let entries = try await viewModel.currentSessionCaptions()
                _ = try await ConversationExportService.exportCaptions(entries, format: format)
            } catch is CancellationError {
                // Closing the save panel is a normal cancellation.
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        let tolerance: CGFloat = 8
        return geometry.contentSize.height <= geometry.containerSize.height
            || geometry.visibleRect.maxY >= geometry.contentSize.height - tolerance
    }
}

private let captionTranslationColor = Color(red: 0.47, green: 0.78, blue: 1.0)

/// Completed captions. Equatable on the history revision, so streaming text,
/// hover and control fades do not rebuild every row.
private struct CaptionHistoryRows: View, Equatable {
    let entries: ArraySlice<CaptionEntry>
    let revision: Int
    let latestIsLive: Bool
    let fontSize: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.entries.count == rhs.entries.count
            && lhs.latestIsLive == rhs.latestIsLive && lhs.fontSize == rhs.fontSize
            && lhs.entries.last?.id == rhs.entries.last?.id
    }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(entries) { entry in
                    let isLatest = latestIsLive && entry.id == entries.last?.id
                    pair(entry, originalOpacity: isLatest ? 0.97 : 0.76, translationOpacity: isLatest ? 0.98 : 0.80)
                        .id(entry.id)
                }
            }
        }
    }

    private func pair(_ entry: CaptionEntry, originalOpacity: Double, translationOpacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.originalText)
                .font(.system(size: fontSize))
                .foregroundStyle(.white.opacity(originalOpacity))
                .fixedSize(horizontal: false, vertical: true)
            if !entry.translatedText.isEmpty {
                Text(entry.translatedText)
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(captionTranslationColor.opacity(translationOpacity))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The only part of the transcript that changes on every recognizer update.
private struct StreamingCaptionRow: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @Environment(CaptionSettings.self) private var settings
    let proxy: ScrollViewProxy
    let follows: Bool
    let bottomID: String

    var body: some View {
        LiveCaptionTextView(
            original: viewModel.streamingOriginalText,
            stableOriginal: viewModel.streamingStableOriginal,
            draftOriginal: viewModel.streamingDraftOriginal,
            translation: viewModel.streamingTranslatedText,
            originalFontSize: settings.fontSize,
            translationFontSize: settings.fontSize - 1,
            translationColor: captionTranslationColor.opacity(0.9)
        )
        // Growing text can wrap onto a new line; keep the bottom in view.
        .onChange(of: viewModel.streamingOriginalText + "\u{1F}" + viewModel.streamingTranslatedText) {
            guard follows else { return }
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}
