@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

enum AppleStreamingTranscriptionError: Error, LocalizedError {
    case unavailable
    case unsupportedEnglishLocale
    case assetsUnavailable
    case audioFormatUnavailable
    case audioBufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple on-device speech transcription is unavailable"
        case .unsupportedEnglishLocale:
            return "The installed Apple speech model does not support US English"
        case .assetsUnavailable:
            return "The Apple English speech model could not be installed"
        case .audioFormatUnavailable:
            return "No compatible Apple speech audio format is available"
        case .audioBufferAllocationFailed:
            return "Could not allocate an Apple speech audio buffer"
        }
    }
}

/// Streams the already-normalized 16 kHz mono capture directly into Apple's
/// on-device transcriber. Unlike the Whisper snapshot path, audio already seen
/// by the model is never submitted again.
final class AppleStreamingTranscriptionService: StreamingTranscriptionProviding,
    @unchecked Sendable {
    private static let sampleRate = 16_000.0
    private static let locale = Locale(identifier: "en_US")

    private let lock = NSLock()
    private var runningTask: Task<Void, Never>?

    func prepare() async throws {
        _ = try await Self.makePreparedTranscriber(vocabulary: "")
    }

    func updates(
        from audioStream: AsyncStream<CapturedAudioChunk>,
        vocabulary: String
    ) -> AsyncThrowingStream<StreamingTranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                do {
                    let (transcriber, context) = try await Self.makePreparedTranscriber(
                        vocabulary: vocabulary
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

                    let resultTask = Task {
                        for try await result in transcriber.results {
                            guard !Task.isCancelled else { return }
                            let text = String(result.text.characters)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty,
                                  !TranscriptionTextPolicy.isNonSpeechOnly(text),
                                  !TranscriptionTextPolicy.isDegenerateRepetition(text) else {
                                continue
                            }

                            let start = max(
                                0,
                                Int64((CMTimeGetSeconds(result.range.start)
                                    * Self.sampleRate).rounded())
                            )
                            let end = max(
                                start,
                                Int64((CMTimeGetSeconds(result.range.end)
                                    * Self.sampleRate).rounded())
                            )
                            let audioEnd = CMTimeGetSeconds(result.range.end)
                            let finalizedAt = CMTimeGetSeconds(
                                result.resultsFinalizationTime
                            )
                            continuation.yield(
                                StreamingTranscriptionUpdate(
                                    output: TranscriptionOutput(
                                        text: text,
                                        language: .english,
                                        reportedLanguageCode: "en",
                                        words: []
                                    ),
                                    startSample: start,
                                    endSample: end,
                                    isFinal: result.isFinal,
                                    processingLatency: max(0, finalizedAt - audioEnd)
                                )
                            )
                        }
                    }

                    do {
                        let inputSequence = audioStream.compactMap { chunk in
                            try? Self.makeAnalyzerInput(samples: chunk.samples, format: format)
                        }
                        _ = try await analyzer.analyzeSequence(inputSequence)
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        try await resultTask.value
                        continuation.finish()
                    } catch {
                        resultTask.cancel()
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                self?.clearRunningTask()
            }

            lock.withLock {
                runningTask?.cancel()
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
        }
    }

    private func clearRunningTask() {
        lock.withLock {
            runningTask = nil
        }
    }

    private static func makePreparedTranscriber(
        vocabulary: String
    ) async throws -> (SpeechTranscriber, AnalysisContext) {
        guard SpeechTranscriber.isAvailable else {
            throw AppleStreamingTranscriptionError.unavailable
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: locale
        ) else {
            throw AppleStreamingTranscriptionError.unsupportedEnglishLocale
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let modules: [any SpeechModule] = [transcriber]
        let status = await AssetInventory.status(forModules: modules)
        if status != .installed {
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) else {
                throw AppleStreamingTranscriptionError.assetsUnavailable
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
