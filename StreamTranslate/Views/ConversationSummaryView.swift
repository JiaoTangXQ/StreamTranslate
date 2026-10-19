import SwiftUI

/// A right-edge drawer over the reading surface. No model is loaded while
/// collapsed; narrow windows retain the same controls.
struct ConversationSummaryView: View {
    @Environment(CaptionViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: ConversationSummaryModel { viewModel.conversationSummary }
    private var displayedText: String { summary.displayedMap.outline }

    var body: some View {
        GeometryReader { geometry in
            if summary.isExpanded {
                drawer
                    .frame(width: min(380, max(260, geometry.size.width - 20)))
                    .frame(maxHeight: .infinity)
                    .background(.black, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2)))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button {
                    viewModel.expandConversationSummary()
                } label: {
                    VStack(spacing: 5) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        Text("总\n结").lineSpacing(2)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 28, height: 78)
                    .background(.black.opacity(0.92), in: UnevenRoundedRectangle(
                        topLeadingRadius: 9, bottomLeadingRadius: 9))
                    .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.2)).frame(width: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开本次对话的 AI 总结")
                .help("总结本次对话在聊什么，以及讨论进展")
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: summary.isExpanded)
        .environment(\.colorScheme, .dark)
        .onDisappear { summary.collapse() }
    }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本次对话").font(.system(size: 14, weight: .semibold))
                    Text("AI 脑图 · 仅在本机处理").font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(displayedText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").frame(width: 26, height: 30)
                }
                .buttonStyle(.plain).disabled(!summary.displayedMap.hasContent)
                .accessibilityLabel("复制脑图文字").help("复制完整的主题、分支和要点")
                Button { summary.collapse() } label: {
                    Image(systemName: "chevron.right").frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("折叠对话总结")
                .help("折叠总结；正在生成时会取消并释放模型")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(.white.opacity(0.15))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if summary.displayedMap.hasContent {
                        ConversationMindMapView(map: summary.displayedMap)
                        if !summary.isGenerating, let date = summary.completedAt {
                            HStack(spacing: 4) {
                                Text("已梳理 \(summary.coveredCount) 条 ·")
                                Text(date, format: .dateTime.hour().minute())
                            }
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                        }
                    } else if !summary.isGenerating && summary.errorMessage == nil {
                        Text("先听几句话，再来看脑图。")
                            .font(.system(size: 14, weight: .medium))
                        Text("新内容补充到对应话题；广告和不同主题各自分开。点击话题或分支可展开、收起。")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    }
                    if summary.isGenerating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text(summary.progress).font(.system(size: 12))
                        }
                        .accessibilityLabel(summary.progress)
                    }
                    if let error = summary.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
                        if !LocalSummaryService.isInstalled {
                            Button("查看本地模型安装说明") {
                                NSWorkspace.shared.open(URL(string: "https://github.com/JiaoTangXQ/StreamTranslate/blob/main/docs/conversation-summary-1.7.0.md")!)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            Divider().overlay(.white.opacity(0.15))
            HStack(spacing: 8) {
                if summary.errorMessage != nil {
                    Button("重试") { viewModel.resumeConversationSummary() }
                } else if summary.isAutoUpdating {
                    Button("暂停") { summary.pauseAutomaticUpdates() }
                } else {
                    Button("继续") { viewModel.resumeConversationSummary() }
                }
                Text(summary.isGenerating ? "更新中" : summary.isUpdateScheduled ? "即将更新"
                    : summary.isAutoUpdating ? "自动更新" : "已暂停")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                Text("AI 可能有遗漏").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .foregroundStyle(.white.opacity(0.95))
    }
}
