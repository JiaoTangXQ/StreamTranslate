import Foundation

struct CaptionEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let englishText: String
    let chineseText: String
    let sourceLanguage: SpokenLanguage

    init(
        id: UUID = UUID(),
        timestamp: Date,
        englishText: String,
        chineseText: String,
        sourceLanguage: SpokenLanguage = .english
    ) {
        self.id = id
        self.timestamp = timestamp
        self.englishText = englishText
        self.chineseText = chineseText
        self.sourceLanguage = sourceLanguage
    }

    var originalText: String {
        switch sourceLanguage {
        case .english: return englishText
        case .chinese: return chineseText
        case .unknown: return englishText.isEmpty ? chineseText : englishText
        }
    }

    var translatedText: String {
        switch sourceLanguage {
        case .english: return chineseText
        case .chinese: return englishText
        case .unknown: return ""
        }
    }
}
