import SwiftUI

/// A layout-owned reading pane. Reflow never cancels generation; only explicit
/// close, pause and the window lifecycle do that.
struct ConversationSummaryView: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @Environment(CaptionSettings.self) private var settings
    @State private var copied = false
    @State private var viewportHeight: CGFloat = 0
    @State private var exportError: String?
    private var summary: ConversationSummaryModel { viewModel.conversationSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("对话脑图").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Text("\(summary.map.topics.filter { $0.kind == .discussion }.count) 个话题")
                        Text("·")
                        Text(summary.backendDescription.replacingOccurrences(of: "AI 脑图 · ", with: ""))
                    }
                    .font(.system(size: 11)).foregroundStyle(CaptionWorkspaceStyle.secondary)
                }
                Spacer(minLength: 0)
                CaptionToolbarButton(title: copied ? "已复制" : "复制完整脑图", symbol: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary.map.outline, forType: .string)
                    copied = true
                }.disabled(!summary.map.hasContent)
                mindMapExportMenu
                CaptionToolbarButton(title: "清空当前字幕和脑图", symbol: "trash") {
                    viewModel.clearCurrentSession()
                }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if summary.map.hasContent {
                        ConversationMindMapView(map: summary.map, overviewOnly: viewportHeight < 300)
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(summary.isGenerating ? "正在梳理主题与分支" : "先听一段，再看脑图")
                                .font(.system(size: 15, weight: .medium))
                            Text("展开分支看短节点，点击节点看说明；完整字幕在历史记录中。")
                                .font(.system(size: 13)).lineSpacing(5)
                                .foregroundStyle(CaptionWorkspaceStyle.secondary)
                        }
                        .padding(.top, 18)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 18)
            }
            .scrollIndicators(.automatic)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            Rectangle().fill(CaptionWorkspaceStyle.line).frame(height: 1)
            statusBar
        }
        .foregroundStyle(CaptionWorkspaceStyle.foreground)
        .background(CaptionWorkspaceStyle.sidebar)
        .onAppear { summary.configuredUpdateDelay = settings.summaryUpdateInterval.duration }
        .onChange(of: settings.summaryUpdateInterval) { _, interval in
            summary.configuredUpdateDelay = interval.duration
        }
        .onChange(of: summary.completedAt) { copied = false }
        .onKeyPress(.escape) { summary.collapse(); return .handled }
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "无法导出当前脑图。")
        }
    }

    private var mindMapExportMenu: some View {
        Menu {
            Button("导出脑图 HTML…") { exportMindMap(.html) }
                .disabled(!summary.map.hasContent)
            Button("导出脑图 PDF…") { exportMindMap(.pdf) }
                .disabled(!summary.map.hasContent)
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
        .help("导出当前脑图或清空当前字幕和脑图")
        .accessibilityLabel("脑图导出与清空")
    }

    private func exportMindMap(_ format: ConversationExportFormat) {
        Task { @MainActor in
            do {
                _ = try await ConversationExportService.exportMindMap(summary.map, format: format)
            } catch is CancellationError {
                // Closing the save panel is a normal cancellation.
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private var statusBar: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                if let error = summary.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).lineLimit(3)
                        .foregroundStyle(CaptionWorkspaceStyle.foreground)
                } else {
                    HStack(spacing: 7) {
                        if summary.isGenerating { ProgressView().controlSize(.mini) }
                        Text(summary.isGenerating ? "整理完成后一起更新" : summary.isAutoUpdating ? settings.summaryUpdateInterval.summaryDescription : "自动整理已暂停")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11)).foregroundStyle(CaptionWorkspaceStyle.secondary)
                }
                if summary.errorMessage == nil {
                    SummaryIntervalPicker(selection: $settings.summaryUpdateInterval, compact: true)
                        .help("调整脑图自动整理间隔")
                }
            }
            if summary.errorMessage == nil {
                HStack {
                    Text("滚轮可选择整理间隔")
                        .font(.system(size: 10)).foregroundStyle(CaptionWorkspaceStyle.secondary)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                Button(summary.errorMessage != nil ? "重试" : "整理一次") {
                    if summary.errorMessage != nil { viewModel.resumeConversationSummary() }
                    else { viewModel.requestConversationSummary() }
                }
                    .disabled(summary.isGenerating)
                Button(summary.isAutoUpdating ? "暂停" : "继续") {
                    if summary.isAutoUpdating { summary.pauseAutomaticUpdates() }
                    else { viewModel.resumeConversationSummary() }
                }
                Spacer(minLength: 0)
                Text("AI 可能有遗漏").font(.system(size: 10)).foregroundStyle(CaptionWorkspaceStyle.secondary)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
