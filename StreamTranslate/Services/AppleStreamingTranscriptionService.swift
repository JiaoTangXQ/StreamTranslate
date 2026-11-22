@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

enum AppleStreamingTranscriptionError: Error, LocalizedError {
    case unavailable
    case unsupportedLocale(SpokenLanguage)
    case assetsUnavailable(SpokenLanguage)
    case audioFormatUnavailable
    case audioBufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple on-device speech transcription is unavailable"
        case .unsupportedLocale(let language):
            return "Apple speech does not support \(language.displayName) on this Mac. Select Whisper as a fallback."
        case .assetsUnavailable(let language):
            return "The Apple \(language.displayName) speech model could not be installed. Select Whisper as a fallback."
        case .audioFormatUnavailable:
            return "No compatible Apple speech audio format is available"
        case .audioBufferAllocationFailed:
            return "Could not allocate an Apple speech audio buffer"
        }
    }
}

/// One SpeechTranscriber result with its per-token audio timing. The bilingual
/// recognizer needs token timing to drop audio another recognizer already
/// committed, and confidence to judge which language is being spoken.
struct AppleRecognitionResult: Sendable {
    struct Run: Sendable, Equatable {
        let text: String
        let startSample: Int64
        let endSample: Int64
        let confidence: Double?
    }

    let text: String
    let runs: [Run]
    let startSample: Int64
    let endSample: Int64
    let isFinal: Bool
    let processingLatency: TimeInterval

    /// Character-weighted mean of the token confidences Apple reports. Only
    /// final results carry confidence; volatile results return nil.
    var confidence: Double? {
        var weighted = 0.0, count = 0
        for run in runs {
            guard let confidence = run.confidence else { continue }
            let length = max(1, run.text.trimmingCharacters(in: .whitespaces).count)
            weighted += confidence * Double(length)
            count += length
        }
        return count > 0 ? weighted / Double(count) : nil
    }
}

/// Streams the already-normalized 16 kHz mono capture directly into Apple's
/// on-device transcriber. Unlike the Whisper snapshot path, audio already seen
/// by the model is never submitted again.
final class AppleStreamingTranscriptionService: StreamingTranscriptionProviding,
    @unchecked Sendable {
    private static let sampleRate = 16_000.0
    let language: SpokenLanguage
    let fastResults: Bool
    let boundedFinalization: Bool

    private let lock = NSLock()
    private var runningTask: Task<Void, Never>?
    private var runningTaskID: UUID?

    init(language: SpokenLanguage = .english, fastResults: Bool = true, boundedFinalization: Bool = true) {
        self.language = language
        self.fastResults = fastResults
        self.boundedFinalization = boundedFinalization && language == .chinese
    }

    func prepare() async throws {
        _ = try await Self.makePreparedTranscriber(language: language, vocabulary: "", fastResults: fastResults)
    }

    func updates(
        from audioStream: AsyncStream<CapturedAudioChunk>,
        vocabulary: String
    ) -> AsyncThrowingStream<StreamingTranscriptionUpdate, Error> {
        let language = self.language
        let results = self.results(from: audioStream, vocabulary: vocabulary)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results {
                        continuation.yield(StreamingTranscriptionUpdate(
                            output: TranscriptionOutput(
                                text: result.text,
                                language: language,
                                reportedLanguageCode: language.rawValue,
                                words: []
                            ),
                            startSample: result.startSample,
                            endSample: result.endSample,
                            isFinal: result.isFinal,
                            processingLatency: result.processingLatency
                        ))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// The recognizer core. Results keep token timing and confidence.
    func results(
        from audioStream: AsyncStream<CapturedAudioChunk>,
        vocabulary: String
    ) -> AsyncThrowingStream<AppleRecognitionResult, Error> {
        let language = self.language
        let fastResults = self.fastResults
        let boundedFinalization = self.boundedFinalization
        return AsyncThrowingStream { continuation in
            let taskID = UUID()
            let task = Task { [weak self] in
                do {
                    let (transcriber, context) = try await Self.makePreparedTranscriber(
                        language: language,
                        vocabulary: vocabulary,
                        fastResults: fastResults
                    )
                    let modules: [any SpeechModule] = [transcriber]
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: modules
                    ), format.commonFormat == .pcmFormatInt16,
                       format.channelCount == 1,
                       format.sampleRate == Self.sampleRate else {
                        throw AppleStreamingTranscriptionError.audioFormatUnavailable
                    }

                    let analyzer = SpeechAnalyzer(
                        modules: modules,
                        options: .init(
                            priority: .userInitiated,
                            modelRetention: .whileInUse
                        )
                    )
                    try await analyzer.setContext(context)
                    try await analyzer.prepareToAnalyze(in: format)
                    let finalization = boundedFinalization ? SpeechFinalizationPlanner() : nil

                    let resultTask = Task {
                        do {
                            for try await result in transcriber.results {
                                guard !Task.isCancelled else { return }
                                let text = String(result.text.characters)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty,
                                      !TranscriptionTextPolicy.isNonSpeechOnly(text),
                                      !TranscriptionTextPolicy.isDegenerateRepetition(text) else {
                                    continue
                                }

                                let start = Self.sample(result.range.start)
                                let end = max(start, Self.sample(result.range.end))
                                let audioEnd = CMTimeGetSeconds(result.range.end)
                                finalization?.recognized(through: end, isFinal: result.isFinal, text: text)
                                let finalizedAt = CMTimeGetSeconds(
                                    result.resultsFinalizationTime
                                )
                                var runs: [AppleRecognitionResult.Run] = []
                                // Spaces and punctuation may lack their own time
                                // range; they belong to the token before them.
                                var cursor = start
                                for run in result.text.runs {
                                    let piece = String(result.text[run.range].characters)
                                    guard !piece.isEmpty else { continue }
                                    let range = run.audioTimeRange
                                    let runStart = range.map { Self.sample($0.start) } ?? cursor
                                    let runEnd = max(runStart, range.map { Self.sample($0.end) } ?? cursor)
                                    cursor = runEnd
                                    runs.append(.init(text: piece, startSample: runStart,
                                        endSample: runEnd, confidence: run.transcriptionConfidence))
                                }
                                continuation.yield(AppleRecognitionResult(
                                    text: text,
                                    runs: runs,
                                    startSample: start,
                                    endSample: end,
                                    isFinal: result.isFinal,
                                    processingLatency: max(0, finalizedAt - audioEnd)
                                ))
                            }
                            // A clean EOF can also precede the end of continuous
                            // audio. Let the consumer retire that capture now.
                            continuation.finish()
                        } catch {
                            // Report a failed result stream immediately. Waiting
                            // for the continuous audio input to end hides this
                            // error indefinitely while capture still looks active.
                            continuation.finish(throwing: error)
                            await analyzer.cancelAndFinishNow()
                            throw error
                        }
                    }

                    let finalizationTask = Task {
                        guard let finalization else { return }
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                            guard let boundary = finalization.nextBoundary() else { continue }
                            do {
                                try await analyzer.finalize(through: CMTime(value: boundary, timescale: 16_000))
                            } catch {
                                if !Task.isCancelled { AppLogger.log("Speech bounded finalization: \(error)") }
                                return
                            }
                        }
                    }
                    do {
                        let inputSequence = audioStream.map { chunk in
                            finalization?.observe(chunk.samples)
                            return try Self.makeAnalyzerInput(samples: chunk.samples, format: format)
                        }
                        _ = try await analyzer.analyzeSequence(inputSequence)
                        finalizationTask.cancel()
                        await finalizationTask.value
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        try await resultTask.value
                        continuation.finish()
                    } catch {
                        finalizationTask.cancel()
                        resultTask.cancel()
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                self?.clearRunningTask(id: taskID)
            }

            lock.withLock {
                runningTask?.cancel()
                runningTaskID = taskID
                runningTask = task
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func cancel() {
        lock.withLock {
            runningTask?.cancel()
            runningTask = nil
            runningTaskID = nil
        }
    }

    private func clearRunningTask(id: UUID) {
        lock.withLock {
            guard runningTaskID == id else { return }
            runningTask = nil
            runningTaskID = nil
        }
    }

    private static func sample(_ time: CMTime) -> Int64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return 0 }
        return max(0, Int64((seconds * sampleRate).rounded()))
    }

    private static func makePreparedTranscriber(
        language: SpokenLanguage,
        vocabulary: String,
        fastResults: Bool
    ) async throws -> (SpeechTranscriber, AnalysisContext) {
        guard SpeechTranscriber.isAvailable else {
            throw AppleStreamingTranscriptionError.unavailable
        }
        guard language == .english || language == .chinese,
              let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language == .chinese ? "zh_CN" : "en_US")
        ) else {
            throw AppleStreamingTranscriptionError.unsupportedLocale(language)
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: fastResults ? [.volatileResults, .fastResults] : [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let modules: [any SpeechModule] = [transcriber]
        let status = await AssetInventory.status(forModules: modules)
        if status != .installed {
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) else {
                throw AppleStreamingTranscriptionError.assetsUnavailable(language)
            }
            try await request.downloadAndInstall()
        }
        _ = try await AssetInventory.reserve(locale: supportedLocale)

        let context = AnalysisContext()
        let terms = vocabulary
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !terms.isEmpty {
            context.contextualStrings[.general] = Array(terms.prefix(100))
        }
        return (transcriber, context)
    }

    private static func makeAnalyzerInput(
        samples: [Float],
        format: AVAudioFormat
    ) throws -> AnalyzerInput {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.int16ChannelData?[0] else {
            throw AppleStreamingTranscriptionError.audioBufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            let clamped = min(1, max(-1, samples[index]))
            channel[index] = Int16(clamped * Float(Int16.max))
        }
        return AnalyzerInput(buffer: buffer)
    }
}
