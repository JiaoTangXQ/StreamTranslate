import Foundation

struct WordTimestamp: Sendable {
    let word: String
    let start: Float
    let end: Float
    let confidence: Float
}

struct TranscriptionOutput: Sendable {
    let text: String
    let language: SpokenLanguage
    let reportedLanguageCode: String
    let words: [WordTimestamp]
    let averageLogProbability: Float?
    let noSpeechProbability: Float?

    init(
        text: String,
        language: SpokenLanguage,
        reportedLanguageCode: String,
        words: [WordTimestamp],
        averageLogProbability: Float? = nil,
        noSpeechProbability: Float? = nil
    ) {
        self.text = text
        self.language = language
        self.reportedLanguageCode = reportedLanguageCode
        self.words = words
        self.averageLogProbability = averageLogProbability
        self.noSpeechProbability = noSpeechProbability
    }
}

enum TranscriptionTextPolicy {
    static func isDegenerateRepetition(_ text: String) -> Bool {
        let words = text.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }
        guard words.count >= 16 else { return false }

        let maximumPhraseLength = min(8, words.count / 4)
        for phraseLength in 1...maximumPhraseLength {
            var start = 0
            while start + phraseLength <= words.count {
                var repetitionCount = 1
                while start + ((repetitionCount + 1) * phraseLength) <= words.count {
                    let first = words[
                        start..<(start + phraseLength)
                    ]
                    let nextStart = start + (repetitionCount * phraseLength)
                    let next = words[
                        nextStart..<(nextStart + phraseLength)
                    ]
                    guard first.elementsEqual(next) else { break }
                    repetitionCount += 1
                }

                let repeatedWordCount = repetitionCount * phraseLength
                if repetitionCount >= 4,
                   repeatedWordCount >= 16,
                   Double(repeatedWordCount) / Double(words.count) >= 0.5 {
                    return true
                }
                start += repetitionCount > 1 ? repeatedWordCount : 1
            }
        }
        return false
    }

    static func isNonSpeechOnly(_ text: String) -> Bool {
        let value = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return true }

        if value.allSatisfy({ "♪♫♬♩ ".contains($0) }) {
            return true
        }

        let wrappers: [(String, String)] = [
            ("(", ")"), ("[", "]"), ("（", "）"), ("【", "】")
        ]
        guard wrappers.contains(where: {
            value.hasPrefix($0.0) && value.hasSuffix($0.1)
        }) else {
            return false
        }

        let soundLabels = [
            "typing", "keyboard", "clicking", "scissors", "snipping",
            "music", "applause", "clapping", "laughter", "laughing",
            "cough", "noise", "silence", "footsteps", "inaudible",
            "blank_audio", "blank audio",
            "foreign", "foreign language", "speaking chinese",
            "speaking english", "spoken in chinese", "spoken in english",
            "打字", "键盘", "点击", "剪刀", "音乐",
            "掌声", "鼓掌", "笑声", "咳嗽", "噪音", "安静", "脚步",
            "空白_音频", "空白音频"
        ]
        return soundLabels.contains { value.contains($0) }
    }
}
