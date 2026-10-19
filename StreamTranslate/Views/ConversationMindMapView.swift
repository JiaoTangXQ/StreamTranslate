import SwiftUI

/// The current subject opens automatically; deliberate disclosures stay put.
/// Older facts remain in the map, with a compact overview before expansion.
struct ConversationMindMapView: View {
    let map: ConversationMindMap
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
                OutlineTopic(topic: topic, expanded: Binding(
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
                            OutlineTopic(topic: topic, expanded: Binding(
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
    @Binding var expanded: Bool
    @State private var hovered = false
    private var count: Int { topic.branches.reduce(0) { $0 + $1.points.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(topic.title)
                        .font(.system(size: topic.kind == .advertisement ? 13 : 15, weight: .semibold))
                        .foregroundStyle(expanded ? CaptionWorkspaceStyle.foreground : CaptionWorkspaceStyle.secondary)
                        .lineSpacing(3).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !expanded {
                        Text("\(count)").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(CaptionWorkspaceStyle.secondary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(CaptionWorkspaceStyle.secondary)
                }
                .frame(minHeight: 32).contentShape(Rectangle())
                .background(hovered ? Color.white.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel("\(expanded ? "收起" : "展开")\(topic.title)，\(count)条要点")
            if expanded {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(topic.branches.filter { !$0.points.isEmpty }) { branch in
                        OutlineBranch(branch: branch)
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }
}

private struct OutlineBranch: View {
    let branch: ConversationMindMap.Branch
    @State private var showsAll = false
    private var points: [ConversationMindMap.Point] {
        if showsAll || branch.points.count <= 3 { return branch.points }
        return [branch.points[0]] + branch.points.suffix(2)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OutlineConnection().stroke(CaptionWorkspaceStyle.accent.opacity(0.42), lineWidth: 1)
                .frame(width: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 11) {
                if branch.title != "要点" {
                    Text(branch.title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CaptionWorkspaceStyle.accent)
                }
                ForEach(points) { point in
                    Text(point.text).font(.system(size: 13)).lineSpacing(5)
                        .foregroundStyle(CaptionWorkspaceStyle.foreground.opacity(0.94))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if branch.points.count > 3 {
                    Button(showsAll ? "收起早期细节" : "展开其余 \(branch.points.count - 3) 条") { showsAll.toggle() }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CaptionWorkspaceStyle.accent)
                        .buttonStyle(.plain).frame(minHeight: 28)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OutlineConnection: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: max(9, rect.height - 4)))
            path.move(to: CGPoint(x: 0, y: 9))
            path.addLine(to: CGPoint(x: rect.width, y: 9))
        }
    }
}
