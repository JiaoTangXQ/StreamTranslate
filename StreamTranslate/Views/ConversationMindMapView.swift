import SwiftUI

/// The current subject opens automatically; deliberate disclosures stay put.
/// Older facts remain in the map, with a compact overview before expansion.
struct ConversationMindMapView: View {
    let map: ConversationMindMap
    var overviewOnly = false
    @State private var activeTopic: String?
    @State private var disclosure: [String: Bool] = [:]
    @State private var advertisementsExpanded = false

    private var discussions: [ConversationMindMap.Topic] {
        map.topics.filter { $0.kind != .advertisement && !$0.branches.allSatisfy { $0.points.isEmpty } }
    }
    private var advertisements: [ConversationMindMap.Topic] {
        map.topics.filter { $0.kind == .advertisement && !$0.branches.allSatisfy { $0.points.isEmpty } }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(discussions) { topic in
                OutlineTopic(topic: topic, overviewOnly: overviewOnly, expanded: Binding(
                    get: { disclosure[topic.id] ?? (topic.id == (activeTopic ?? discussions.last?.id)) },
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
                            OutlineTopic(topic: topic, overviewOnly: overviewOnly, expanded: Binding(
                                get: { disclosure[topic.id] ?? false },
                                set: { disclosure[topic.id] = $0 }))
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .onChange(of: map) { old, new in
            if new.topics.isEmpty { activeTopic = nil; disclosure = [:]; advertisementsExpanded = false; return }
            let previous = Dictionary(uniqueKeysWithValues: old.topics.map { ($0.id, $0.branches.flatMap(\.points).map(\.id)) })
            if let changed = new.topics.last(where: { $0.kind != .advertisement && previous[$0.id] != $0.branches.flatMap(\.points).map(\.id) }) {
                activeTopic = changed.id
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("对话主题与要点")
    }
}

private struct OutlineTopic: View {
    let topic: ConversationMindMap.Topic
    let overviewOnly: Bool
    @Binding var expanded: Bool
    private var count: Int { topic.branches.reduce(0) { $0 + $1.points.count } }
    private var branches: [ConversationMindMap.Branch] { topic.branches.filter { !$0.points.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .center, spacing: 9) {
                    Circle().fill(CaptionWorkspaceStyle.accent).frame(width: 5, height: 5)
                    Text(topic.title)
                        .font(.system(size: topic.kind == .advertisement ? 13 : 15, weight: .semibold))
                        .foregroundStyle(CaptionWorkspaceStyle.foreground)
                        .lineSpacing(3).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !expanded {
                        Text("\(count)").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(CaptionWorkspaceStyle.secondary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(CaptionWorkspaceStyle.accent)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(CaptionWorkspaceStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CaptionWorkspaceStyle.accent.opacity(0.28), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "收起" : "展开")主题：\(topic.title)，\(branches.count)个分支，\(count)个节点")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(branches.enumerated()), id: \.element.id) { index, branch in
                        HStack(alignment: .top, spacing: 0) {
                            MindMapEdge(last: index == branches.count - 1, joint: 20)
                                .stroke(CaptionWorkspaceStyle.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                                .frame(width: 18).accessibilityHidden(true)
                            OutlineBranch(branch: branch, overviewOnly: overviewOnly).padding(.top, 5).padding(.bottom, 8)
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
    @State private var showsAll = false
    private var expanded: Bool { disclosure ?? !overviewOnly }
    private var points: [ConversationMindMap.Point] {
        if showsAll || branch.points.count <= 3 { return branch.points }
        return [branch.points[0]] + branch.points.suffix(2)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { disclosure = !expanded } label: {
                HStack(spacing: 7) {
                    Text(branch.title == "要点" ? "概览" : branch.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(branch.points.count)").font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(CaptionWorkspaceStyle.secondary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(CaptionWorkspaceStyle.accent)
                .frame(minHeight: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "收起" : "展开")分支：\(branch.title)，\(branch.points.count)个节点")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        HStack(alignment: .top, spacing: 0) {
                            MindMapEdge(last: index == points.count - 1, joint: 19)
                                .stroke(CaptionWorkspaceStyle.accent.opacity(0.36), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                                .frame(width: 14).accessibilityHidden(true)
                            MindMapLeaf(point: point).padding(.vertical, 3)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if branch.points.count > 3 {
                        Button(showsAll ? "收起较早节点" : "其余 \(branch.points.count - 3) 个节点") { showsAll.toggle() }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CaptionWorkspaceStyle.accent)
                            .buttonStyle(.plain).frame(minHeight: 28).padding(.leading, 14)
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
        .padding(.horizontal, 9).padding(.vertical, 8)
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
