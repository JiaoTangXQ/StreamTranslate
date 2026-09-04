import Foundation

struct StabilizedCaptionText: Equatable, Sendable {
    let stable: String
    let draft: String

    var fullText: String {
        stable + draft
    }
}

/// Turns Whisper's repeatedly rewritten snapshots into a monotonic reading
/// surface. Text is committed only after it agrees across two snapshots, and
/// a small trailing window remains editable so Whisper can still correct the
/// words nearest the live edge.
struct CaptionTextStabilizer: Sendable {
    private var segmentStartSample: Int64?
    private var previousTokens: [Token] = []
    private var committedTokenCount = 0
    private var committedKeys: [String] = []
    private var committedText = ""

    mutating func update(
        text: String,
        segmentStartSample: Int64,
        language: SpokenLanguage
    ) -> StabilizedCaptionText {
        if self.segmentStartSample != segmentStartSample {
            reset(for: segmentStartSample)
        }

        let tokens = Self.tokens(in: text)
        if !previousTokens.isEmpty {
            let agreementCount = Self.commonPrefixCount(previousTokens, tokens)
            let holdback = language == .chinese ? 4 : 2
            let targetCount = max(
                committedTokenCount,
                agreementCount - min(holdback, agreementCount)
            )
            commit(
                through: min(targetCount, tokens.count),
                tokens: tokens,
                text: text
            )
        }

        previousTokens = tokens
        return presentation(for: text, tokens: tokens)
    }

    mutating func finalize(
        text: String,
        segmentStartSample: Int64
    ) -> StabilizedCaptionText {
        if self.segmentStartSample != segmentStartSample {
            reset(for: segmentStartSample)
        }

        let tokens = Self.tokens(in: text)
        committedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        committedTokenCount = tokens.count
        committedKeys = tokens.map(\.key)
        previousTokens = tokens

        return StabilizedCaptionText(
            stable: committedText,
            draft: ""
        )
    }

    mutating func reset() {
        segmentStartSample = nil
        previousTokens = []
        committedTokenCount = 0
        committedKeys = []
        committedText = ""
    }

    static func semanticUnitCount(in text: String) -> Int {
        tokens(in: text).count
    }

    private mutating func reset(for segmentStartSample: Int64) {
        reset()
        self.segmentStartSample = segmentStartSample
    }

    private mutating func commit(
        through targetCount: Int,
        tokens: [Token],
        text: String
    ) {
        guard targetCount > committedTokenCount else { return }
        guard committedKeys.elementsEqual(
            tokens.prefix(committedTokenCount).map(\.key)
        ) else { return }
        let start = boundaryIndex(in: text, tokens: tokens)
        let end = tokens[targetCount - 1].range.upperBound
        committedText += String(text[start..<end])
        committedKeys.append(
            contentsOf: tokens[committedTokenCount..<targetCount].map(\.key)
        )
        committedTokenCount = targetCount
    }

    private func presentation(
        for text: String,
        tokens: [Token]
    ) -> StabilizedCaptionText {
        let boundary = boundaryIndex(in: text, tokens: tokens)
        return StabilizedCaptionText(
            stable: committedText.trimmingCharacters(in: .whitespacesAndNewlines),
            draft: continuation(in: text, from: boundary)
        )
    }

    /// Normally the uncommitted suffix still includes Whisper's original
    /// whitespace. If the hypothesis was completely rewritten there is no
    /// overlap boundary, so restore an English word separator without adding
    /// artificial spaces between CJK characters.
    private func continuation(
        in text: String,
        from boundary: String.Index
    ) -> String {
        let remainder = String(text[boundary...])
        guard boundary == text.startIndex,
              let previous = committedText.last,
              let next = remainder.first,
              !previous.isWhitespace,
              !next.isWhitespace,
              !Self.isCJK(previous),
              !Self.isCJK(next),
              next.isLetter || next.isNumber else {
            return remainder
        }
        return " " + remainder
    }

    private func boundaryIndex(
        in text: String,
        tokens: [Token]
    ) -> String.Index {
        guard !committedKeys.isEmpty, !tokens.isEmpty else { return text.startIndex }

        if committedKeys.elementsEqual(tokens.prefix(committedKeys.count).map(\.key)) {
            return tokens[committedKeys.count - 1].range.upperBound
        }

        let maximumOverlap = min(committedKeys.count, tokens.count)
        for overlap in stride(from: maximumOverlap, through: 1, by: -1) {
            let committedSuffix = committedKeys.suffix(overlap)
            let latestPossibleEnd = min(tokens.count, committedKeys.count + 2)
            guard latestPossibleEnd >= overlap else { continue }
            for end in overlap...latestPossibleEnd {
                let candidate = tokens[(end - overlap)..<end].map(\.key)
                if committedSuffix.elementsEqual(candidate) {
                    return tokens[end - 1].range.upperBound
                }
            }
        }
        return text.startIndex
    }

    private static func commonPrefixCount(
        _ left: [Token],
        _ right: [Token]
    ) -> Int {
        var count = 0
        while count < left.count,
              count < right.count,
              left[count].key == right[count].key {
            count += 1
        }
        return count
    }

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if isCJK(character) {
                result.append(Token(
                    key: String(character),
                    range: index..<next
                ))
                index = next
                continue
            }

            guard isWordCharacter(character) else {
                index = next
                continue
            }

            let start = index
            index = next
            while index < text.endIndex {
                let candidate = text[index]
                guard isWordCharacter(candidate), !isCJK(candidate) else { break }
                index = text.index(after: index)
            }
            let value = text[start..<index]
                .lowercased()
                .replacingOccurrences(of: "’", with: "'")
            result.append(Token(key: value, range: start..<index))
        }

        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "'"
            || character == "’"
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                true
            default:
                false
            }
        }
    }

    private struct Token: Sendable {
        let key: String
        let range: Range<String.Index>
    }
}

enum PartialTranslationPolicy {
    static func shouldRequest(
        previousText: String,
        stableText: String,
        language: SpokenLanguage
    ) -> Bool {
        let stable = stableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stable.isEmpty, stable != previousText else { return false }

        let previousCount = CaptionTextStabilizer.semanticUnitCount(in: previousText)
        let currentCount = CaptionTextStabilizer.semanticUnitCount(in: stable)
        let requiredGrowth = language == .chinese ? 10 : 5
        let endsPhrase = stable.last.map {
            ".!?。！？;；:：".contains($0)
        } ?? false

        return previousText.isEmpty
            || currentCount - previousCount >= requiredGrowth
            || endsPhrase
    }
}
