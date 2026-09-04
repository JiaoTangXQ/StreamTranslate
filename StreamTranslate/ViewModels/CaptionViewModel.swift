import Foundation
import SwiftUI

actor SpeechEventQueue {
    private var finals: [SpeechSegment] = []
    private var latestPartial: SpeechSegment?
    private var waiter: CheckedContinuation<SpeechSegmentEvent?, Never>?
    private var isFinished = false

    func submit(_ event: SpeechSegmentEvent) {
        guard !isFinished else { return }

        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
            return
        }

        switch event {
        case .partial(let segment):
            let hasMatchingFinal = finals.contains {
                $0.startSample == segment.startSample
            }
            if !hasMatchingFinal {
                latestPartial = segment
            }
        case .final(let segment):
            if latestPartial?.startSample == segment.startSample {
                latestPartial = nil
            }
            finals.append(segment)
        }
    }

    func next() async -> SpeechSegmentEvent? {
        if !finals.isEmpty {
            return .final(finals.removeFirst())
        }
        if let latestPartial {
            self.latestPartial = nil
            return .partial(latestPartial)
        }
        if isFinished {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func finish() {
        isFinished = true
        if finals.isEmpty, latestPartial == nil, let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}

struct PartialTranslationRequest: Sendable {
    let segment: SpeechSegment
    let output: TranscriptionOutput
    let sourceText: String
    let direction: TranslationDirection
    let generation: Int
}

private struct FinalTranslationRequest: Sendable {
    let entryID: UUID
    let segment: SpeechSegment
    let output: TranscriptionOutput
    let sourceText: String
    let direction: TranslationDirection
    let generation: Int
    let queuedAt: Date
    let logger: MeetingSessionLogger?
}

actor PartialTranslationQueue {
    private var latest: PartialTranslationRequest?
    private var waiter: CheckedContinuation<PartialTranslationRequest?, Never>?
    private var discardedSegmentStarts: Set<Int64> = []
    private var isFinished = false

    func submit(_ request: PartialTranslationRequest) {
        guard !isFinished,
              !discardedSegmentStarts.contains(request.segment.startSample) else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: request)
        } else {
            latest = request
        }
    }

    func next() async -> PartialTranslationRequest? {
        if let latest {
            self.latest = nil
            return latest
        }
        if isFinished {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    /// Apple Speech can emit several growing subword hypotheses in one
    /// callback burst. After a short debounce, consume the newest request so
    /// only the most useful prefix reaches TranslationSession.
    func coalesced(with request: PartialTranslationRequest) -> PartialTranslationRequest? {
        guard !discardedSegmentStarts.contains(request.segment.startSample) else {
            return nil
        }
        guard let latest else { return request }
        self.latest = nil
        return latest
    }

    func discard(segmentStartingAt startSample: Int64) {
        discardedSegmentStarts.insert(startSample)
        if latest?.segment.startSample == startSample {
            latest = nil
        }
    }

    func finish() {
        isFinished = true
        latest = nil
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}

struct CaptionContentRevision: Equatable {
    let historyCount: Int
    let streamingSegmentStartSample: Int64?
}

private actor TranslationGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
@Observable
final class CaptionViewModel {
    var isRecording = false
    var isStartingCapture = false
    var isLoading = false
    var isModelReady = false
    var isPreparingTranslation = false
    var isTranslationReady = false
    var statusMessage = ""
    var downloadProgress: Double?
    var downloadError: String?

    var streamingEnglish = ""
    var streamingChinese = ""
    var streamingSourceLanguage: SpokenLanguage = .english
    var streamingWords: [WordTimestamp] = []
    var streamingStableOriginal = ""
    var streamingDraftOriginal = ""

    var captionHistory: [CaptionEntry] = []
    var recentCaptions: [CaptionEntry] = []

    let translationService = TranslationService()

    var hasStreamingText: Bool {
        !streamingEnglish.isEmpty || !streamingChinese.isEmpty
    }

    var streamingOriginalText: String {
        streamingSourceLanguage == .english ? streamingEnglish : streamingChinese
    }

    var streamingTranslatedText: String {
        streamingSourceLanguage == .english ? streamingChinese : streamingEnglish
    }

    var captionContentRevision: CaptionContentRevision {
        CaptionContentRevision(
            historyCount: captionHistory.count,
            streamingSegmentStartSample: streamingSegmentStartSample
        )
    }

    private let maxRecentCaptions = 2
    private var audioCaptureService: AudioCaptureService?
    private var sessionLogger: MeetingSessionLogger?
    private var transcriptionService: WhisperTranscriptionService?
    private var appleTranscriptionService: AppleStreamingTranscriptionService?
    private var segmentationTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var partialTranslationTask: Task<Void, Never>?
    private var activePartialTranslationOperation: Task<Void, Never>?
    private var partialTranslationQueue: PartialTranslationQueue?
    private var pendingFinalTranslations: [FinalTranslationRequest] = []
    private var finalTranslationWorker: Task<Void, Never>?
    private var finalTranslationWorkerID: UUID?
    private var cleanupTask: Task<Void, Never>?
    private var readyTranslationDirections: Set<TranslationDirection> = []
    private var transcriptionContext = TranscriptionContext()
    private var captionTextStabilizer = CaptionTextStabilizer()
    private let translationGate = TranslationGate()
    private var captionGeneration = 0
    private var streamingSegmentStartSample: Int64?
    private var lastPartialTranslationRequestText = ""
    private var activeRecognitionVocabulary = ""
    private var activeModel = ASRModel.defaultModel

    // MARK: - Lifecycle

    func preloadModel(modelId: String = ASRModel.defaultModel.id) {
        guard !isModelReady, !isLoading else { return }
        loadModel(modelId: modelId, switching: false)
    }

    func switchModel(to modelId: String) {
        guard !isLoading else { return }
        if isRecording {
            stopCapture()
        }
        transcriptionService = nil
        appleTranscriptionService?.cancel()
        appleTranscriptionService = nil
        isModelReady = false
        loadModel(modelId: modelId, switching: true)
    }

    private func loadModel(modelId: String, switching: Bool) {
        let model = ASRModel.available.first { $0.id == modelId }
            ?? ASRModel.defaultModel
        let modelName = model.name
        isLoading = true
        statusMessage = switching ? "Switching to \(modelName)..." : "Loading \(modelName)..."
        downloadProgress = 0
        downloadError = nil

        Task {
            do {
                switch model.backend {
                case .appleSpeech:
                    AppLogger.log("Preparing Apple streaming English model")
                    let service = AppleStreamingTranscriptionService()
                    try await service.prepare()
                    appleTranscriptionService = service
                    transcriptionService = nil
                case .whisperKit:
                    AppLogger.log("Loading multilingual Whisper model: \(modelId)")
                    let service = try await WhisperTranscriptionService.load(
                        modelId: modelId,
                        onDownloadProgress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                self?.downloadProgress = progress
                                self?.statusMessage = "Downloading \(modelName)..."
                            }
                        }
                    )
                    transcriptionService = service
                    appleTranscriptionService = nil
                }
                activeModel = model
                isModelReady = true
                statusMessage = ""
                downloadProgress = nil
                downloadError = nil
                AppLogger.log("Speech model ready: \(modelId)")
            } catch {
                let details = Self.describe(error)
                AppLogger.log("Whisper model load failed: \(details)")
                let message = "Model load failed: \(error.localizedDescription)"
                statusMessage = message
                downloadError = message
                downloadProgress = nil
            }
            isLoading = false
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let error = current, depth < 4 {
            parts.append("\(error.domain) code=\(error.code) \"\(error.localizedDescription)\"")
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " → ")
    }

    func clearDownloadError() {
        downloadError = nil
    }

    // MARK: - Translation readiness

    func translationPreparationStarted(_ direction: TranslationDirection) {
        readyTranslationDirections.remove(direction)
        isPreparingTranslation = true
        isTranslationReady = false
        AppLogger.log("Preparing translation: \(direction)")
    }

    func translationPreparationSucceeded(_ direction: TranslationDirection) {
        readyTranslationDirections.insert(direction)
        isTranslationReady = readyTranslationDirections.count == TranslationDirection.allCases.count
        isPreparingTranslation = !isTranslationReady
        if isTranslationReady, statusMessage.hasPrefix("Translation") {
            statusMessage = ""
        }
        AppLogger.log("Translation session ready: \(direction)")
    }

    func translationPreparationFailed(
        _ direction: TranslationDirection,
        message: String,
        details: String
    ) {
        readyTranslationDirections.remove(direction)
        isPreparingTranslation = false
        isTranslationReady = false
        statusMessage = "Translation unavailable: \(message)"
        AppLogger.log("Translation preparation failed [\(direction)]: \(details)")
    }

    // MARK: - Caption state

    func addCaption(
        english: String,
        chinese: String,
        sourceLanguage: SpokenLanguage = .english
    ) {
        let entry = CaptionEntry(
            timestamp: .now,
            englishText: english,
            chineseText: chinese,
            sourceLanguage: sourceLanguage
        )
        appendCaption(entry)
    }

    func clearHistory() {
        captionGeneration += 1
        activePartialTranslationOperation?.cancel()
        activePartialTranslationOperation = nil
        finalTranslationWorker?.cancel()
        finalTranslationWorker = nil
        finalTranslationWorkerID = nil
        pendingFinalTranslations = []
        captionHistory = []
        recentCaptions = []
        clearStreamingState()
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    // MARK: - Capture control

    func toggleCapture(
        source: AudioInputSource = .microphone,
        sensitivity: SpeechDetectionSensitivity = .automatic,
        recognitionMode: RecognitionLanguageMode = .automatic,
        recognitionVocabulary: String = "",
        captureDiagnosticsEnabled: Bool = false
    ) {
        AppLogger.log("toggleCapture called, isRecording=\(isRecording), isModelReady=\(isModelReady)")
        if isRecording {
            stopCapture()
        } else if !isStartingCapture {
            Task {
                await startCapture(
                    source: source,
                    sensitivity: sensitivity,
                    recognitionMode: recognitionMode,
                    recognitionVocabulary: recognitionVocabulary,
                    captureDiagnosticsEnabled: captureDiagnosticsEnabled
                )
            }
        }
    }

    func startCapture(
        source: AudioInputSource = .microphone,
        sensitivity: SpeechDetectionSensitivity = .automatic,
        recognitionMode: RecognitionLanguageMode = .automatic,
        recognitionVocabulary: String = "",
        captureDiagnosticsEnabled: Bool = false
    ) async {
        guard !isRecording, !isStartingCapture else { return }
        isStartingCapture = true
        defer { isStartingCapture = false }

        if !isModelReady {
            preloadModel()
            while isLoading {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard isModelReady else { return }
        }

        guard (activeModel.backend == .appleSpeech
                && appleTranscriptionService != nil)
                || (activeModel.backend == .whisperKit
                    && transcriptionService != nil) else {
            statusMessage = "Model not available"
            return
        }
        guard isTranslationReady else {
            statusMessage = isPreparingTranslation
                ? "Translation is still preparing"
                : "Translation is not available"
            return
        }

        do {
            var logger: MeetingSessionLogger?
            if captureDiagnosticsEnabled {
                do {
                    logger = try MeetingSessionLogger(source: source)
                    AppLogger.log(
                        "Session evidence: \(logger?.directoryURL.path ?? "unavailable")"
                    )
                } catch {
                    AppLogger.log(
                        "Session evidence unavailable: \(Self.describe(error))"
                    )
                }
            }

            let audioService = AudioCaptureService(
                source: source,
                sessionLogger: logger
            )
            let audioStream = audioService.makeAudioStream()
            audioCaptureService = audioService
            sessionLogger = logger
            statusMessage = ""

            try await audioService.start()
            isRecording = true
            transcriptionContext.reset()
            activeRecognitionVocabulary = recognitionVocabulary
            let effectiveSensitivity: SpeechDetectionSensitivity = source == .microphone
                ? sensitivity
                : .automatic
            AppLogger.log(
                "Audio capture started: \(source.rawValue), "
                    + "speech detection=\(effectiveSensitivity.rawValue), "
                    + "recognition language=\(recognitionMode.rawValue)"
            )
            runPipeline(
                audioStream: audioStream,
                sensitivity: effectiveSensitivity,
                recognitionMode: recognitionMode
            )
        } catch {
            AppLogger.log("Failed to start capture: \(error.localizedDescription)")
            await audioCaptureService?.stop()
            sessionLogger?.finish()
            sessionLogger = nil
            audioCaptureService = nil
            statusMessage = "Error: \(error.localizedDescription)"
            isRecording = false
        }
    }

    func stopCapture() {
        isRecording = false
        segmentationTask?.cancel()
        segmentationTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        appleTranscriptionService?.cancel()
        partialTranslationTask?.cancel()
        partialTranslationTask = nil
        activePartialTranslationOperation?.cancel()
        activePartialTranslationOperation = nil
        let translationQueue = partialTranslationQueue
        partialTranslationQueue = nil

        let service = audioCaptureService
        let logger = sessionLogger
        Task {
            await translationQueue?.finish()
            await service?.stop()
            logger?.finish()
        }
        audioCaptureService = nil
        sessionLogger = nil
        transcriptionContext.reset()

        if hasStreamingText {
            addCaption(
                english: streamingEnglish,
                chinese: streamingChinese,
                sourceLanguage: streamingSourceLanguage
            )
        }
        clearStreamingState()
        AppLogger.log("Audio capture stopped")
    }

    // MARK: - Multilingual transcription pipeline

    private func runPipeline(
        audioStream: AsyncStream<CapturedAudioChunk>,
        sensitivity: SpeechDetectionSensitivity,
        recognitionMode: RecognitionLanguageMode
    ) {
        if activeModel.backend == .appleSpeech {
            runApplePipeline(audioStream: audioStream)
            return
        }
        runWhisperPipeline(
            audioStream: audioStream,
            sensitivity: sensitivity,
            recognitionMode: recognitionMode
        )
    }

    private func runApplePipeline(
        audioStream: AsyncStream<CapturedAudioChunk>
    ) {
        guard let transcription = appleTranscriptionService else { return }
        let logger = sessionLogger
        let translationQueue = PartialTranslationQueue()
        partialTranslationQueue = translationQueue

        AppLogger.log("Recognition profile: Apple Speech continuous en_US")
        logger?.recordPipelineStatus(
            "recognition_backend",
            detail: "apple-speech-transcriber-en"
        )
        partialTranslationTask = Task { [weak self] in
            while !Task.isCancelled,
                  let initialRequest = await translationQueue.next(),
                  let self {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled,
                      let request = await translationQueue.coalesced(
                        with: initialRequest
                      ) else { continue }
                let operation = Task { [weak self] in
                    guard let self else { return }
                    await self.processPartialTranslation(request, logger: logger)
                }
                self.activePartialTranslationOperation = operation
                await operation.value
                self.activePartialTranslationOperation = nil
            }
        }

        pipelineTask = Task { [weak self] in
            do {
                let updates = transcription.updates(
                    from: audioStream,
                    vocabulary: self?.activeRecognitionVocabulary ?? ""
                )
                for try await update in updates {
                    guard !Task.isCancelled, let self else { break }
                    await self.processStreamingUpdate(
                        update,
                        logger: logger,
                        partialTranslations: translationQueue
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                let details = Self.describe(error)
                self.statusMessage = "Transcription error: \(error.localizedDescription)"
                AppLogger.log("Apple streaming transcription failed: \(details)")
            }
        }
    }

    private func runWhisperPipeline(
        audioStream: AsyncStream<CapturedAudioChunk>,
        sensitivity: SpeechDetectionSensitivity,
        recognitionMode: RecognitionLanguageMode
    ) {
        guard let transcription = transcriptionService else { return }
        let logger = sessionLogger
        let eventQueue = SpeechEventQueue()
        let translationQueue = PartialTranslationQueue()
        let modelProfile = activeModel
        partialTranslationQueue = translationQueue

        AppLogger.log(
            "Recognition profile: \(modelProfile.priorityName), "
                + "maximum utterance=\(modelProfile.maximumUtteranceDuration)s, "
                + "source preview=\(modelProfile.firstPreviewInterval)s/"
                + "\(modelProfile.subsequentPreviewInterval)s, "
                + "rolling audio context=\(modelProfile.usesRollingAudioContext)"
        )
        logger?.recordPipelineStatus(
            "recognition_backend",
            detail: modelProfile.id
        )

        partialTranslationTask = Task { [weak self] in
            while !Task.isCancelled,
                  let initialRequest = await translationQueue.next(),
                  let self {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled,
                      let request = await translationQueue.coalesced(
                        with: initialRequest
                      ) else { continue }
                let operation = Task { [weak self] in
                    guard let self else { return }
                    await self.processPartialTranslation(request, logger: logger)
                }
                self.activePartialTranslationOperation = operation
                await operation.value
                self.activePartialTranslationOperation = nil
            }
        }

        segmentationTask = Task {
            var segmenter = SpeechSegmenter(
                sensitivity: sensitivity,
                previewInterval: modelProfile.firstPreviewInterval,
                subsequentPreviewInterval: modelProfile.subsequentPreviewInterval,
                maximumUtteranceDuration: modelProfile.maximumUtteranceDuration
            )
            for await chunk in audioStream {
                guard !Task.isCancelled else { break }
                let events = segmenter.append(chunk.samples)
                for event in events {
                    guard !Task.isCancelled else { break }
                    await eventQueue.submit(event)
                }
            }
            if !Task.isCancelled, let final = segmenter.finish() {
                await eventQueue.submit(final)
            }
            await eventQueue.finish()
        }

        pipelineTask = Task { [weak self] in
            while !Task.isCancelled,
                  let event = await eventQueue.next(),
                  let self {
                switch event {
                case .partial(let segment):
                    await self.processPartial(
                        segment,
                        using: transcription,
                        recognitionMode: recognitionMode,
                        logger: logger,
                        partialTranslations: translationQueue
                    )
                case .final(let segment):
                    await self.processFinal(
                        segment,
                        using: transcription,
                        recognitionMode: recognitionMode,
                        logger: logger,
                        partialTranslations: translationQueue,
                        usesRollingAudioContext: modelProfile.usesRollingAudioContext
                    )
                }
            }
        }
    }

    private func processPartial(
        _ segment: SpeechSegment,
        using transcription: WhisperTranscriptionService,
        recognitionMode: RecognitionLanguageMode,
        logger: MeetingSessionLogger?,
        partialTranslations: PartialTranslationQueue
    ) async {
        logger?.recordSegment("partial_segment", segment: segment)
        let recognitionStarted = Date()
        do {
            guard let output = try await recognizePartial(
                segment,
                using: transcription,
                recognitionMode: recognitionMode
            ) else {
                logger?.recordRecognition(
                    "partial_recognized",
                    segment: segment,
                    output: nil,
                    duration: Date().timeIntervalSince(recognitionStarted)
                )
                return
            }
            transcriptionContext.recordPartial(segment: segment, output: output)
            logger?.recordRecognition(
                "partial_recognized",
                segment: segment,
                output: output,
                duration: Date().timeIntervalSince(recognitionStarted)
            )
            guard let direction = TranslationDirection.forSource(output.language) else {
                return
            }
            await acceptRecognizedPartial(
                output,
                segment: segment,
                direction: direction,
                partialTranslations: partialTranslations
            )
            AppLogger.log(
                "Partial \(output.language.rawValue) (reported \(output.reportedLanguageCode)): \(output.text)"
            )
        } catch is CancellationError {
            return
        } catch {
            logger?.recordPipelineError(
                "partial_recognition_failed",
                segment: segment,
                error: Self.describe(error)
            )
            statusMessage = "Transcription error: \(error.localizedDescription)"
            AppLogger.log("Partial transcription failed: \(Self.describe(error))")
        }
    }

    private func processStreamingUpdate(
        _ update: StreamingTranscriptionUpdate,
        logger: MeetingSessionLogger?,
        partialTranslations: PartialTranslationQueue
    ) async {
        let segment = SpeechSegment(
            samples: [],
            startSample: update.startSample,
            endSample: update.endSample
        )
        let stage = update.isFinal ? "final_recognized" : "partial_recognized"
        logger?.recordRecognition(
            stage,
            segment: segment,
            output: update.output,
            duration: update.processingLatency
        )
        guard let direction = TranslationDirection.forSource(
            update.output.language
        ) else { return }

        if update.isFinal {
            await acceptRecognizedFinal(
                update.output,
                segment: segment,
                direction: direction,
                logger: logger,
                partialTranslations: partialTranslations
            )
        } else {
            await acceptRecognizedPartial(
                update.output,
                segment: segment,
                direction: direction,
                partialTranslations: partialTranslations
            )
        }
    }

    private func acceptRecognizedPartial(
        _ output: TranscriptionOutput,
        segment: SpeechSegment,
        direction: TranslationDirection,
        partialTranslations: PartialTranslationQueue
    ) async {
        let presentation = showStreamingPartial(output, segment: segment)
        let conservativePrefix = captionTextStabilizer.conservativeTranslationPrefix(
            in: output.text,
            language: output.language
        )
        let sourceText = CaptionTextStabilizer.semanticUnitCount(
            in: conservativePrefix
        ) > CaptionTextStabilizer.semanticUnitCount(in: presentation.stable)
            ? conservativePrefix
            : presentation.stable
        if PartialTranslationPolicy.shouldRequest(
            previousText: lastPartialTranslationRequestText,
            stableText: sourceText,
            language: output.language
        ) {
            lastPartialTranslationRequestText = sourceText
            await partialTranslations.submit(
                PartialTranslationRequest(
                    segment: segment,
                    output: output,
                    sourceText: sourceText,
                    direction: direction,
                    generation: captionGeneration
                )
            )
        }
        AppLogger.log(
            "Partial \(output.language.rawValue) (reported \(output.reportedLanguageCode)): \(output.text)"
        )
    }

    private func processPartialTranslation(
        _ request: PartialTranslationRequest,
        logger: MeetingSessionLogger?
    ) async {
        guard request.generation == captionGeneration else { return }
        let translationStarted = Date()
        let translation = await translate(
            request.sourceText,
            direction: request.direction
        )
        guard !Task.isCancelled else { return }
        if let error = translation.error {
            logger?.recordPipelineError(
                "partial_translation_failed",
                segment: request.segment,
                error: error
            )
        }
        logger?.recordTranslation(
            "partial_translated",
            segment: request.segment,
            sourceText: request.sourceText,
            translatedText: translation.text,
            direction: request.direction,
            duration: Date().timeIntervalSince(translationStarted)
        )
        guard request.generation == captionGeneration,
              streamingSegmentStartSample == request.segment.startSample,
              lastPartialTranslationRequestText == request.sourceText,
              (streamingStableOriginal + streamingDraftOriginal)
                .hasPrefix(request.sourceText) else { return }
        showStreamingTranslation(
            translation.text,
            sourceLanguage: request.output.language
        )
    }

    private func processFinal(
        _ segment: SpeechSegment,
        using transcription: WhisperTranscriptionService,
        recognitionMode: RecognitionLanguageMode,
        logger: MeetingSessionLogger?,
        partialTranslations: PartialTranslationQueue,
        usesRollingAudioContext: Bool
    ) async {
        logger?.recordSegment("final_segment", segment: segment)
        let recognitionStarted = Date()
        do {
            guard let output = try await recognizeFinal(
                segment,
                using: transcription,
                recognitionMode: recognitionMode,
                logger: logger,
                usesRollingAudioContext: usesRollingAudioContext
            ) else {
                logger?.recordRecognition(
                    "final_recognized",
                    segment: segment,
                    output: nil,
                    duration: Date().timeIntervalSince(recognitionStarted)
                )
                clearStreamingState()
                return
            }
            transcriptionContext.recordFinal(segment: segment, output: output)
            logger?.recordRecognition(
                "final_recognized",
                segment: segment,
                output: output,
                duration: Date().timeIntervalSince(recognitionStarted)
            )
            guard let direction = TranslationDirection.forSource(output.language) else {
                clearStreamingState()
                return
            }
            await acceptRecognizedFinal(
                output,
                segment: segment,
                direction: direction,
                logger: logger,
                partialTranslations: partialTranslations
            )
        } catch is CancellationError {
            return
        } catch {
            logger?.recordPipelineError(
                "final_recognition_failed",
                segment: segment,
                error: Self.describe(error)
            )
            statusMessage = "Transcription error: \(error.localizedDescription)"
            AppLogger.log("Final transcription failed: \(Self.describe(error))")
        }
    }

    private func acceptRecognizedFinal(
        _ output: TranscriptionOutput,
        segment: SpeechSegment,
        direction: TranslationDirection,
        logger: MeetingSessionLogger?,
        partialTranslations: PartialTranslationQueue
    ) async {
        activePartialTranslationOperation?.cancel()
        await partialTranslations.discard(segmentStartingAt: segment.startSample)
        let finalPresentation = captionTextStabilizer.finalize(
            text: output.text,
            segmentStartSample: segment.startSample
        )
        let finalText = finalPresentation.fullText
        let draftTranslation: String
        if streamingSegmentStartSample == segment.startSample,
           streamingSourceLanguage == output.language {
            draftTranslation = streamingTranslatedText
        } else {
            draftTranslation = ""
        }
        AppLogger.log(
            "Completed \(output.language.rawValue) (reported \(output.reportedLanguageCode)): \(finalText)"
        )

        let entry = CaptionEntry(
            timestamp: .now,
            englishText: output.language == .english ? finalText : draftTranslation,
            chineseText: output.language == .chinese ? finalText : draftTranslation,
            sourceLanguage: output.language
        )
        appendCaption(entry)
        if streamingSegmentStartSample == segment.startSample {
            clearStreamingState()
        }
        logger?.recordTranslation(
            "caption_source_committed",
            segment: segment,
            sourceText: finalText,
            translatedText: draftTranslation,
            direction: direction,
            duration: 0
        )

        enqueueFinalTranslation(
            FinalTranslationRequest(
                entryID: entry.id,
                segment: segment,
                output: output,
                sourceText: finalText,
                direction: direction,
                generation: captionGeneration,
                queuedAt: .now,
                logger: logger
            )
        )
    }

    private func enqueueFinalTranslation(_ request: FinalTranslationRequest) {
        pendingFinalTranslations.append(request)
        guard finalTranslationWorker == nil else { return }
        let workerID = UUID()
        finalTranslationWorkerID = workerID
        finalTranslationWorker = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            while !Task.isCancelled, let self {
                await self.translationGate.acquire()
                if Task.isCancelled {
                    await self.translationGate.release()
                    break
                }
                guard let batch = self.takeNextFinalTranslationBatch() else {
                    await self.translationGate.release()
                    break
                }
                await self.processFinalTranslationBatch(batch)
                await self.translationGate.release()
            }
            guard self?.finalTranslationWorkerID == workerID else { return }
            self?.finalTranslationWorker = nil
            self?.finalTranslationWorkerID = nil
        }
    }

    private func takeNextFinalTranslationBatch() -> [FinalTranslationRequest]? {
        pendingFinalTranslations.removeAll {
            $0.generation != captionGeneration
        }
        guard let direction = pendingFinalTranslations.first?.direction else {
            return nil
        }
        let batch = pendingFinalTranslations.filter { $0.direction == direction }
        pendingFinalTranslations.removeAll { $0.direction == direction }
        return batch
    }

    private func processFinalTranslationBatch(
        _ batch: [FinalTranslationRequest]
    ) async {
        guard let direction = batch.first?.direction else { return }
        let byID = Dictionary(uniqueKeysWithValues: batch.map { ($0.entryID, $0) })
        do {
            try await translationService.translateBatch(
                batch.map {
                    IdentifiedTranslationRequest(id: $0.entryID, text: $0.sourceText)
                },
                direction: direction,
                onResponse: { [weak self] response in
                    await MainActor.run {
                        guard let self,
                              let request = byID[response.id],
                              request.generation == self.captionGeneration else { return }
                        self.applyFinalTranslation(
                            response.translatedText,
                            to: request,
                            duration: Date().timeIntervalSince(request.queuedAt)
                        )
                    }
                }
            )
        } catch is CancellationError {
            return
        } catch {
            let details = Self.describe(error)
            statusMessage = "Translation error: \(error.localizedDescription)"
            AppLogger.log("Final translation batch failed: \(details)")
            for request in batch where request.generation == captionGeneration {
                request.logger?.recordPipelineError(
                    "final_translation_failed",
                    segment: request.segment,
                    error: details
                )
            }
        }
    }

    private func applyFinalTranslation(
        _ translatedText: String,
        to request: FinalTranslationRequest,
        duration: TimeInterval
    ) {
        request.logger?.recordTranslation(
            "final_translated",
            segment: request.segment,
            sourceText: request.sourceText,
            translatedText: translatedText,
            direction: request.direction,
            duration: duration
        )
        let english = request.output.language == .english
            ? request.sourceText
            : translatedText
        let chinese = request.output.language == .chinese
            ? request.sourceText
            : translatedText
        updateCaption(
            id: request.entryID,
            english: english,
            chinese: chinese,
            sourceLanguage: request.output.language
        )
        request.logger?.recordTranslation(
            "caption_committed",
            segment: request.segment,
            sourceText: request.sourceText,
            translatedText: translatedText,
            direction: request.direction,
            duration: 0
        )
        AppLogger.log("Translated \(request.direction): \(translatedText)")
    }

    private func recognizePartial(
        _ segment: SpeechSegment,
        using transcription: WhisperTranscriptionService,
        recognitionMode: RecognitionLanguageMode
    ) async throws -> TranscriptionOutput? {
        if let languageHint = recognitionMode.languageHint {
            let prompt = transcriptionContext.prompt(
                for: segment,
                language: languageHint,
                vocabulary: activeRecognitionVocabulary
            )
            return try await transcription.transcribe(
                segment.samples,
                languageHint: languageHint,
                prompt: prompt,
                pass: .preview
            )
        }
        if let lockedLanguage = transcriptionContext.lockedLanguage(for: segment) {
            return try await transcription.transcribe(
                segment.samples,
                languageHint: lockedLanguage,
                prompt: transcriptionContext.prompt(
                    for: segment,
                    language: lockedLanguage,
                    vocabulary: activeRecognitionVocabulary
                ),
                pass: .preview
            )
        }
        return try await recognizeNewSegment(
            segment,
            using: transcription,
            allowsRecoveryRetries: false,
            pass: .preview
        )
    }

    private func recognizeFinal(
        _ segment: SpeechSegment,
        using transcription: WhisperTranscriptionService,
        recognitionMode: RecognitionLanguageMode,
        logger: MeetingSessionLogger?,
        usesRollingAudioContext: Bool
    ) async throws -> TranscriptionOutput? {
        let partial = transcriptionContext.partial(for: segment)
        let candidate: TranscriptionOutput?
        if let languageHint = recognitionMode.languageHint {
            let prompt = transcriptionContext.prompt(
                for: segment,
                language: languageHint,
                vocabulary: activeRecognitionVocabulary
            )
            candidate = try await transcription.transcribe(
                segment.samples,
                languageHint: languageHint,
                prompt: prompt
            )
        } else if let lockedLanguage = transcriptionContext.lockedLanguage(for: segment) {
            candidate = try await transcription.transcribe(
                segment.samples,
                languageHint: lockedLanguage,
                prompt: transcriptionContext.prompt(
                    for: segment,
                    language: lockedLanguage,
                    vocabulary: activeRecognitionVocabulary
                )
            )
        } else {
            candidate = try await recognizeNewSegment(
                segment,
                using: transcription,
                allowsRecoveryRetries: true,
                pass: .final
            )
        }
        let currentOnly = TranscriptionSelectionPolicy.chooseFinalResult(
            candidate: candidate,
            previousPartial: partial,
            finalSegment: segment
        )
        guard usesRollingAudioContext,
              let currentOnly,
              currentOnly.language != .unknown,
              let contextualAudio = transcriptionContext.contextualAudio(
                  for: segment,
                  language: currentOnly.language
              ) else {
            return currentOnly
        }

        let contextualStarted = Date()
        let contextual = try await transcription.transcribe(
            contextualAudio.samples,
            languageHint: currentOnly.language,
            prompt: transcriptionContext.prompt(
                for: segment,
                language: currentOnly.language,
                vocabulary: activeRecognitionVocabulary
            ),
            currentAudioOffset: contextualAudio.currentAudioOffset
        )
        logger?.recordRecognition(
            "final_context_recognized",
            segment: segment,
            output: contextual,
            duration: Date().timeIntervalSince(contextualStarted)
        )
        return TranscriptionSelectionPolicy.chooseAudioContextResult(
            currentOnly: currentOnly,
            contextual: contextual
        )
    }

    private func recognizeNewSegment(
        _ segment: SpeechSegment,
        using transcription: WhisperTranscriptionService,
        allowsRecoveryRetries: Bool,
        pass: TranscriptionPass
    ) async throws -> TranscriptionOutput? {
        let context = transcriptionContext.recentFinal(for: segment)
        let automatic = try await transcription.transcribe(
            segment.samples,
            prompt: activeRecognitionVocabulary.nilIfBlank,
            pass: pass
        )
        if allowsRecoveryRetries,
           automatic == nil
            || TranscriptionSelectionPolicy.shouldRetryUnsupportedLanguage(automatic) {
            let english = try await transcription.transcribe(
                segment.samples,
                languageHint: .english
            )
            let chinese = try await transcription.transcribe(
                segment.samples,
                languageHint: .chinese
            )
            return TranscriptionSelectionPolicy.chooseBestScoredResult([
                automatic,
                english,
                chinese
            ])
        }
        let acceptedAutomatic = TranscriptionSelectionPolicy.chooseBestScoredResult([
            automatic
        ])
        guard allowsRecoveryRetries,
              let context,
              TranscriptionSelectionPolicy.shouldRetryWithContextLanguage(
                  automatic: acceptedAutomatic,
                  context: context,
                  sampleCount: segment.samples.count
              ) else {
            return acceptedAutomatic
        }

        let contextual = try await transcription.transcribe(
            segment.samples,
            languageHint: context.output.language,
            prompt: transcriptionContext.prompt(
                for: segment,
                language: context.output.language,
                vocabulary: activeRecognitionVocabulary
            )
        )
        return TranscriptionSelectionPolicy.chooseLanguageResult(
            automatic: acceptedAutomatic,
            contextual: contextual
        )
    }

    @discardableResult
    private func showStreamingPartial(
        _ output: TranscriptionOutput,
        segment: SpeechSegment
    ) -> StabilizedCaptionText {
        let isNewSegment = streamingSegmentStartSample != segment.startSample
        let sourceLanguageChanged = streamingSourceLanguage != output.language
        if isNewSegment || sourceLanguageChanged {
            captionTextStabilizer.reset()
            streamingStableOriginal = ""
            streamingDraftOriginal = ""
            lastPartialTranslationRequestText = ""
            streamingEnglish = ""
            streamingChinese = ""
        }

        let presentation = captionTextStabilizer.update(
            text: output.text,
            segmentStartSample: segment.startSample,
            language: output.language,
            evidenceEndSample: segment.endSample
        )
        streamingSegmentStartSample = segment.startSample
        streamingSourceLanguage = output.language
        streamingWords = output.words
        streamingStableOriginal = presentation.stable
        streamingDraftOriginal = presentation.draft
        switch output.language {
        case .english:
            streamingEnglish = presentation.fullText
        case .chinese:
            streamingChinese = presentation.fullText
        case .unknown:
            clearStreamingState()
        }
        return presentation
    }

    private func showStreamingFinal(
        text: String,
        sourceLanguage: SpokenLanguage,
        segment: SpeechSegment
    ) {
        if streamingSourceLanguage != sourceLanguage {
            streamingEnglish = ""
            streamingChinese = ""
        }
        streamingSegmentStartSample = segment.startSample
        streamingSourceLanguage = sourceLanguage
        streamingStableOriginal = text
        streamingDraftOriginal = ""
        streamingWords = []
        switch sourceLanguage {
        case .english:
            streamingEnglish = text
        case .chinese:
            streamingChinese = text
        case .unknown:
            clearStreamingState()
        }
    }

    private func showStreamingTranslation(
        _ translated: String,
        sourceLanguage: SpokenLanguage
    ) {
        switch sourceLanguage {
        case .english:
            streamingChinese = translated
        case .chinese:
            streamingEnglish = translated
        case .unknown:
            break
        }
    }

    func showCompleted(
        english: String,
        chinese: String,
        sourceLanguage: SpokenLanguage
    ) {
        clearStreamingState()
        addCaption(
            english: english,
            chinese: chinese,
            sourceLanguage: sourceLanguage
        )
    }

    private func appendCaption(_ entry: CaptionEntry) {
        captionHistory.append(entry)
        recentCaptions.append(entry)
        while recentCaptions.count > maxRecentCaptions {
            recentCaptions.removeFirst()
        }
        scheduleCleanup()
    }

    private func updateCaption(
        id: UUID,
        english: String,
        chinese: String,
        sourceLanguage: SpokenLanguage
    ) {
        guard let historyIndex = captionHistory.firstIndex(where: { $0.id == id }) else {
            return
        }
        let previous = captionHistory[historyIndex]
        let updated = CaptionEntry(
            id: id,
            timestamp: previous.timestamp,
            englishText: english,
            chineseText: chinese,
            sourceLanguage: sourceLanguage
        )
        captionHistory[historyIndex] = updated
        if let recentIndex = recentCaptions.firstIndex(where: { $0.id == id }) {
            recentCaptions[recentIndex] = updated
        }
    }

    private func clearStreamingState() {
        streamingEnglish = ""
        streamingChinese = ""
        streamingWords = []
        streamingStableOriginal = ""
        streamingDraftOriginal = ""
        streamingSegmentStartSample = nil
        lastPartialTranslationRequestText = ""
        captionTextStabilizer.reset()
    }

    private func translate(
        _ text: String,
        direction: TranslationDirection
    ) async -> TranslationAttempt {
        await translationGate.acquire()
        if Task.isCancelled {
            await translationGate.release()
            return TranslationAttempt(text: "", error: nil)
        }
        do {
            let attempt = TranslationAttempt(
                text: try await translationService.translate(text, direction: direction),
                error: nil
            )
            await translationGate.release()
            return attempt
        } catch {
            await translationGate.release()
            let details = Self.describe(error)
            statusMessage = "Translation error: \(error.localizedDescription)"
            AppLogger.log("Translation failed: \(details)")
            return TranslationAttempt(text: "", error: details)
        }
    }

    // MARK: - Display timing

    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = Task {
            while !recentCaptions.isEmpty {
                guard let oldest = recentCaptions.first else { break }
                let readingTime = Self.estimateReadingTime(
                    english: oldest.englishText,
                    chinese: oldest.chineseText
                )
                let age = Date.now.timeIntervalSince(oldest.timestamp)
                let remaining = readingTime - age

                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                    if Task.isCancelled { break }
                }

                if !recentCaptions.isEmpty {
                    recentCaptions.removeFirst()
                }
            }
        }
    }

    nonisolated static func estimateReadingTime(
        english: String,
        chinese: String
    ) -> TimeInterval {
        let englishTime = Double(english.count) / 15.0
        let chineseTime = Double(chinese.count) / 8.0
        let baseTime = max(englishTime, chineseTime)
        let bilingualTime = baseTime * 1.3
        return min(max(bilingualTime, 2.5), 10.0)
    }
}

private struct TranslationAttempt {
    let text: String
    let error: String?
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
