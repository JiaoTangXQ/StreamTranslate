import Foundation

struct CapturedAudioChunk: Sendable {
    let samples: [Float]
    let sequence: Int64
    let capturedAt: Date
    let sourceTimestamp: Double?
}

struct StreamingTranscriptionUpdate: Sendable {
    let output: TranscriptionOutput
    let startSample: Int64
    let endSample: Int64
    let isFinal: Bool
    let processingLatency: TimeInterval
}

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

protocol StreamingTranscriptionProviding: AnyObject, Sendable {
    func updates(
        from audioStream: AsyncStream<CapturedAudioChunk>,
        vocabulary: String
    ) -> AsyncThrowingStream<StreamingTranscriptionUpdate, Error>

    func cancel()
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

        // SpeechAnalyzer may emit a trailing punctuation-only range after a
        // complete sentence. Do not create or translate a caption containing
        // just "。" / "."; retain short words and numbers such as "15%".
        guard value.contains(where: { $0.isLetter || $0.isNumber }) else { return true }

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

    /// Credits Whisper copies from its subtitle training data when it hears
    /// music, applause or silence, e.g. "(字幕:J Chong)" or "字幕由Amara.org社区提供".
    /// Ordinary speech that mentions subtitles is kept.
    static func isKnownHallucination(_ text: String) -> Bool {
        let value = text.lowercased()
        let credits = ["amara.org", "j chong", "明镜与点点", "明鏡與點點", "请不吝点赞", "請不吝點贊", "点点栏目", "點點欄目"]
        if credits.contains(where: { value.contains($0) }) { return true }
        guard value.contains("字幕") else { return false }
        let markers = ["(", "（", "cc by", "字幕君", "字幕組:", "字幕组:", "字幕組：", "字幕组：",
                       "字幕由", "字幕提供", "字幕志愿者", "字幕志願者", "字幕補助", "字幕补助"]
        return markers.contains { value.contains($0) }
    }
}
