import SwiftUI

/// Topics the latest update touched open automatically; a topic the reader
/// opened or closed stays that way. Collapsed topics still show their
/// one-line summary, so the whole session reads at a glance.
struct ConversationMindMapView: View {
    let map: ConversationMindMap
    var activeTopicIDs: [String] = []
    var overviewOnly = false
    @State private var disclosure: [String: Bool] = [:]
    @State private var advertisementsExpanded = false

    private var discussions: [ConversationMindMap.Topic] {
        map.topics.filter { $0.kind != .advertisement && $0.pointCount > 0 }
    }
    private var advertisements: [ConversationMindMap.Topic] {
        map.topics.filter { $0.kind == .advertisement && $0.pointCount > 0 }
    }

    private func opensByDefault(_ topic: ConversationMindMap.Topic) -> Bool {
        if discussions.count <= 2 { return true }
        let active = activeTopicIDs.filter { id in discussions.contains { $0.id == id } }
        return active.isEmpty ? topic.id == discussions.last?.id : active.contains(topic.id)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(discussions) { topic in
                OutlineTopic(topic: topic, overviewOnly: overviewOnly,
                             isRecent: activeTopicIDs.contains(topic.id), expanded: Binding(
                    get: { disclosure[topic.id] ?? opensByDefault(topic) },
                    set: { disclosure[topic.id] = $0 }))
            }
            if !advertisements.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Button { advertisementsExpanded.toggle() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "megaphone").font(.system(size: 11))
                            Text("广告与赞助")
                            Text("\(advertisements.count)").monospacedDigit()
                            Spacer()
                            Image(systemName: advertisementsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 12)).foregroundStyle(CaptionWorkspaceStyle.secondary)
                        .frame(minHeight: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(advertisementsExpanded ? "收起" : "展开")广告与赞助，\(advertisements.count)项")
                    if advertisementsExpanded {
                        ForEach(advertisements) { topic in
                            OutlineTopic(topic: topic, overviewOnly: overviewOnly, isRecent: false, expanded: Binding(
                                get: { disclosure[topic.id] ?? false },
                                set: { disclosure[topic.id] = $0 }))
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .onChange(of: map.topics.isEmpty) { _, empty in
            if empty { disclosure = [:]; advertisementsExpanded = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("对话主题与要点")
    }
}

private struct OutlineTopic: View {
    let topic: ConversationMindMap.Topic
    let overviewOnly: Bool
    let isRecent: Bool
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .top, spacing: 9) {
                    Circle().fill(isRecent ? CaptionWorkspaceStyle.accent : CaptionWorkspaceStyle.secondary.opacity(0.6))
                        .frame(width: 6, height: 6).padding(.top, 7)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.title)
                            .font(.system(size: topic.kind == .advertisement ? 13 : 15, weight: .semibold))
                            .foregroundStyle(CaptionWorkspaceStyle.foreground)
                            .lineSpacing(3).multilineTextAlignment(.leading)
                        if !topic.summary.isEmpty {
                            Text(topic.summary)
                                .font(.system(size: 12)).lineSpacing(3)
                                .foregroundStyle(CaptionWorkspaceStyle.secondary)
                                .lineLimit(expanded ? nil : 2).multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(CaptionWorkspaceStyle.accent)
                        .padding(.top, 5)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(CaptionWorkspaceStyle.accent.opacity(isRecent ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CaptionWorkspaceStyle.accent.opacity(isRecent ? 0.32 : 0.16), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "收起" : "展开")主题：\(topic.title)。\(topic.summary)。\(topic.branches.count)个分支")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(topic.branches.enumerated()), id: \.element.id) { index, branch in
                        HStack(alignment: .top, spacing: 0) {
                            MindMapEdge(last: index == topic.branches.count - 1, joint: 20)
                                .stroke(CaptionWorkspaceStyle.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                                .frame(width: 18).accessibilityHidden(true)
                            OutlineBranch(branch: branch, overviewOnly: overviewOnly).padding(.top, 5).padding(.bottom, 6)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 14)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct OutlineBranch: View {
    let branch: ConversationMindMap.Branch
    let overviewOnly: Bool
    @State private var disclosure: Bool?
    private var expanded: Bool { disclosure ?? !overviewOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { disclosure = !expanded } label: {
                HStack(spacing: 7) {
                    Text(branch.title).font(.system(size: 12, weight: .semibold))
                    if !expanded {
                        Text("\(branch.points.count)").font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(CaptionWorkspaceStyle.secondary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(CaptionWorkspaceStyle.accent)
                .frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "收起" : "展开")分支：\(branch.title)，\(branch.points.count)个节点")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(branch.points.enumerated()), id: \.element.id) { index, point in
                        HStack(alignment: .top, spacing: 0) {
                            MindMapEdge(last: index == branch.points.count - 1, joint: 19)
                                .stroke(CaptionWorkspaceStyle.accent.opacity(0.36), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                                .frame(width: 14).accessibilityHidden(true)
                            MindMapLeaf(point: point).padding(.vertical, 3)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MindMapLeaf: View {
    let point: ConversationMindMap.Point
    @State private var showsDetail = false
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if point.detail.isEmpty {
                label.textSelection(.enabled)
            } else {
                Button { showsDetail.toggle() } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(showsDetail ? "收起" : "展开")节点说明：\(point.text)")
            }
            if showsDetail, !point.detail.isEmpty {
                Text(point.detail).font(.system(size: 12)).lineSpacing(4)
                    .foregroundStyle(CaptionWorkspaceStyle.secondary)
                    .textSelection(.enabled).padding(.horizontal, 9).padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovered = $0 }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(point.text).font(.system(size: 12, weight: .medium)).lineSpacing(3)
                .foregroundStyle(CaptionWorkspaceStyle.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !point.detail.isEmpty {
                Image(systemName: showsDetail ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(CaptionWorkspaceStyle.secondary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Color.white.opacity(hovered ? 0.065 : 0.035), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// An edge joins every sibling to its own parent, rather than drawing a single
/// decorative rail beside unrelated paragraphs. The last edge ends at its node.
private struct MindMapEdge: Shape {
    var last: Bool
    var joint: CGFloat
    func path(in rect: CGRect) -> Path {
        Path { path in
            let y = min(joint, rect.height)
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: last ? y : rect.height))
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
        }
    }
}
