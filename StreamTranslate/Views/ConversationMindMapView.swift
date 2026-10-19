import SwiftUI

/// Native reading tree: one topic, connected branches, selectable leaf text.
/// It preserves the caption drawer's dark palette and supports a 300pt panel.
struct ConversationMindMapView: View {
    let map: ConversationMindMap
    @State private var expanded: Set<Int> = [0]
    private let accent = Color(red: 0.47, green: 0.78, blue: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(map.topic)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .lineSpacing(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(map.branches) { branch in
                    branchView(branch)
                }
            }
            .padding(.leading, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本次对话脑图")
    }

    private func branchView(_ branch: ConversationMindMap.Branch) -> some View {
        HStack(alignment: .top, spacing: 0) {
            BranchConnection(isLast: branch.id == map.branches.last?.id)
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
                    ForEach(Array(branch.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 7) {
                            Circle().fill(accent.opacity(0.8)).frame(width: 3, height: 3).padding(.top, 7)
                            Text(point).font(.system(size: 12)).lineSpacing(4)
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
