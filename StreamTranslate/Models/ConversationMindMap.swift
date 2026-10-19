import Foundation

/// A bounded reading tree parsed from streamed plain text. Topic/branch/point
/// order is preserved; incomplete drafts wait for a meaningful topic line.
struct ConversationMindMap: Equatable {
    struct Branch: Equatable, Identifiable {
        let id: Int
        var title: String
        var points: [String]
    }
    let topic: String
    let branches: [Branch]

    static func parse(_ text: String, isDraft: Bool = false) -> Self? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        var topic = "", branches: [Branch] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            if topic.isEmpty, let colon = heading.firstIndex(where: { $0 == ":" || $0 == "：" }),
               ["主题", "中心主题"].contains(String(heading[..<colon]).trimmingCharacters(in: .whitespaces)) {
                topic = String(heading[heading.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                continue
            }
            let isIndented = raw.first == " " || raw.first == "\t"
            let bullet = ["- ", "* ", "• ", "· "].contains(where: line.hasPrefix)
            let content = (bullet ? String(line.dropFirst(2)) : line)
                .trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            guard !content.isEmpty, content != "-" else { continue }
            if bullet && !isIndented {
                branches.append(Branch(id: branches.count, title: content, points: []))
            } else if !branches.isEmpty {
                branches[branches.count - 1].points.append(content)
            } else {
                // A topic header does not guarantee that the model follows the
                // outline grammar. Preserve prose before its first branch.
                branches.append(Branch(id: 0, title: "对话大意", points: [content]))
            }
        }
        guard !topic.isEmpty else {
            if isDraft { return nil }
            // Readable compatibility for a model that returns prose. No extra
            // relationship or factual topic is inferred by this fallback.
            return Self(topic: "本次对话", branches: [Branch(id: 0, title: "对话大意", points: [source])])
        }
        if branches.count > 5 {
            let overflow = branches.dropFirst(4).flatMap { [$0.title] + $0.points }
            branches = Array(branches.prefix(4)) + [Branch(id: 4, title: "其他内容", points: overflow)]
        }
        for index in branches.indices where branches[index].points.count > 3 {
            let points = branches[index].points
            branches[index].points = Array(points.prefix(2)) + [points.dropFirst(2).joined(separator: "\n")]
        }
        return Self(topic: topic, branches: branches)
    }
}
