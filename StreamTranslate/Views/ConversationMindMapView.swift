import SwiftUI

/// Independent topic trees. Stable IDs preserve disclosure state as facts arrive.
struct ConversationMindMapView: View {
    let map: ConversationMindMap
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(map.topics.filter { $0.branches.contains { !$0.points.isEmpty } }) { topic in
                MindMapTopicView(topic: topic)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本次对话的独立话题脑图")
    }
}

private struct MindMapTopicView: View {
    let topic: ConversationMindMap.Topic
    @State private var isExpanded: Bool
    @State private var expanded: Set<String>
    private let accent = Color(red: 0.47, green: 0.78, blue: 1)

    init(topic: ConversationMindMap.Topic) {
        self.topic = topic
        _isExpanded = State(initialValue: topic.kind != .advertisement)
        _expanded = State(initialValue: Set(topic.branches.prefix(1).map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .top, spacing: 8) {
                    if topic.kind == .advertisement {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("广告").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                            Text(topic.title).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            if topic.kind == .uncertain {
                                Text(topic.kind.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                            }
                            Text(topic.title).font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.96)).lineSpacing(3)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7)).padding(.top, 4)
                }
                .padding(.horizontal, 12).padding(.vertical, topic.kind == .advertisement ? 8 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(topic.kind == .advertisement ? 0.07 : 0.15), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "收起" : "展开")\(topic.kind.label)：\(topic.title)")
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(topic.branches.filter { !$0.points.isEmpty }) { branch in branchView(branch) }
                }
                .padding(.leading, 12)
            }
        }
    }

    private func branchView(_ branch: ConversationMindMap.Branch) -> some View {
        HStack(alignment: .top, spacing: 0) {
            BranchConnection(isLast: branch.id == topic.branches.last?.id)
                .stroke(accent.opacity(0.55), lineWidth: 1)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if expanded.contains(branch.id) { expanded.remove(branch.id) }
                    else { expanded.insert(branch.id) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(branch.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                        Spacer(minLength: 0)
                        if !expanded.contains(branch.id) {
                            Text("\(branch.points.count)")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                        }
                        Image(systemName: expanded.contains(branch.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded.contains(branch.id) ? "收起" : "展开")\(branch.title)，\(branch.points.count)条要点")
                if expanded.contains(branch.id) {
                    ForEach(branch.points) { point in
                        HStack(alignment: .top, spacing: 7) {
                            Circle().fill(accent.opacity(0.8)).frame(width: 3, height: 3).padding(.top, 7)
                            Text(point.text).font(.system(size: 12)).lineSpacing(4)
                                .foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.top, 14).padding(.bottom, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BranchConnection: Shape {
    let isLast: Bool
    func path(in rect: CGRect) -> Path {
        Path { path in
            let y: CGFloat = 22
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: isLast ? y : rect.height))
            path.move(to: CGPoint(x: 0, y: y))
            path.addQuadCurve(to: CGPoint(x: 9, y: y + 3), control: CGPoint(x: 0, y: y + 3))
            path.addLine(to: CGPoint(x: rect.width - 3, y: y + 3))
        }
    }
}
