import Foundation

/// Decides which of two simultaneous Apple recognizers (en_US and zh_CN) is
/// transcribing the language actually spoken, and forwards only that stream.
///
/// The zh_CN model is the language detector: it writes Chinese speech as Han
/// characters and English speech as Latin words, already on volatile results.
/// The en_US model gives no script signal on Chinese audio, only very low final
/// confidence, so it is used just for the first decision and as a tie-break.
///
/// Both recognizers see every sample once. Nothing is resubmitted on a switch;
/// tokens that cover audio already committed by the other language are trimmed
/// by their audio time range, and finals from the inactive recognizer are kept
/// briefly so a late switch can still commit them instead of losing a sentence.
struct BilingualRecognitionArbiter {
    /// 0.2 s at 16 kHz.
    static let tolerance: Int64 = 3_200
    static let lowEnglishConfidence = 0.35
    static let trustedEnglishConfidence = 0.6
    static let firstDecisionEnglishConfidence = 0.8

    private(set) var active: SpokenLanguage?
    private(set) var committedThrough: Int64 = 0
    private var pending: (language: SpokenLanguage, votes: Int)?
    private var shadowFinals: [SpokenLanguage: [AppleRecognitionResult]] = [:]

    mutating func accept(_ result: AppleRecognitionResult, from source: SpokenLanguage) -> [StreamingTranscriptionUpdate] {
        var output: [StreamingTranscriptionUpdate] = []
        if let evidence = evidence(for: result, from: source) {
            if active == nil {
                output += switchTo(evidence)
            } else if evidence == active {
                pending = nil
            } else {
                let votes = (pending?.language == evidence ? pending?.votes ?? 0 : 0) + 1
                pending = (evidence, votes)
                // Two agreeing updates, or a zh_CN final, confirm a change.
                if votes >= 2 || (result.isFinal && source == .chinese) {
                    output += switchTo(evidence)
                }
            }
        }
        if result.isFinal, source == .english, source == active, let pending, pending.language != source,
           (result.confidence ?? 1) < Self.trustedEnglishConfidence {
            // Committing this final while Chinese is already indicated would
            // freeze a mistranscribed caption. A zh_CN final is judged by its
            // own script above instead.
            output += switchTo(pending.language)
        } else if result.isFinal, source == .english, source == active,
                  (result.confidence ?? 0) >= Self.trustedEnglishConfidence {
            pending = nil
        }
        guard source == active else {
            if result.isFinal { remember(result, from: source) }
            return output
        }
        if let update = forward(result, from: source) { output.append(update) }
        return output
    }

    /// Classify the zh_CN text written for audio not yet committed.
    static func scriptLanguage(_ text: String) -> SpokenLanguage? {
        var han = 0, latinWords = 0, inWord = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                han += 1; inWord = false
            case 0x41...0x5A, 0x61...0x7A:
                if !inWord { latinWords += 1; inWord = true }
            case 0x27, 0x2019:
                break // apostrophes stay inside an English word
            default:
                inWord = false
            }
        }
        if han >= 3, han >= latinWords * 2 { return .chinese }
        if latinWords >= 3, han * 3 <= latinWords { return .english }
        return nil
    }

    private func evidence(for result: AppleRecognitionResult, from source: SpokenLanguage) -> SpokenLanguage? {
        switch source {
        case .chinese:
            guard let fresh = freshText(result) else { return nil }
            return Self.scriptLanguage(fresh.text)
        case .english:
            guard result.isFinal, let confidence = result.confidence,
                  freshText(result) != nil else { return nil }
            if confidence < Self.lowEnglishConfidence { return .chinese }
            if active == nil, confidence >= Self.firstDecisionEnglishConfidence { return .english }
            return nil
        case .unknown:
            return nil
        }
    }

    private mutating func switchTo(_ language: SpokenLanguage) -> [StreamingTranscriptionUpdate] {
        active = language
        pending = nil
        var replayed: [StreamingTranscriptionUpdate] = []
        for final in shadowFinals[language] ?? [] {
            if let update = forward(final, from: language) { replayed.append(update) }
        }
        // The other language's recent finals stay available in case this
        // decision is reversed before they are covered by committed audio.
        shadowFinals[language] = []
        return replayed
    }

    private mutating func remember(_ final: AppleRecognitionResult, from source: SpokenLanguage) {
        var finals = shadowFinals[source, default: []]
        finals.removeAll { $0.endSample <= committedThrough + Self.tolerance }
        finals.append(final)
        shadowFinals[source] = Array(finals.suffix(4))
    }

    private mutating func forward(_ result: AppleRecognitionResult, from language: SpokenLanguage) -> StreamingTranscriptionUpdate? {
        guard let fresh = freshText(result) else { return nil }
        if result.isFinal { committedThrough = max(committedThrough, result.endSample) }
        return StreamingTranscriptionUpdate(
            output: TranscriptionOutput(text: fresh.text, language: language,
                reportedLanguageCode: language.rawValue, words: [],
                averageLogProbability: result.confidence.map { Float(log(max($0, 0.0001))) }),
            startSample: fresh.start,
            endSample: max(fresh.start, result.endSample),
            isFinal: result.isFinal,
            processingLatency: result.processingLatency
        )
    }

    /// The part of a result covering audio after the last committed final.
    private func freshText(_ result: AppleRecognitionResult) -> (text: String, start: Int64)? {
        guard result.endSample > committedThrough + Self.tolerance else { return nil }
        if result.startSample + Self.tolerance >= committedThrough {
            return (result.text, result.startSample)
        }
        guard !result.runs.isEmpty else { return (result.text, committedThrough) }
        let kept = result.runs.filter { ($0.startSample + $0.endSample) / 2 >= committedThrough }
        let text = kept.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TranscriptionTextPolicy.isNonSpeechOnly(text) else { return nil }
        return (text, committedThrough)
    }
}

/// Automatic Chinese/English recognition on Apple's continuous streaming models.
/// Replaces the Whisper snapshot path for the automatic language mode: no
/// fixed utterance cuts, no repeated re-transcription and no audio resubmission.
final class BilingualStreamingTranscriptionService: StreamingTranscriptionProviding, @unchecked Sendable {
    private let english: AppleStreamingTranscriptionService
    private let chinese: AppleStreamingTranscriptionService
    private let lock = NSLock()
    private var running: Task<Void, Never>?

    init(fastResults: Bool = true, boundedFinalization: Bool = true) {
        english = AppleStreamingTranscriptionService(language: .english, fastResults: fastResults)
        chinese = AppleStreamingTranscriptionService(language: .chinese, fastResults: fastResults,
            boundedFinalization: boundedFinalization)
    }

    func prepare() async throws {
        try await english.prepare()
        try await chinese.prepare()
    }

    func updates(
        from audioStream: AsyncStream<CapturedAudioChunk>,
        vocabulary: String
    ) -> AsyncThrowingStream<StreamingTranscriptionUpdate, Error> {
        let english = self.english, chinese = self.chinese
        return AsyncThrowingStream { continuation in
            let (englishAudio, englishInput) = AsyncStream<CapturedAudioChunk>.makeStream()
            let (chineseAudio, chineseInput) = AsyncStream<CapturedAudioChunk>.makeStream()
            let arbiter = LockedArbiter()
            let task = Task {
                let pump = Task {
                    for await chunk in audioStream {
                        englishInput.yield(chunk)
                        chineseInput.yield(chunk)
                    }
                    englishInput.finish()
                    chineseInput.finish()
                }
                let englishResults = english.results(from: englishAudio, vocabulary: vocabulary)
                let chineseResults = chinese.results(from: chineseAudio, vocabulary: vocabulary)
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await result in englishResults {
                                arbiter.accept(result, from: .english) { continuation.yield($0) }
                            }
                        }
                        group.addTask {
                            for try await result in chineseResults {
                                arbiter.accept(result, from: .chinese) { continuation.yield($0) }
                            }
                        }
                        try await group.waitForAll()
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                pump.cancel()
                englishInput.finish()
                chineseInput.finish()
            }
            lock.withLock {
                running?.cancel()
                running = task
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            running?.cancel()
            running = nil
        }
        english.cancel()
        chinese.cancel()
    }
}

/// Serializes both recognizers' results so arbitration and output order agree.
private final class LockedArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var arbiter = BilingualRecognitionArbiter()

    func accept(_ result: AppleRecognitionResult, from language: SpokenLanguage,
                yield: (StreamingTranscriptionUpdate) -> Void) {
        lock.withLock {
            for update in arbiter.accept(result, from: language) { yield(update) }
        }
    }
}
