import Foundation

/// Detect comparable numeric/fraction mismatches, not general semantic truth.
/// Unparsed formats and unit conversions are deliberately not guessed.
enum TranslationIntegrityPolicy {
    /// Resolve a narrow, explicit grammatical ellipsis without asking a small
    /// model to separate source from background (which leaked prior sentences).
    /// Keep raw ASR untouched; only the translation input is made self-contained.
    static func resolvedEllipsis(_ source: String, context: String, language: SpokenLanguage) -> String? {
        guard shouldUseContext(source, language: language), language == .english,
              let current = matches(#"(?i)^\s*(I|we|you|they) no longer do[.!?]?\s*$"#, source).first,
              let prior = matches(#"(?i)(?:^|[.!?]\s+)(I|we|you|they) used to ([^.!?]+)[.!?]?\s*$"#,
                String(context.suffix(600))).last,
              current[1].lowercased() == prior[1].lowercased() else { return nil }
        let complement = prior[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !complement.isEmpty, complement.split(whereSeparator: { $0.isWhitespace }).count <= 20,
              !complement.contains(where: { ";:\n".contains($0) }),
              matches(#"(?i)^(not|never|no)\b"#, complement).isEmpty else { return nil }
        return current[1] + " no longer " + complement + "."
    }

    static func precisionInstruction(for source: String, language: SpokenLanguage) -> String {
        let applicable: Bool
        if language == .english {
            applicable = !matches(#"(?i)\bby\b"#, source).isEmpty
                && !matches(#"(?i)\bto\b"#, source).isEmpty
                && !matches(#"(?i)\b(reduced?|decreased?|increased?|fell|fall|rose|rise|grew|grow|cut)\b"#, source).isEmpty
        } else {
            applicable = source.contains("到") && !matches(#"(降低|减少|下降|增加|增长|上升|降)[到了]+"#, source).isEmpty
        }
        guard applicable else { return "" }
        return "When translating numerical changes, distinguish the amount of change ('by') from the resulting value ('to'); preserve this distinction in both clauses. A percent change is not a percentage-point change; do not substitute one for the other.\n"
    }

    /// Preserve an explicitly stated percent unit. Some model outputs replace
    /// it with percentage points even under an explicit instruction. Change no
    /// values, and never apply this when the source actually says points.
    static func normalizedPercentUnits(_ translation: String, source: String) -> String {
        let points = #"(?i)percentage[- ]points?|百分点|百分點"#
        guard matches(points, source).isEmpty,
              !matches(#"(?i)%|\bpercent\b|百分之"#, source).isEmpty else { return translation }
        var result = translation.replacingOccurrences(of: #"(?<=\d)\s*个?百分点|(?<=\d)\s*個?百分點"#,
            with: "%", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\bpercentage[- ]points?\b"#,
            with: "percent", options: .regularExpression)
        return result
    }

    static func shouldUseContext(_ source: String, language: SpokenLanguage) -> Bool {
        guard language == .english, source.split(whereSeparator: { $0.isWhitespace }).count <= 8,
              !source.contains(where: { $0.isNumber }),
              matches(#"(?i)\b(one|two|three|four|five|six|seven|eight|nine|ten|half|third|quarter|percent|twice)\b"#, source).isEmpty else { return false }
        guard !matches(#"(?i)^\s*(i|we|you|they|he|she|it|this|that|these|those|not until)\b"#, source).isEmpty else { return false }
        // A leading pronoun alone does not make a sentence elliptical. Passing
        // background for a complete cash-eviction sentence made the model
        // invent memory exhaustion in a real replay.
        return !matches(#"(?i)(\b(do|does|did|so|not|empty|same|too|either|neither)\s*[.!?]*$|^\s*not until\b)"#, source).isEmpty
    }

    static func accepts(_ translation: String, for source: String) -> Bool {
        guard !TranscriptionTextPolicy.isNonSpeechOnly(translation),
              !TranscriptionTextPolicy.isDegenerateRepetition(translation) else { return false }
        let points = #"(?i)percentage[- ]points?|百分点|百分點"#
        if matches(points, source).isEmpty != matches(points, translation).isEmpty { return false }
        let promptLabel = #"(?i)^\s*[\[【]\s*(source text|源文本|原文|background information|背景信息|背景資訊)\s*[\]】]"#
        let mentionsLabel = ["source text", "源文本", "原文", "background information", "背景信息", "背景資訊"]
            .contains { source.localizedCaseInsensitiveContains($0) }
        if !mentionsLabel, !matches(promptLabel, translation).isEmpty { return false }
        // A weak semantic safety net, not a complete negation/entailment test.
        // An explicit negative clause must not disappear completely. Some valid
        // positive paraphrases may keep the fast translation instead.
        let explicitEnglishNegative = #"(?i)\b(not|no|never|neither|nor|without|cannot)\b|n['’]t\b"#
        let explicitChineseNegative = #"不是|不能|不要|不得|不再|并不|並不|没有|沒有|还没|還沒|尚未|未能|禁止|并非|並非"#
        let targetChineseNegative = #"[不没沒未无無非否]|禁止|避免|缺乏|尚待|保持不变|保持不變"#
        let targetEnglishNegative = #"(?i)\b(not|no|never|neither|nor|without|cannot|unable|impossible|avoid|avoided|avoiding|lack|lacks|lacking|unless|until|instead|rather|unchanged)\b|n['’]t\b|remain\w* the same"#
        if !matches(explicitEnglishNegative, source).isEmpty,
           !matches(#"[\p{Han}]"#, translation).isEmpty,
           matches(targetChineseNegative, translation).isEmpty { return false }
        if !matches(explicitChineseNegative, source).isEmpty,
           matches(#"[\p{Han}]"#, translation).isEmpty,
           matches(targetEnglishNegative, translation).isEmpty { return false }
        let originalFractions = fractions(source), translatedFractions = fractions(translation)
        if !originalFractions.isEmpty, !translatedFractions.isEmpty,
           !sameValues(originalFractions, translatedFractions, relativeTolerance: 0.01) { return false }
        // A change from 3.5 万 to 35,000 is valid, but this small checker is not
        // a universal unit parser. Only compare literal numerals without scale.
        let scalePattern = #"(?i)\d[\d.,]*\s*(万|千|百|亿|[kmb]\b|thousand\b|million\b|billion\b)"#
        if matches(scalePattern, source + " " + translation).isEmpty {
            let originalNumbers = arabicNumbers(source), translatedNumbers = arabicNumbers(translation)
            if !originalNumbers.isEmpty, !translatedNumbers.isEmpty,
               !sameValues(originalNumbers, translatedNumbers, relativeTolerance: 0.000001) { return false }
        }
        return true
    }

    private static func sameValues(_ lhs: [Double], _ rhs: [Double], relativeTolerance: Double) -> Bool {
        func contains(_ values: [Double], _ number: Double) -> Bool {
            values.contains { abs($0 - number) <= max(abs(number) * relativeTolerance, 0.00000001) }
        }
        return lhs.allSatisfy { contains(rhs, $0) } && rhs.allSatisfy { contains(lhs, $0) }
    }

    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let value = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: value.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : value.substring(with: range)
            }
        }
    }

    private static func arabicNumbers(_ text: String) -> [Double] {
        matches(#"\d+(?:[.,]\d+)*"#, text).compactMap {
            guard let value = Double($0[0].replacingOccurrences(of: ",", with: "")), value.isFinite else { return nil }
            return value
        }
    }

    private static func fractions(_ text: String) -> [Double] {
        var result: [Double] = []
        let numerators = ["a": 1.0, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
                          "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
        let denominators = ["half": 2.0, "halves": 2, "third": 3, "quarter": 4,
                            "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]
        let english = #"(?i)\b(a|an|one|two|three|four|five|six|seven|eight|nine|\d+)[\s-]+(half|halves|thirds?|quarters?|fourths?|fifths?|sixths?|sevenths?|eighths?|ninths?|tenths?)\b(?=\s*(?:$|[,.!?;:]|of\b|and\b|not\b|more\b|less\b|as\b))"#
        for match in matches(english, text) {
            let word = match[2].lowercased()
            if let numerator = numerators[match[1].lowercased()] ?? Double(match[1]),
               let denominator = denominators[word] ?? denominators[String(word.dropLast())] {
                result.append(numerator / denominator)
            }
        }
        for match in matches(#"(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)"#, text) {
            if let numerator = Double(match[1]), let denominator = Double(match[2]), denominator > 0 {
                result.append(numerator / denominator)
            }
        }
        for match in matches(#"([零〇一二两三四五六七八九十百千万\d]+)分之([零〇一二两三四五六七八九十百千万\d]+)"#, text) {
            if let denominator = chineseInteger(match[1]), let numerator = chineseInteger(match[2]), denominator > 0 {
                result.append(Double(numerator) / Double(denominator))
            }
        }
        for match in matches(#"(?i)(\d+(?:\.\d+)?)\s*(?:%|percent\b)"#, text) {
            if let value = Double(match[1]) { result.append(value / 100) }
        }
        return result.filter { $0.isFinite }
    }

    private static func chineseInteger(_ text: String) -> Int? {
        if let number = Int(text) { return number }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3,
                                       "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        var total = 0, section = 0, number = 0
        for character in text {
            if let unit = units[character] { section += max(1, number) * unit; number = 0 }
            else if character == "万" { total += max(1, section + number) * 10_000; section = 0; number = 0 }
            else if let digit = digits[character] ?? character.wholeNumberValue, digit < 10 { number = digit }
            else { return nil }
        }
        return total + section + number
    }
}
