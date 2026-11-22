import Foundation

/// Size budget for one mind map. The map is the session's compressed memory:
/// every update re-synthesizes it from the previous map plus new captions, so
/// its size, not the transcript length, bounds each request.
struct MindMapLimits: Equatable, Sendable {
    var topics: Int
    var branchesPerTopic: Int
    var pointsPerBranch: Int

    static let titleLength = 24, summaryLength = 60, branchLength = 16
    static let pointLength = 48, detailLength = 120

    /// Longer sessions get room for more topics; branches and nodes stay few
    /// so the map remains an overview instead of a transcript.
    static func forSession(minutes: Int, local: Bool) -> Self {
        let topics = switch minutes {
        case ..<20: 5
        case ..<60: 7
        case ..<180: 9
        default: 12
        }
        return local ? Self(topics: min(topics, 6), branchesPerTopic: 3, pointsPerBranch: 3)
                     : Self(topics: topics, branchesPerTopic: 4, pointsPerBranch: 4)
    }
}

/// Topic → branch → node outline of the whole conversation. Model output
/// replaces whole topics (so a story told in halves is merged and earlier
/// mistakes are corrected) while untouched topics, their IDs and their order
/// stay as they were.
struct ConversationMindMap: Equatable, Sendable {
    enum Kind: String, Sendable {
        case discussion, advertisement
        var label: String {
            switch self {
            case .discussion: "话题"
            case .advertisement: "广告 / 赞助"
            }
        }
    }

    struct Point: Equatable, Identifiable, Sendable {
        let id: String
        let text: String
        let detail: String
    }

    struct Branch: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let points: [Point]
    }

    struct Topic: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let kind: Kind
        let summary: String
        let branches: [Branch]
        var pointCount: Int { branches.reduce(0) { $0 + $1.points.count } }
    }

    /// The result of applying one model revision.
    struct Revision: Equatable, Sendable {
        let map: ConversationMindMap
        /// Topics added or rewritten by this revision, in map order.
        let changedTopicIDs: [String]
    }

    private(set) var topics: [Topic] = []
    private var nextTopic = 1

    var hasContent: Bool { topics.contains { $0.pointCount > 0 } }
    var pointCount: Int { topics.reduce(0) { $0 + $1.pointCount } }

    var outline: String {
        topics.map { topic in
            var lines = ["\(topic.kind.label)：\(topic.title)"]
            if !topic.summary.isEmpty { lines.append("  \(topic.summary)") }
            for branch in topic.branches {
                lines.append("- \(branch.title)")
                for point in branch.points {
                    lines.append("  - \(point.text)")
                    if !point.detail.isEmpty { lines.append("    \(point.detail)") }
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The current map as the model sees it. Compact JSON keeps IDs explicit
    /// so a revision can say which topic it replaces or merges away.
    var modelContext: String {
        let value: [[String: Any]] = topics.map { topic in
            ["id": topic.id, "kind": topic.kind.rawValue, "title": topic.title, "summary": topic.summary,
             "branches": topic.branches.map { branch in
                 ["title": branch.title, "points": branch.points.map { ["text": $0.text, "detail": $0.detail] }]
             }]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Applies `{"topics":[...],"remove":[...]}`. Each returned topic with an
    /// existing ID replaces that topic in place; other topics are appended.
    /// Removed IDs disappear unless the same response also rewrites them.
    /// Oversized text and counts are clipped rather than rejected, because a
    /// slightly long node is still useful; malformed structure is rejected.
    func applying(_ output: String, limits: MindMapLimits) throws -> Revision {
        guard let root = try? JSONSerialization.jsonObject(with: Data(Self.stripFence(output).utf8)) as? [String: Any],
              let items = root["topics"] as? [[String: Any]] else {
            throw SummaryError.invalidResult
        }
        let removals = Set((root["remove"] as? [Any] ?? []).compactMap { $0 as? String })
        var result = self
        var changed: [String] = []
        var claimed: Set<String> = []
        for item in items {
            guard let title = Self.clean(item["title"], limit: MindMapLimits.titleLength), !title.isEmpty else {
                throw SummaryError.invalidResult
            }
            let kind: Kind = (item["kind"] as? String) == Kind.advertisement.rawValue ? .advertisement : .discussion
            let summary = Self.clean(item["summary"], limit: MindMapLimits.summaryLength) ?? ""
            let requestedID = (item["id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let reuses = !requestedID.isEmpty && !claimed.contains(requestedID)
                && topics.contains { $0.id == requestedID }
            let id: String
            if reuses { id = requestedID } else { id = "T\(result.nextTopic)"; result.nextTopic += 1 }
            claimed.insert(id)
            var branches: [Branch] = []
            for rawBranch in (item["branches"] as? [[String: Any]] ?? []) {
                guard branches.count < limits.branchesPerTopic else { break }
                let branchTitle = Self.clean(rawBranch["title"], limit: MindMapLimits.branchLength)
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "要点"
                let branchID = id + "/" + branchTitle
                var points: [Point] = []
                for rawPoint in (rawBranch["points"] as? [Any] ?? []) {
                    guard points.count < limits.pointsPerBranch else { break }
                    let fields = rawPoint as? [String: Any]
                    guard let text = Self.clean(fields?["text"] ?? rawPoint, limit: MindMapLimits.pointLength),
                          !text.isEmpty else { continue }
                    let detail = Self.clean(fields?["detail"], limit: MindMapLimits.detailLength) ?? ""
                    guard !points.contains(where: { $0.text == text }) else { continue }
                    points.append(Point(id: branchID + "/" + text, text: text, detail: detail == text ? "" : detail))
                }
                guard !points.isEmpty else { continue }
                if let index = branches.firstIndex(where: { $0.title == branchTitle }) {
                    let merged = (branches[index].points + points).prefix(limits.pointsPerBranch)
                    branches[index] = Branch(id: branchID, title: branchTitle, points: Array(merged))
                } else {
                    branches.append(Branch(id: branchID, title: branchTitle, points: points))
                }
            }
            let topic = Topic(id: id, title: title, kind: kind, summary: summary, branches: branches)
            if let index = result.topics.firstIndex(where: { $0.id == id }) {
                result.topics[index] = topic
            } else {
                result.topics.append(topic)
            }
            changed.append(id)
        }
        // `remove` is honored only for a real merge: the same response rewrote
        // an existing topic that absorbed them. A bare removal (for example
        // to make room) folds the topics into the overview instead, so a
        // revision can never silently erase earlier parts of the session.
        let mergedIntoExisting = claimed.contains { id in topics.contains { $0.id == id } }
        let removable = removals.subtracting(claimed)
        if mergedIntoExisting {
            result.topics.removeAll { removable.contains($0.id) }
        }
        result.topics.removeAll { $0.pointCount == 0 }
        result.foldOldestTopics(keeping: claimed, limit: limits.topics,
                                forcing: mergedIntoExisting ? [] : removable)
        let remaining = Set(result.topics.map(\.id))
        return Revision(map: result, changedTopicIDs: changed.filter { remaining.contains($0) })
    }

    static let archiveTitle = "更早的话题"

    /// A model that ignores the topic budget must not grow the map without
    /// bound, and a long session must not silently lose its first hours. The
    /// oldest untouched topics become one line each in an overview topic,
    /// which later revisions may rewrite like any other topic.
    private mutating func foldOldestTopics(keeping claimed: Set<String>, limit: Int, forcing: Set<String> = []) {
        let isArchive: (Topic) -> Bool = { $0.title == Self.archiveTitle && $0.kind == .discussion }
        let live = topics.filter { !isArchive($0) }
        let forced = live.filter { forcing.contains($0.id) }
        let overflow = max(0, live.count - forced.count - max(1, limit))
        let oldest = live.filter { !claimed.contains($0.id) && !forcing.contains($0.id) }.prefix(overflow)
        let folded = forced + oldest
        guard !folded.isEmpty || live.count > max(1, limit) else { return }
        if !folded.isEmpty {
            let foldedIDs = Set(folded.map(\.id))
            let existing = topics.firstIndex(where: isArchive)
            let archive = existing.map { topics[$0] }
                ?? Topic(id: "T\(nextTopic)", title: Self.archiveTitle, kind: .discussion, summary: "", branches: [])
            if existing == nil { nextTopic += 1 }
            let branchID = archive.id + "/概览"
            var points = archive.branches.flatMap(\.points)
            for topic in folded {
                let gist = topic.summary.isEmpty ? (topic.branches.first?.points.first?.text ?? "") : topic.summary
                let line = gist.isEmpty ? topic.title : topic.title + "：" + gist
                guard let text = Self.clean(line, limit: MindMapLimits.pointLength),
                      !points.contains(where: { $0.text == text }) else { continue }
                points.append(Point(id: branchID + "/" + text, text: text, detail: ""))
            }
            let updated = Topic(id: archive.id, title: archive.title, kind: .discussion,
                summary: "已收拢 \(points.count) 个较早的话题",
                branches: [Branch(id: branchID, title: "概览", points: points)])
            topics.removeAll { foldedIDs.contains($0.id) || isArchive($0) }
            topics.insert(updated, at: 0)
        }
        // An oversized response with no older topic left to fold keeps its
        // first topics.
        while topics.filter({ !isArchive($0) }).count > limit, let last = topics.indices.last, !isArchive(topics[last]) {
            topics.removeLast()
        }
    }

    private static func clean(_ value: Any?, limit: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let text = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// Some compatible gateways wrap JSON in a Markdown fence despite the
    /// requested JSON response format.
    private static func stripFence(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("```") else { return value }
        value = String(value.drop(while: { $0 != "\n" }))
        if value.hasSuffix("```") { value = String(value.dropLast(3)) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
