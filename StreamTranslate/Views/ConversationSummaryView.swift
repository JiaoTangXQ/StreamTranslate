import SwiftUI

/// A layout-owned reading pane. Reflow never cancels generation; only explicit
/// close, pause and the window lifecycle do that.
struct ConversationSummaryView: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @State private var copied = false
    private var summary: ConversationSummaryModel { viewModel.conversationSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("对话脉络").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Text("\(summary.map.topics.filter { $0.kind == .discussion }.count) 个话题")
                        Text("·")
                        Text(summary.backendDescription.replacingOccurrences(of: "AI 脑图 · ", with: ""))
                    }
                    .font(.system(size: 11)).foregroundStyle(CaptionWorkspaceStyle.secondary)
                }
                Spacer(minLength: 0)
                CaptionToolbarButton(title: copied ? "已复制" : "复制完整脉络", symbol: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary.map.outline, forType: .string)
                    copied = true
                }.disabled(!summary.map.hasContent)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if summary.map.hasContent {
                        ConversationMindMapView(map: summary.map)
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(summary.isGenerating ? "正在梳理这段对话" : "先听一段，再看脉络")
                                .font(.system(size: 15, weight: .medium))
                            Text("把相关内容合在一起，只保留观点、结论和新的进展。完整字幕可在历史记录中查看。")
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
            Rectangle().fill(CaptionWorkspaceStyle.line).frame(height: 1)
            statusBar
        }
        .foregroundStyle(CaptionWorkspaceStyle.foreground)
        .background(CaptionWorkspaceStyle.sidebar)
        .onChange(of: summary.completedAt) { copied = false }
        .onKeyPress(.escape) { summary.collapse(); return .handled }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = summary.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).lineLimit(3)
                    .foregroundStyle(CaptionWorkspaceStyle.foreground)
            } else {
                HStack(spacing: 7) {
                    if summary.isGenerating { ProgressView().controlSize(.mini) }
                    Text(summary.isGenerating ? "整理完成后一起更新" : summary.isAutoUpdating ? "约 30 秒集中整理一次" : "自动整理已暂停")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).foregroundStyle(CaptionWorkspaceStyle.secondary)
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
