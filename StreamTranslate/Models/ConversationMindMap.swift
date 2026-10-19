import Foundation
import CryptoKit

/// Application-owned forest: model output appends facts instead of replacing
/// or reparenting topics. Caption corrections invalidate dependent facts only.
struct ConversationMindMap: Equatable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case discussion, advertisement, uncertain
        var label: String {
            switch self {
            case .discussion: "话题"
            case .advertisement: "广告 / 赞助"
            case .uncertain: "待归类"
            }
        }
    }
    struct Point: Equatable, Identifiable, Sendable {
        let id: String
        let text: String
        var sources: Set<UUID>
    }
    struct Branch: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        var points: [Point]
    }
    struct Topic: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let kind: Kind
        var branches: [Branch]
        var nextBranch = 1
        var routingTerms: Set<String> = []
    }
    private(set) var topics: [Topic] = []
    private var nextTopic = 1
    var hasContent: Bool { topics.contains { $0.branches.contains { !$0.points.isEmpty } } }

    var outline: String {
        topics.filter { $0.branches.contains { !$0.points.isEmpty } }.map { topic in
            "\(topic.kind.label)：\(topic.title)\n" + topic.branches.filter { !$0.points.isEmpty }.map { branch in
                "- \(branch.title)\n" + branch.points.map { "  - \($0.text)" }.joined(separator: "\n")
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Bounded routing index, not a request to regenerate the entire forest.
    func context(for input: String = "", including linked: Set<String> = [], limit: Int = 1_200) -> String {
        var lines: [String] = [], size = 0
        let terms = Self.terms(input)
        var scored: [(index: Int, score: Int)] = []
        for index in topics.indices {
            let labels = topics[index].title + " " + topics[index].branches.map(\.title).joined(separator: " ")
            let knownTerms = Self.terms(labels).union(topics[index].routingTerms)
            let score = knownTerms.intersection(terms).count + (linked.contains(topics[index].id) ? 10_000 : 0)
            if score > 0 { scored.append((index, score)) }
        }
        scored.sort { $0.score == $1.score ? $0.index > $1.index : $0.score > $1.score }
        let matched = scored.prefix(6).map { $0.index }
        // Unrelated recent topics are not default parents. Sending their names
        // can bias extraction toward an opening advertisement or earlier event.
        let order: [Int] = input.isEmpty ? Array(topics.indices.reversed()) : matched
        for index in order {
            let topic = topics[index]
            var line = "\(topic.id)|\(topic.kind.rawValue)|\(topic.title)"
            if lines.count < 3 {
                for branch in topic.branches.suffix(4) {
                    line += "\n \(branch.id)|\(branch.title)"
                }
            }
            guard size + line.count + 1 <= limit else { continue }
            lines.append(line); size += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    func topicIDs(for sources: Set<UUID>) -> Set<String> {
        Set(topics.filter { topic in
            topic.branches.contains { $0.points.contains { !$0.sources.isDisjoint(with: sources) } }
        }.map(\.id))
    }

    /// Reprocess every source of an affected fact, so correcting one source
    /// does not lose another source that contributed to the same fact.
    func dependentSources(of changed: Set<UUID>) -> Set<UUID> {
        var affected = changed
        let points = topics.flatMap(\.branches).flatMap(\.points)
        var previousCount: Int
        repeat {
            previousCount = affected.count
            for point in points where !point.sources.isDisjoint(with: affected) { affected.formUnion(point.sources) }
        } while affected.count != previousCount
        return affected
    }

    mutating func invalidate(sources: Set<UUID>) {
        for topic in topics.indices {
            for branch in topics[topic].branches.indices {
                topics[topic].branches[branch].points.removeAll { !$0.sources.isDisjoint(with: sources) }
            }
        }
    }

    mutating func pruneEmptyTopics() {
        for topic in topics.indices { topics[topic].branches.removeAll { $0.points.isEmpty } }
        topics.removeAll { $0.branches.isEmpty }
    }

    private struct Addition: Decodable {
        let topic: String
        let kind: Kind
        let title: String?
        let branch: String
        let text: String
        let sources: [Int]
    }

    func adding(_ output: String, batch: SummaryBatch, isDraft: Bool = false) throws -> Self {
        var result = self, aliases: [String: String] = [:]
        let lines = try Self.operationLines(output, isDraft: isDraft)
        var count = 0
        for (offset, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line == "[]" || line.hasPrefix("```") { continue }
            let addition: Addition
            do { addition = try JSONDecoder().decode(Addition.self, from: Data(line.utf8)) }
            catch {
                if isDraft && offset == lines.count - 1 { break }
                throw SummaryError.invalidResult
            }
            count += 1
            guard addition.topic.range(of: #"^(?:T[1-9][0-9]*|new:[1-9][0-9]*)$"#, options: .regularExpression) != nil else {
                throw SummaryError.invalidResult
            }
            guard count <= 8, !addition.text.trimmingCharacters(in: .whitespaces).isEmpty,
                  addition.text.count <= 240, !addition.sources.isEmpty,
                  addition.sources.allSatisfy({ $0 > 0 && $0 <= batch.records.count }),
                  addition.branch.count <= 60, addition.branch.rangeOfCharacter(from: .newlines) == nil,
                  !addition.branch.contains("|") else { throw SummaryError.invalidResult }
            let trimmedBranch = addition.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            let branchTitle = trimmedBranch.isEmpty ? "要点" : trimmedBranch
            let sources = Set(addition.sources.map { batch.records[$0 - 1].sourceID })
            let alias = addition.topic + "|" + addition.kind.rawValue
            var topicIndex: Int?
            if let existing = topics.firstIndex(where: { $0.id == addition.topic }), topics[existing].kind == addition.kind {
                topicIndex = existing
            } else if let id = aliases[alias] {
                topicIndex = result.topics.firstIndex { $0.id == id }
                if let topicIndex, let title = addition.title, Self.key(title) != Self.key(result.topics[topicIndex].title) {
                    // Conflicting labels for one new alias must never make the
                    // first narrow subject a parent of unrelated later facts.
                    throw SummaryError.invalidResult
                }
            }
            if topicIndex == nil {
                guard addition.topic.hasPrefix("new:") || topics.contains(where: { $0.id == addition.topic }),
                      let title = addition.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty, title.count <= 60, title.rangeOfCharacter(from: .newlines) == nil,
                      !title.contains("|") else { throw SummaryError.invalidResult }
                guard result.topics.count < 300 else { throw SummaryError.mapCapacityReached }
                result.topics.append(Topic(id: "T\(result.nextTopic)", title: title, kind: addition.kind, branches: []))
                result.nextTopic += 1
                topicIndex = result.topics.count - 1
                aliases[alias] = result.topics[topicIndex!].id
            }
            guard let topicIndex else { throw SummaryError.invalidResult }
            let sourceTerms = Self.englishTerms(addition.sources.map { batch.records[$0 - 1].text }.joined(separator: " "))
            result.topics[topicIndex].routingTerms.formUnion(sourceTerms)
            if result.topics[topicIndex].routingTerms.count > 256 {
                result.topics[topicIndex].routingTerms = Set(result.topics[topicIndex].routingTerms.sorted().prefix(256))
            }
            var branchIndex = result.topics[topicIndex].branches.firstIndex {
                $0.id == branchTitle || Self.key($0.title) == Self.key(branchTitle)
            }
            if branchIndex == nil {
                guard let first = branchTitle.unicodeScalars.first, (0x4E00...0x9FFF).contains(first.value),
                      !branchTitle.contains("new:") else { throw SummaryError.invalidResult }
                let next = result.topics[topicIndex].nextBranch
                result.topics[topicIndex].branches.append(Branch(id: "B\(next)", title: branchTitle, points: []))
                result.topics[topicIndex].nextBranch += 1
                branchIndex = result.topics[topicIndex].branches.count - 1
            }
            let branch = branchIndex!
            if let existing = result.topics[topicIndex].branches[branch].points.firstIndex(where: { Self.key($0.text) == Self.key(addition.text) }) {
                result.topics[topicIndex].branches[branch].points[existing].sources.formUnion(sources)
            } else {
                guard result.topics.reduce(0, { $0 + $1.branches.reduce(0, { $0 + $1.points.count }) }) < 6_000 else {
                    throw SummaryError.mapCapacityReached
                }
                let identity = result.topics[topicIndex].id + "/" + result.topics[topicIndex].branches[branch].id
                    + sources.map(\.uuidString).sorted().joined(separator: "/") + addition.text
                let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                result.topics[topicIndex].branches[branch].points.append(Point(id: id, text: addition.text, sources: sources))
            }
        }
        guard isDraft || count > 0 || (output.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" || lines.isEmpty) else {
            throw SummaryError.invalidResult
        }
        return result
    }

    /// Production responses use a schema-constrained envelope. Scan complete
    /// objects for previews; final decoding validates the entire envelope.
    private static func operationLines(_ output: String, isDraft: Bool) throws -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\{\s*"additions"\s*:"#, options: .regularExpression) != nil else {
            return output.components(separatedBy: .newlines)
        }
        if !isDraft {
            guard let root = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                  root.count == 1, let items = root["additions"] as? [[String: Any]] else { throw SummaryError.invalidResult }
            return try items.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        }
        guard let arrayStart = trimmed.firstIndex(of: "[") else { return [] }
        var lines: [String] = [], start: String.Index?, depth = 0, quoted = false, escaped = false
        for index in trimmed.indices where index > arrayStart {
            let character = trimmed[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { if depth == 0 { start = index }; depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0, let start { lines.append(String(trimmed[start...index])) }
            }
        }
        return lines
    }

    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func englishTerms(_ text: String) -> Set<String> {
        let common: Set<String> = ["the", "and", "that", "this", "with", "from", "have", "will", "they", "about", "there", "what", "your", "into", "were", "been", "more", "than", "then", "also", "just", "when", "which", "their", "does", "some", "them", "can", "could", "would", "should", "may", "might", "our", "has", "are", "for", "but", "you", "not", "now", "one", "its", "his", "her", "today", "episode", "podcast", "sponsor", "sponsored", "advertisement", "return", "returning", "back", "topic", "discuss", "discussion", "welcome", "talk", "talking", "content", "previous", "earlier", "first", "another"]
        return Set(text.lowercased().components(separatedBy: .letters.inverted).filter {
            $0.count >= 3 && !common.contains($0) && $0.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
        })
    }

    private static func terms(_ text: String) -> Set<String> {
        let common: Set<String> = ["节目", "本期", "本次", "讨论", "话题", "记录", "内容", "广告", "赞助", "刚才", "现在", "回到", "欢迎", "关于", "然后", "继续", "今日", "今天", "我们", "他们", "以及", "信息", "影响", "作用", "方面", "进展", "机制"]
        var result = englishTerms(text)
        let characters = Array(text.unicodeScalars)
        for index in 0..<max(0, characters.count - 1) {
            let pair = characters[index...index + 1]
            if pair.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) {
                let term = String(String.UnicodeScalarView(pair))
                if !common.contains(term) { result.insert(term) }
            }
        }
        return result
    }
}
