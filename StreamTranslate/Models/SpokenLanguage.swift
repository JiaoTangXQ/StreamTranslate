import Foundation

enum SpokenLanguage: String, Codable, Sendable {
    case english = "en"
    case chinese = "zh"
    case unknown = "und"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        case .unknown: return "Unknown"
        }
    }

    /// Whisper normally returns `en` or `zh`. Character inspection is a
    /// fallback for very short utterances, where acoustic language detection
    /// is less reliable.
    static func resolve(whisperCode: String, text: String) -> SpokenLanguage {
        let normalizedCode = whisperCode.lowercased()
        let counts = scriptCounts(in: text)
        let scriptTotal = counts.han + counts.latin

        if counts.han >= 2,
           scriptTotal == 0 || Double(counts.han) / Double(scriptTotal) >= 0.3 {
            return .chinese
        }
        if normalizedCode == "zh"
            || normalizedCode.hasPrefix("zh-")
            || normalizedCode == "cmn"
            || normalizedCode == "yue" {
            return .chinese
        }
        if normalizedCode == "en" || normalizedCode.hasPrefix("en-") {
            return .english
        }
        if normalizedCode.isEmpty, counts.latin >= 2 {
            return .english
        }
        return .unknown
    }

    private static func scriptCounts(in text: String) -> (han: Int, latin: Int) {
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                han += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            default:
                break
            }
        }
        return (han, latin)
    }
}

enum TranslationDirection: CaseIterable, Hashable, Sendable {
    case englishToChinese
    case chineseToEnglish

    var sourceLanguage: SpokenLanguage {
        switch self {
        case .englishToChinese: return .english
        case .chineseToEnglish: return .chinese
        }
    }

    static func forSource(_ language: SpokenLanguage) -> TranslationDirection? {
        switch language {
        case .english: return .englishToChinese
        case .chinese: return .chineseToEnglish
        case .unknown: return nil
        }
    }
}
