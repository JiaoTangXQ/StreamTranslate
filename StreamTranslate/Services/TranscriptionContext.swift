import Foundation

struct RecognizedSegment: Sendable {
    let segment: SpeechSegment
    let output: TranscriptionOutput
}

struct ContextualAudio: Sendable {
    let samples: [Float]
    let currentAudioOffset: TimeInterval
}

struct TranscriptionContext: Sendable {
    private static let sampleRate = 16_000
    private static let maximumContextGapSamples: Int64 = 12 * 16_000
    private static let maximumAudioContextGapSamples: Int64 = 6 * 16_000
    private static let maximumAudioContextSamples: Int64 = 30 * 16_000

    private(set) var partial: RecognizedSegment?
    private(set) var final: RecognizedSegment?
    private var finalHistory: [RecognizedSegment] = []
    private var languageSegmentStartSample: Int64?
    private var languageCandidate: SpokenLanguage?
    private var languageAgreementCount = 0
    private var lockedLanguage: SpokenLanguage?

    mutating func reset() {
        partial = nil
        final = nil
        finalHistory = []
        resetLanguageTracking()
    }

    mutating func recordPartial(
        segment: SpeechSegment,
        output: TranscriptionOutput
    ) {
        partial = RecognizedSegment(segment: segment, output: output)
        recordLanguage(output.language, for: segment)
    }

    mutating func recordFinal(
        segment: SpeechSegment,
        output: TranscriptionOutput
    ) {
        let recognized = RecognizedSegment(segment: segment, output: output)
        final = recognized
        finalHistory.append(recognized)
        finalHistory.removeAll {
            segment.endSample - $0.segment.startSample
                > Self.maximumAudioContextSamples
        }
        partial = nil
        resetLanguageTracking()
    }

    func partial(for segment: SpeechSegment) -> RecognizedSegment? {
        guard partial?.segment.startSample == segment.startSample else { return nil }
        return partial
    }

    func recentFinal(for segment: SpeechSegment) -> RecognizedSegment? {
        guard let final else { return nil }
        let gap = segment.startSample - final.segment.endSample
        guard gap >= 0, gap <= Self.maximumContextGapSamples else { return nil }
        return final
    }

    func lockedLanguage(for segment: SpeechSegment) -> SpokenLanguage? {
        guard languageSegmentStartSample == segment.startSample else { return nil }
        return lockedLanguage
    }

    func prompt(
        for segment: SpeechSegment,
        language: SpokenLanguage,
        vocabulary: String = ""
    ) -> String? {
        var context: [String] = []
        var nextStartSample = segment.startSample

        for recognized in finalHistory.reversed() {
            let gap = nextStartSample - recognized.segment.endSample
            guard gap >= 0,
                  gap <= Self.maximumContextGapSamples else { break }
            if recognized.output.language == language {
                context.append(recognized.output.text)
                if context.count == 3 { break }
            }
            nextStartSample = recognized.segment.startSample
        }

        var parts: [String] = []
        let terms = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            parts.append(context.reversed().joined(separator: " "))
        }
        if !terms.isEmpty {
            parts.append("Vocabulary: \(terms)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func contextualAudio(
        for segment: SpeechSegment,
        language: SpokenLanguage
    ) -> ContextualAudio? {
        var selected: [RecognizedSegment] = []
        var nextStartSample = segment.startSample

        for recognized in finalHistory.reversed() {
            let gap = nextStartSample - recognized.segment.endSample
            guard gap >= 0,
                  gap <= Self.maximumAudioContextGapSamples,
                  recognized.output.language == language,
                  segment.endSample - recognized.segment.startSample
                    <= Self.maximumAudioContextSamples else {
                break
            }
            selected.append(recognized)
            nextStartSample = recognized.segment.startSample
        }

        guard let first = selected.last else { return nil }
        let orderedSegments = selected.reversed().map(\.segment) + [segment]
        var samples: [Float] = []
        samples.reserveCapacity(Int(segment.endSample - first.segment.startSample))
        var cursor = first.segment.startSample

        for item in orderedSegments {
            let gap = item.startSample - cursor
            if gap > 0 {
                samples.append(contentsOf: repeatElement(0, count: Int(gap)))
            }

            let overlap = max(0, cursor - item.startSample)
            if overlap < item.samples.count {
                samples.append(contentsOf: item.samples.dropFirst(Int(overlap)))
            }
            cursor = max(cursor, item.endSample)
        }

        let currentOffsetSamples = segment.startSample - first.segment.startSample
        return ContextualAudio(
            samples: samples,
            currentAudioOffset: TimeInterval(currentOffsetSamples)
                / TimeInterval(Self.sampleRate)
        )
    }

    private mutating func recordLanguage(
        _ language: SpokenLanguage,
        for segment: SpeechSegment
    ) {
        guard language != .unknown else { return }
        if languageSegmentStartSample != segment.startSample {
            resetLanguageTracking()
            languageSegmentStartSample = segment.startSample
        }

        if languageCandidate == language {
            languageAgreementCount += 1
        } else {
            languageCandidate = language
            languageAgreementCount = 1
            lockedLanguage = nil
        }
        if languageAgreementCount >= 2 {
            lockedLanguage = language
        }
    }

    private mutating func resetLanguageTracking() {
        languageSegmentStartSample = nil
        languageCandidate = nil
        languageAgreementCount = 0
        lockedLanguage = nil
    }
}

enum TranscriptionSelectionPolicy {
    static let languageRetryMaximumSamples = 40_000
    static let finalStabilityMaximumAddedSamples = 9_600

    static func shouldRetryWithContextLanguage(
        automatic: TranscriptionOutput?,
        context: RecognizedSegment,
        sampleCount: Int
    ) -> Bool {
        guard sampleCount <= languageRetryMaximumSamples else { return false }
        guard let automatic else { return true }
        return automatic.language != context.output.language
    }

    static func shouldRetryUnsupportedLanguage(
        _ automatic: TranscriptionOutput?
    ) -> Bool {
        guard let code = automatic?.reportedLanguageCode.lowercased() else {
            return false
        }
        let isEnglish = code == "en" || code.hasPrefix("en-")
        let isChinese = code == "zh"
            || code.hasPrefix("zh-")
            || code == "cmn"
            || code == "yue"
        return !isEnglish && !isChinese
    }

    static func chooseBestScoredResult(
        _ candidates: [TranscriptionOutput?]
    ) -> TranscriptionOutput? {
        candidates.compactMap { $0 }.filter {
            $0.language != .unknown
                && !TranscriptionTextPolicy.isNonSpeechOnly($0.text)
        }.max { left, right in
            let leftScore = left.averageLogProbability ?? -.infinity
            let rightScore = right.averageLogProbability ?? -.infinity
            return leftScore < rightScore
        }
    }

    static func chooseLanguageResult(
        automatic: TranscriptionOutput?,
        contextual: TranscriptionOutput?
    ) -> TranscriptionOutput? {
        guard let automatic else { return contextual }
        guard let contextual else { return automatic }
        guard let automaticScore = automatic.averageLogProbability,
              let contextualScore = contextual.averageLogProbability else {
            return automatic
        }
        return contextualScore > automaticScore ? contextual : automatic
    }

    static func chooseFinalResult(
        candidate: TranscriptionOutput?,
        previousPartial: RecognizedSegment?,
        finalSegment: SpeechSegment
    ) -> TranscriptionOutput? {
        guard let previousPartial else { return candidate }
        guard let candidate else { return previousPartial.output }
        guard candidate.language == previousPartial.output.language else {
            return candidate
        }

        // A final pass sometimes returns a confident sentence fragment even
        // though repeated preview passes decoded the complete utterance. The
        // final segment contains all preview audio, so a same-language result
        // covering at most one third of a substantial preview is truncation,
        // not a plausible final correction.
        if isCatastrophicallyShorter(
            candidate.text,
            than: previousPartial.output.text
        ) {
            return previousPartial.output
        }

        let changedSamples = abs(
            finalSegment.samples.count - previousPartial.segment.samples.count
        )
        guard changedSamples <= finalStabilityMaximumAddedSamples else {
            return candidate
        }

        let candidateWords = words(in: candidate.text)
        let partialWords = words(in: previousPartial.output.text)
        let candidateScore = candidate.averageLogProbability ?? -.infinity
        let partialScore = previousPartial.output.averageLogProbability ?? -.infinity
        if candidateWords.count < partialWords.count,
           candidateScore <= partialScore {
            return previousPartial.output
        }
        if similarity(candidateWords, partialWords) < 0.5,
           candidateScore <= partialScore {
            return previousPartial.output
        }
        return candidate
    }


    static func chooseAudioContextResult(
        currentOnly: TranscriptionOutput?,
        contextual: TranscriptionOutput?
    ) -> TranscriptionOutput? {
        guard let currentOnly else { return contextual }
        guard let contextual else { return currentOnly }
        if contextual.language == currentOnly.language,
           isCatastrophicallyShorter(
               contextual.text,
               than: currentOnly.text
           ) {
            return currentOnly
        }
        return contextual
    }

    private static func isCatastrophicallyShorter(
        _ candidate: String,
        than reference: String
    ) -> Bool {
        let candidateUnitCount = CaptionTextStabilizer.semanticUnitCount(
            in: candidate
        )
        let referenceUnitCount = CaptionTextStabilizer.semanticUnitCount(
            in: reference
        )
        return referenceUnitCount >= 6
            && candidateUnitCount * 3 <= referenceUnitCount
    }

    private static func words(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
    }

    private static func similarity(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count)
            / Double(max(left.count, right.count))
    }
}
