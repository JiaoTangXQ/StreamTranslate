import Foundation
import NaturalLanguage

/// Translation follows the current recognition hypothesis, not the frozen
/// reading surface. Preserve lexical and punctuation boundaries at its live edge.
enum TranslationDraftPlanner {
    static let initialSettleDelay: Duration = .milliseconds(250)

    static func prefix(in text: String, language: SpokenLanguage) -> String {
        let ranges = wordRanges(in: text, language: language)
        guard !ranges.isEmpty else { return "" }
        let holdback = 2
        var boundary = ranges.count > holdback ? ranges[ranges.count - holdback - 1].upperBound : text.startIndex
        // Include punctuation attached to the last retained word, such as %.
        if boundary > text.startIndex {
            while boundary < text.endIndex, !text[boundary].isLetter, !text[boundary].isNumber {
                boundary = text.index(after: boundary)
            }
        }
        // A complete short clause should not wait for two more spoken words.
        for index in text.indices where isClauseBoundary(in: text, at: index) {
            let end = text.index(after: index)
            let phrase = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if end > boundary, isUsefulShortPhrase(phrase, language: language) { boundary = end }
        }
        var result = String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Never end a speculative prefix inside a quantity or at an unfinished
        // connective. The next recognition update supplies the missing context.
        while !result.isEmpty, hasUnsafeEnding(result, language: language) {
            guard let last = wordRanges(in: result, language: language).last else { return "" }
            result = String(result[..<last.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func canSettleInitialPhrase(_ text: String, language: SpokenLanguage) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isUsefulShortPhrase(value, language: language)
            && CaptionTextStabilizer.semanticUnitCount(in: value) <= (language == .chinese ? 6 : 4)
            && !hasUnsafeEnding(value, language: language)
    }

    static func hasEnoughContext(_ text: String, language: SpokenLanguage) -> Bool {
        PartialTranslationPolicy.hasEnoughContext(text, language: language)
            || (language == .chinese && isUsefulShortPhrase(text, language: language)
                && !hasUnsafeEnding(text, language: language))
    }

    /// Preserve paired conditions when requesting a pause-based ASR commit.
    /// Do not reuse speculative word-tail checks here: a real audio pause may
    /// finish a number before its volatile percent/unit token has arrived.
    /// The recognizer's own finals and stop-time finalization remain authoritative.
    static func hasClosedChineseConditions(_ text: String) -> Bool {
        for (opening, closing) in [("只有", "才"), ("只要", "就")] {
            if let range = text.range(of: opening, options: .backwards),
               !text[range.upperBound...].contains(closing) { return false }
        }
        return true
    }

    private static func isUsefulShortPhrase(_ text: String, language: SpokenLanguage) -> Bool {
        let ranges = wordRanges(in: text, language: language)
        return ranges.count >= 2 && (language != .chinese || CaptionTextStabilizer.semanticUnitCount(in: text) >= 3)
    }

    private static func wordRanges(in text: String, language: SpokenLanguage) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(language == .chinese ? .simplifiedChinese : .english)
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
    }

    private static func isClauseBoundary(in text: String, at index: String.Index) -> Bool {
        let character = text[index]
        guard ".,!?;:。！？，；：".contains(character) else { return false }
        if ".,:".contains(character), index > text.startIndex {
            let next = text.index(after: index)
            // Decimal numbers, thousands separators, and clock times.
            if text[text.index(before: index)].isNumber,
               next < text.endIndex, text[next].isNumber { return false }
            if character == ".", next < text.endIndex, !text[next].isWhitespace { return false }
        }
        return true
    }

    static func hasUnsafeEnding(_ text: String, language: SpokenLanguage) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        if last.isNumber { return true }
        if ".!?。！？;；".contains(last) { return false }
        guard let range = wordRanges(in: trimmed, language: language).last else { return true }
        let word = trimmed[range].lowercased()
        let english: Set<String> = ["a", "an", "the", "of", "to", "by", "for", "with", "without", "until", "unless", "if", "and", "or", "but", "not", "no", "is", "are", "was", "were", "will", "would", "can", "could", "should", "must", "in", "at", "than", "as", "i", "we", "you", "they", "he", "she", "it", "this", "that", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "fifteen", "fifty", "hundred", "thousand",
            "have", "has", "had", "been", "being", "do", "does", "did", "already", "still",
            "rule", "ruled", "look", "looked", "looking", "give", "gave", "given", "put", "get", "got", "getting", "take", "took", "taken"]
        let chinese: Set<String> = ["的", "地", "得", "了", "将", "在", "把", "被", "不", "不是", "是", "和", "或", "但", "如果", "除非", "因为", "所以", "比", "第", "我", "我们", "你", "你们", "他", "她", "它", "他们", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万",
            "已经", "正在", "仍然", "仍", "还", "也", "就", "才", "会", "要", "能", "可以", "能够", "应该", "需要",
            "没有", "并未", "尚未", "未", "没", "只要", "只有", "才能", "从", "到"]
        return (language == .chinese ? chinese : english).contains(word)
    }
}
