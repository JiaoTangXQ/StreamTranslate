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

struct FinalTranslationRequest: Sendable {
    let entryID: UUID
    let segment: SpeechSegment
    let output: TranscriptionOutput
    let sourceText: String
    let direction: TranslationDirection
    let generation: Int
    let queuedAt: Date
    let logger: MeetingSessionLogger?
    var corroboratingOriginal: String = ""
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
    let historyRevision: Int
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
    var isFinalizingCapture = false
    var isChangingCaptureConfiguration = false
    var quickControlMessage = ""
    @ObservationIgnored private var captureStopTask: Task<Void, Never>?
    @ObservationIgnored private var quickResumeRequested = false
    @ObservationIgnored private var captureStartGeneration = 0
    @ObservationIgnored private var finalizingCaptureGeneration: Int?
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
    static let maximumFloatingHistory = 100
    var floatingCaptionHistory: ArraySlice<CaptionEntry> {
        captionHistory.suffix(Self.maximumFloatingHistory - (hasStreamingText ? 1 : 0))
    }
    let historyStore: CaptionHistoryStore?
    @ObservationIgnored private var captionArchiveSessions: [UUID: (UUID, Date)] = [:]
    @ObservationIgnored private var captionWorkCounts: [UUID: Int] = [:]
    @ObservationIgnored private var retainedCaptionUpdates: [UUID: CaptionEntry] = [:]
    var recentCaptions: [CaptionEntry] = []
    private(set) var historyRevision = 0
    private(set) var companionSessionID = UUID()
    private(set) var companionSessionStartedAt = Date.distantPast

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
            historyRevision: historyRevision,
            streamingSegmentStartSample: streamingSegmentStartSample
        )
    }

    private let maxRecentCaptions = 2
    private var audioCaptureService: AudioCaptureService?
    private var sessionLogger: MeetingSessionLogger?
    private var transcriptionService: WhisperTranscriptionService?
    private var streamingTranscriptionService: (any StreamingTranscriptionProviding)?
    private var segmentationTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var partialTranslationTask: Task<Void, Never>?
    private var activePartialTranslationOperation: Task<Void, Never>?
    private var partialTranslationQueue: PartialTranslationQueue?
    private var pendingFinalTranslations: [FinalTranslationRequest] = []
    private var finalTranslationWorker: Task<Void, Never>?
    private var finalTranslationWorkerID: UUID?
    private var audioReviewTap: Task<Void, Never>?
    private var reviewAudio: ReviewAudioBuffer?
    private var reviewService: (any RecognitionReviewProviding)?
    private var recognitionReviewWorker: Task<Void, Never>?
    private var recognitionReviewWorkerID: UUID?
    private var pendingRecognitionReviews: [(FinalTranslationRequest, [Float], [Float])] = []
    private var translationRefiner: (any TranslationRefinementProviding)?
    private var translationRefinementWorker: Task<Void, Never>?
    private var translationRefinementWorkerID: UUID?
    private var pendingTranslationRefinements: [FinalTranslationRequest] = []
    private var refinedSources: [UUID: String] = [:]
    private var refinementContextStart: Date = .distantFuture
    private var memoryPressureMonitor: (any DispatchSourceMemoryPressure)?
    private var memoryPressureMonitorID: UUID?
    private var cleanupTask: Task<Void, Never>?
    private var readyTranslationDirections: Set<TranslationDirection> = []
    private var transcriptionContext = TranscriptionContext()
    private var captionTextStabilizer = CaptionTextStabilizer()
    private let translationGate = TranslationGate()
    private var captionGeneration = 0
    private var streamingSegmentStartSample: Int64?
    private var streamingSegmentEndSample: Int64?
    private var latestRecognizedOriginal = ""
    private var initialPhraseTask: Task<Void, Never>?
    private var lastPartialTranslationRequestText = ""
    private var lastPartialTranslationRequestAt: ContinuousClock.Instant?
    private var pendingPartialTranslation: PartialTranslationRequest?
    private var partialTranslationDeadlineTask: Task<Void, Never>?
    private var activeRecognitionVocabulary = ""
    private var activeModel = ASRModel.defaultModel

    // MARK: - Lifecycle

    init(historyStore: CaptionHistoryStore? = nil) {
        self.historyStore = historyStore
    }

    func preloadModel(modelId: String = ASRModel.defaultModel.id) {
        guard !isModelReady, !isLoading else { return }
        loadModel(modelId: modelId, switching: false)
    }

    func switchModel(to modelId: String) {
        guard !isLoading, !isStartingCapture, !isFinalizingCapture else { return }
        if isRecording {
            stopCapture(gracefully: false)
        }
        transcriptionService = nil
        streamingTranscriptionService?.cancel()
        streamingTranscriptionService = nil
        isModelReady = false
        loadModel(modelId: modelId, switching: true)
    }

    private func loadModel(modelId: String, switching: Bool) {
        let model = ASRModel.available.first { $0.id == modelId }
            ?? ASRModel.defaultModel
        let modelName = model.name
        isLoading = true
        statusMessage = switching ? "Switching to \(modelName)..." : "Loading \(modelName)..."
        downloadProgress = model.backend == .whisperKit ? 0 : nil
        downloadError = nil

        Task {
            do {
                switch model.backend {
                case .nemotron:
                    AppLogger.log("Loading Nemotron streaming English model")
                    let service = try await NemotronStreamingTranscriptionService.load()
                    streamingTranscriptionService = service
                    transcriptionService = nil
                case .appleSpeech:
                    let language = model.requiredRecognitionMode?.languageHint ?? .english
                    AppLogger.log("Preparing Apple streaming \(language.displayName) model")
                    let service = AppleStreamingTranscriptionService(language: language)
                    try await service.prepare()
                    streamingTranscriptionService = service
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
                    streamingTranscriptionService = nil
                }
                activeModel = model
                isModelReady = true
                statusMessage = ""
                downloadProgress = nil
                downloadError = nil
                AppLogger.log("Speech model ready: \(modelId)")
            } catch {
                let details = Self.describe(error)
                AppLogger.log("Speech model load failed: \(details)")
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

    func beginCompanionSession() {
        companionSessionID = UUID()
        companionSessionStartedAt = .now
    }

    func clearHistory() {
        beginCompanionSession()
        captionGeneration += 1
        cancelRecognitionReviews(stopService: false)
        cancelTranslationRefinements(stopService: false)
        refinedSources = [:]
        refinementContextStart = .now
        activePartialTranslationOperation?.cancel()
        activePartialTranslationOperation = nil
        finalTranslationWorker?.cancel()
        finalTranslationWorker = nil
        finalTranslationWorkerID = nil
        pendingFinalTranslations = []
        captionHistory = []
        captionArchiveSessions = [:]
        captionWorkCounts = [:]
        retainedCaptionUpdates = [:]
        recentCaptions = []
        historyRevision += 1
        clearStreamingState()
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    // MARK: - Capture control

    /// One user action owns stop → configure → prepare → optional resume.
    /// No detached UI observer is allowed to start a second model switch.
    func changeCaptureConfiguration(settings: CaptionSettings,
                                    source: AudioInputSource? = nil,
                                    mode: RecognitionLanguageMode? = nil) {
        guard !isChangingCaptureConfiguration, !isStartingCapture,
              !isFinalizingCapture, !isLoading else { return }
        guard (source != nil && source != settings.audioInputSource)
                || (mode != nil && mode != settings.recognitionLanguageMode) else { return }
        let wasRecording = isRecording
        isChangingCaptureConfiguration = true
        quickControlMessage = wasRecording ? "正在收尾并切换，音频会短暂中断…" : "正在应用选择…"
        if wasRecording { stopCapture() }
        quickResumeRequested = wasRecording
        Task { @MainActor in
            defer { isChangingCaptureConfiguration = false; quickResumeRequested = false }
            await captureStopTask?.value
            if let source { settings.audioInputSource = source }
            if let mode { settings.recognitionLanguageMode = mode }
            if activeModel.id != settings.selectedModelId || !isModelReady {
                quickControlMessage = "正在准备\(settings.recognitionLanguageMode.displayName)识别；首次可能需要下载模型…"
                switchModel(to: settings.selectedModelId)
                while isLoading { try? await Task.sleep(for: .milliseconds(100)) }
                guard isModelReady, activeModel.id == settings.selectedModelId else {
                    quickControlMessage = "未能完成切换：\(statusMessage)"
                    return
                }
            }
            if quickResumeRequested {
                quickControlMessage = "正在恢复收音…"
                await startCapture(source: settings.audioInputSource,
                    sensitivity: settings.speechDetectionSensitivity,
                    recognitionMode: settings.recognitionLanguageMode,
                    recognitionVocabulary: settings.recognitionVocabulary,
                    captureDiagnosticsEnabled: settings.captureDiagnosticsEnabled)
                quickControlMessage = isRecording ? "" : "未能恢复收音：\(statusMessage)"
            } else { quickControlMessage = "" }
        }
    }

    func toggleCapture(
        source: AudioInputSource = .microphone,
        sensitivity: SpeechDetectionSensitivity = .automatic,
        recognitionMode: RecognitionLanguageMode = .automatic,
        recognitionVocabulary: String = "",
        captureDiagnosticsEnabled: Bool = false
    ) {
        if isChangingCaptureConfiguration {
            quickResumeRequested = false
            if isStartingCapture { stopCapture(gracefully: false) }
            quickControlMessage = "已取消自动恢复；完成当前准备后保持停止。"
            return
        }
        AppLogger.log("toggleCapture called, isRecording=\(isRecording), isModelReady=\(isModelReady)")
        if isRecording {
            stopCapture()
        } else if !isStartingCapture, !isFinalizingCapture {
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
        guard !isRecording, !isStartingCapture, !isFinalizingCapture else { return }
        isStartingCapture = true
        defer { isStartingCapture = false }
        let startGeneration = captureStartGeneration

        if !isModelReady {
            preloadModel()
            while isLoading {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard isModelReady else { return }
        }

        guard startGeneration == captureStartGeneration else { return }
        guard (activeModel.usesNativeStreaming
                && streamingTranscriptionService != nil)
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
        guard activeModel.supports(recognitionMode) else {
            statusMessage = "Recognition language does not match the loaded model. Select a compatible model in Settings."
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
            statusMessage = source == .microphone
                ? "Starting microphone capture..."
                : "Starting system audio capture..."
            AppLogger.log("Starting audio capture: \(source.rawValue)")

            try await audioService.start()
            guard startGeneration == captureStartGeneration else {
                await audioService.stop()
                logger?.finish()
                audioCaptureService = nil; sessionLogger = nil
                return
            }
            // A quick source/language switch is still the same conversation.
            // A separate user-started recording keeps the existing fresh-session boundary.
            if !isChangingCaptureConfiguration { beginCompanionSession() }
            isRecording = true
            statusMessage = ""
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

    func stopCapture(gracefully: Bool = true) {
        captureStartGeneration &+= 1
        quickResumeRequested = false
        if gracefully, activeModel.usesNativeStreaming {
            stopStreamingCaptureGracefully()
            return
        }

        isRecording = false
        finalizingCaptureGeneration = nil
        memoryPressureMonitor?.cancel()
        memoryPressureMonitor = nil
        memoryPressureMonitorID = nil
        cancelRecognitionReviews(stopService: true)
        cancelTranslationRefinements(stopService: true)
        audioReviewTap?.cancel()
        audioReviewTap = nil
        segmentationTask?.cancel()
        segmentationTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        streamingTranscriptionService?.cancel()
        partialTranslationTask?.cancel()
        partialTranslationTask = nil
        activePartialTranslationOperation?.cancel()
        activePartialTranslationOperation = nil
        let translationQueue = partialTranslationQueue
        partialTranslationQueue = nil

        let service = audioCaptureService
        let logger = sessionLogger
        captureStopTask = Task {
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

    private func stopStreamingCaptureGracefully() {
        guard isRecording, !isFinalizingCapture else { return }
        finalizingCaptureGeneration = captureStartGeneration - 1
        isRecording = false
        isFinalizingCapture = true
        statusMessage = "Finalizing last words..."

        let service = audioCaptureService
        let logger = sessionLogger
        let recognition = pipelineTask
        let translations = partialTranslationTask
        let translationQueue = partialTranslationQueue
        audioCaptureService = nil
        sessionLogger = nil
        pipelineTask = nil
        partialTranslationTask = nil
        partialTranslationQueue = nil
        segmentationTask?.cancel()
        segmentationTask = nil
        transcriptionContext.reset()

        captureStopTask = Task {
            await service?.stop()
            await recognition?.value
            await translationQueue?.finish()
            translations?.cancel()
            await translations?.value
            activePartialTranslationOperation?.cancel()
            activePartialTranslationOperation = nil

            if hasStreamingText {
                addCaption(
                    english: streamingEnglish,
                    chinese: streamingChinese,
                    sourceLanguage: streamingSourceLanguage
                )
                clearStreamingState()
            }

            await waitForFinalTranslations()
            memoryPressureMonitor?.cancel()
            memoryPressureMonitor = nil
            memoryPressureMonitorID = nil
            cancelRecognitionReviews(stopService: true)
            cancelTranslationRefinements(stopService: true)
            audioReviewTap?.cancel()
            audioReviewTap = nil
            logger?.finish()
            finalizingCaptureGeneration = nil
            isFinalizingCapture = false
            if statusMessage == "Finalizing last words..." {
                statusMessage = ""
            }
            AppLogger.log("Streaming audio capture stopped after finalization")
        }
    }

    // MARK: - Multilingual transcription pipeline

    private func runPipeline(
        audioStream: AsyncStream<CapturedAudioChunk>,
        sensitivity: SpeechDetectionSensitivity,
        recognitionMode: RecognitionLanguageMode
    ) {
        startMemoryPressureMonitor()
        if UserDefaults.standard.object(forKey: "translationRefinementEnabled") as? Bool != false,
           LocalHYTranslationService.isInstalled {
            let refiner = LocalHYTranslationService()
            configureTranslationRefinement(refiner)
            Task {
                do { try await refiner.prepare(); AppLogger.log("Local Hy-MT bidirectional refinement ready") }
                catch { refiner.cancel(); AppLogger.log("Local Hy-MT unavailable; keeping Apple translation: \(error)") }
            }
        }
        if activeModel.usesNativeStreaming {
            runNativeStreamingPipeline(audioStream: audioStream)
            return
        }
        runWhisperPipeline(
            audioStream: audioStream,
            sensitivity: sensitivity,
            recognitionMode: recognitionMode
        )
    }

    private func runNativeStreamingPipeline(
        audioStream: AsyncStream<CapturedAudioChunk>
    ) {
        guard let transcription = streamingTranscriptionService else { return }
        var recognitionAudio = audioStream
        if UserDefaults.standard.object(forKey: "recognitionReviewEnabled") as? Bool != false,
           LocalQwenService.isInstalled {
            let buffer = ReviewAudioBuffer()
            let reviewer = LocalQwenService()
            configureRecognitionReview(reviewer, audio: buffer)
            Task {
                do { try await reviewer.prepare(); AppLogger.log("Local Qwen review ready") }
                catch { AppLogger.log("Local Qwen review unavailable; keeping fast recognition: \(error)") }
            }
            let (stream, continuation) = AsyncStream<CapturedAudioChunk>.makeStream()
            recognitionAudio = stream
            audioReviewTap = Task {
                for await chunk in audioStream {
                    guard !Task.isCancelled else { break }
                    buffer.append(chunk.samples)
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
        let logger = sessionLogger
        let translationQueue = PartialTranslationQueue()
        partialTranslationQueue = translationQueue

        AppLogger.log("Recognition profile: \(activeModel.name) continuous \(activeModel.requiredRecognitionMode?.rawValue ?? "automatic")")
        logger?.recordPipelineStatus(
            "recognition_backend",
            detail: activeModel.id
        )
        startPartialTranslationWorker(translationQueue, logger: logger)

        startNativeStreamingUpdates(transcription.updates(from: recognitionAudio,
            vocabulary: activeRecognitionVocabulary), logger: logger, partialTranslations: translationQueue)
    }

    func startNativeStreamingUpdates(_ updates: AsyncThrowingStream<StreamingTranscriptionUpdate, Error>,
        logger: MeetingSessionLogger?, partialTranslations: PartialTranslationQueue) {
        let generation = captureStartGeneration
        pipelineTask = Task { [weak self] in
            await self?.consumeNativeStreamingUpdates(updates, logger: logger,
                partialTranslations: partialTranslations, captureGeneration: generation)
        }
    }

    /// A terminated recognizer must not leave the capture and controls claiming
    /// to be running. Generation guards keep an old session from stopping a new one.
    func consumeNativeStreamingUpdates(
        _ updates: AsyncThrowingStream<StreamingTranscriptionUpdate, Error>,
        logger: MeetingSessionLogger?, partialTranslations: PartialTranslationQueue,
        captureGeneration: Int
    ) async {
        var failure = "语音识别意外结束，请重新开始。"
        do {
            for try await update in updates {
                guard !Task.isCancelled,
                      captureGeneration == captureStartGeneration
                        || captureGeneration == finalizingCaptureGeneration else { return }
                await processStreamingUpdate(update, logger: logger, partialTranslations: partialTranslations)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failure = "语音识别已中断，请重新开始：\(Self.describe(error))"
        }
        guard !Task.isCancelled, isRecording, captureGeneration == captureStartGeneration else { return }
        logger?.recordPipelineStatus("recognition_terminated", detail: failure)
        AppLogger.log("Native streaming transcription terminated [\(activeModel.backend.rawValue)]: \(failure)")
        stopCapture(gracefully: false)
        statusMessage = failure
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
        startPartialTranslationWorker(translationQueue, logger: logger)

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

    /// Shared by native/Whisper pipelines and the local replay benchmark.
    func startPartialTranslationWorker(
        _ translationQueue: PartialTranslationQueue,
        logger: MeetingSessionLogger?
    ) {
        partialTranslationTask?.cancel()
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

    // Also used by the local replay checks, exercising the production pipeline
    // without capturing a microphone or system audio.
    func processStreamingUpdate(
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
        initialPhraseTask?.cancel()
        initialPhraseTask = nil
        showStreamingPartial(output, segment: segment)
        let sourceText = TranslationDraftPlanner.prefix(in: output.text, language: output.language)
        let request = PartialTranslationRequest(
            segment: segment,
            output: output,
            sourceText: sourceText,
            direction: direction,
            generation: captionGeneration
        )
        await schedulePartialTranslation(request, queue: partialTranslations)
        if lastPartialTranslationRequestText.isEmpty,
           !TranslationDraftPlanner.hasEnoughContext(sourceText, language: output.language),
           TranslationDraftPlanner.canSettleInitialPhrase(output.text, language: output.language) {
            let settled = PartialTranslationRequest(segment: segment, output: output,
                sourceText: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
                direction: direction, generation: captionGeneration)
            initialPhraseTask = Task { [weak self] in
                do { try await Task.sleep(for: TranslationDraftPlanner.initialSettleDelay) }
                catch { return }
                guard !Task.isCancelled, let self,
                      self.lastPartialTranslationRequestText.isEmpty,
                      self.latestRecognizedOriginal == output.text else { return }
                self.initialPhraseTask = nil
                await self.submitPartialTranslation(settled, queue: partialTranslations)
            }
        }
        AppLogger.log(
            "Partial \(output.language.rawValue) (reported \(output.reportedLanguageCode)): \(output.text)"
        )
    }

    private func schedulePartialTranslation(
        _ request: PartialTranslationRequest,
        queue: PartialTranslationQueue
    ) async {
        guard TranslationDraftPlanner.hasEnoughContext(
                request.sourceText, language: request.output.language
              ),
              !lastPartialTranslationRequestText.hasPrefix(request.sourceText) else {
            cancelPendingPartialTranslation()
            return
        }
        let elapsed = lastPartialTranslationRequestAt.map {
            let duration = $0.duration(to: .now)
            return Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
        } ?? 0
        if lastPartialTranslationRequestText.isEmpty || PartialTranslationPolicy.shouldRequest(
            previousText: lastPartialTranslationRequestText,
            stableText: request.sourceText,
            language: request.output.language,
            elapsedSinceLastRequest: elapsed
        ) {
            await submitPartialTranslation(request, queue: queue)
            return
        }

        pendingPartialTranslation = request
        // Keep the original deadline while replacing pending text. A trailing
        // debounce would starve translation during continuous speech.
        guard partialTranslationDeadlineTask == nil else { return }
        let deadline = (lastPartialTranslationRequestAt ?? .now).advanced(
            by: .seconds(PartialTranslationPolicy.maximumWait)
        )
        partialTranslationDeadlineTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard !Task.isCancelled, let self,
                  let latest = self.pendingPartialTranslation else { return }
            self.partialTranslationDeadlineTask = nil
            await self.submitPartialTranslation(latest, queue: queue)
        }
    }

    private func submitPartialTranslation(
        _ request: PartialTranslationRequest,
        queue: PartialTranslationQueue
    ) async {
        cancelPendingPartialTranslation()
        guard request.generation == captionGeneration,
              streamingSegmentStartSample == request.segment.startSample,
              streamingSourceLanguage == request.output.language else { return }
        lastPartialTranslationRequestText = request.sourceText
        lastPartialTranslationRequestAt = .now
        await queue.submit(request)
    }

    private func cancelPendingPartialTranslation() {
        initialPhraseTask?.cancel()
        initialPhraseTask = nil
        partialTranslationDeadlineTask?.cancel()
        partialTranslationDeadlineTask = nil
        pendingPartialTranslation = nil
    }

    private func processPartialTranslation(
        _ request: PartialTranslationRequest,
        logger: MeetingSessionLogger?
    ) async {
        guard request.generation == captionGeneration else { return }
        let translationStarted = Date()
        logger?.recordTranslation(
            "partial_translation_started",
            segment: request.segment,
            sourceText: request.sourceText,
            translatedText: "",
            direction: request.direction,
            duration: 0
        )
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
              latestRecognizedOriginal.hasPrefix(request.sourceText) else { return }
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
        // Native finals may trim silence from both ends of a volatile range.
        // A newer draft extending beyond an older final must remain live.
        let finalizedDraftStart = streamingSegmentStartSample
        let finalizesDraft: Bool
        if let start = streamingSegmentStartSample, let end = streamingSegmentEndSample {
            finalizesDraft = start == segment.startSample || (
                start < segment.endSample && end > segment.startSample
                && (start <= segment.startSample || end <= segment.endSample)
            )
        } else {
            finalizesDraft = false
        }
        if finalizesDraft {
            cancelPendingPartialTranslation()
            activePartialTranslationOperation?.cancel()
        }
        await partialTranslations.discard(segmentStartingAt: segment.startSample)
        if finalizesDraft, let finalizedDraftStart, finalizedDraftStart != segment.startSample {
            await partialTranslations.discard(segmentStartingAt: finalizedDraftStart)
        }
        // A delayed final for an older range must not reset the live range's
        // frozen prefix or its pending translation deadline.
        var finalStabilizer = finalizesDraft
            ? captionTextStabilizer : CaptionTextStabilizer()
        let finalPresentation = finalStabilizer.finalize(
            text: output.text, segmentStartSample: segment.startSample
        )
        let finalText = finalPresentation.recognizedText
        guard !finalText.isEmpty else { return }
        let draftTranslation: String
        let corroboratingOriginal = finalizesDraft ? latestRecognizedOriginal : ""
        if finalizesDraft,
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
        if finalizesDraft {
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

        let request = FinalTranslationRequest(
                entryID: entry.id,
                segment: segment,
                output: output,
                sourceText: finalText,
                direction: direction,
                generation: captionGeneration,
                queuedAt: .now,
                logger: logger,
                corroboratingOriginal: corroboratingOriginal
            )
        enqueueFinalTranslation(request)
        if let reviewer = reviewService, reviewer.isReady,
           segment.endSample - segment.startSample >= 8000,
           segment.endSample - segment.startSample <= 320_000,
           let samples = reviewAudio?.slice(start: segment.startSample, end: segment.endSample),
           let contextSamples = reviewAudio?.contextualSlice(start: segment.startSample, end: segment.endSample) {
            // At most one running and two queued reviews. A busy verifier must
            // never accumulate seconds of stale work or block live captions.
            if pendingRecognitionReviews.count == 2 {
                releaseCaptionWork(pendingRecognitionReviews.removeFirst().0.entryID)
            }
            retainCaptionWork(request.entryID)
            pendingRecognitionReviews.append((request, samples, contextSamples))
            startRecognitionReviewWorker(reviewer)
        }
    }

    /// Shared setup for live audio and deterministic local replay/tests.
    func configureRecognitionReview(_ reviewer: any RecognitionReviewProviding, audio: ReviewAudioBuffer) {
        cancelRecognitionReviews(stopService: true)
        reviewAudio = audio
        reviewService = reviewer
    }

    private func startRecognitionReviewWorker(_ reviewer: any RecognitionReviewProviding) {
        guard recognitionReviewWorker == nil else { return }
        let workerID = UUID()
        recognitionReviewWorkerID = workerID
        recognitionReviewWorker = Task { [weak self] in
            while !Task.isCancelled, let self, !self.pendingRecognitionReviews.isEmpty {
                let (request, samples, contextSamples) = self.pendingRecognitionReviews.removeFirst()
                defer { self.releaseCaptionWork(request.entryID) }
                guard request.generation == self.captionGeneration else { continue }
                let began = Date()
                do {
                    let primary = try await reviewer.transcribe(samples)
                    guard !Task.isCancelled,
                          primary.trimmingCharacters(in: .whitespacesAndNewlines) != request.sourceText
                            || RecognitionReviewPolicy.hasPriorDisagreement(request.corroboratingOriginal, with: request.sourceText, language: request.output.language) else { continue }
                    let contextual = try await reviewer.transcribe(contextSamples)
                    guard !Task.isCancelled, request.generation == self.captionGeneration,
                          let revised = RecognitionReviewPolicy.consensus(primary: primary, contextual: contextual,
                            original: request.sourceText, language: request.output.language, priorHypothesis: request.corroboratingOriginal),
                          revised != request.sourceText,
                          let entry = self.captionForUpdate(request.entryID),
                          entry.originalText == request.sourceText else { continue }
                    self.updateCaption(id: entry.id,
                        english: request.output.language == .english ? revised : entry.englishText,
                        chinese: request.output.language == .chinese ? revised : entry.chineseText,
                        sourceLanguage: request.output.language)
                    request.logger?.recordTranslation("source_reviewed", segment: request.segment,
                        sourceText: revised, translatedText: entry.translatedText,
                        direction: request.direction, duration: Date().timeIntervalSince(began))
                    AppLogger.log("Local Qwen source reviewed in \(Date().timeIntervalSince(began))s: \(revised)")
                    self.enqueueFinalTranslation(FinalTranslationRequest(entryID: request.entryID,
                        segment: request.segment, output: request.output, sourceText: revised,
                        direction: request.direction, generation: request.generation,
                        queuedAt: .now, logger: request.logger))
                } catch {
                    AppLogger.log("Local Qwen review failed; keeping original caption: \(error)")
                }
            }
            guard let self, self.recognitionReviewWorkerID == workerID else { return }
            self.recognitionReviewWorker = nil
            self.recognitionReviewWorkerID = nil
        }
    }

    private func cancelRecognitionReviews(stopService: Bool) {
        recognitionReviewWorker?.cancel()
        recognitionReviewWorker = nil
        recognitionReviewWorkerID = nil
        for (request, _, _) in pendingRecognitionReviews { releaseCaptionWork(request.entryID) }
        pendingRecognitionReviews = []
        if stopService {
            reviewService?.cancel()
            reviewService = nil
            reviewAudio = nil
        }
    }

    private func enqueueFinalTranslation(_ request: FinalTranslationRequest) {
        retainCaptionWork(request.entryID)
        pendingFinalTranslations.append(request)
        startFinalTranslationWorkerIfNeeded()
    }

    func waitForFinalTranslations() async {
        await recognitionReviewWorker?.value
        await finalTranslationWorker?.value
        await translationRefinementWorker?.value
    }

    private func startFinalTranslationWorkerIfNeeded() {
        guard finalTranslationWorker == nil,
              !pendingFinalTranslations.isEmpty else { return }
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
            self?.startFinalTranslationWorkerIfNeeded()
        }
    }

    private func takeNextFinalTranslationBatch() -> [FinalTranslationRequest]? {
        pendingFinalTranslations.removeAll {
            if $0.generation != captionGeneration || !isCurrentFinalTranslation($0) {
                releaseCaptionWork($0.entryID)
                return true
            }
            return false
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
        defer { for request in batch { releaseCaptionWork(request.entryID) } }
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
            guard batch.contains(where: { isCurrentFinalTranslation($0) }) else { return }
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
        guard isCurrentFinalTranslation(request) else { return }
        guard refinedSources[request.entryID] != request.sourceText else { return }
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
        enqueueTranslationRefinement(request)
    }

    func configureTranslationRefinement(_ refiner: any TranslationRefinementProviding) {
        cancelTranslationRefinements(stopService: true)
        translationRefiner = refiner
        refinementContextStart = .now
    }

    func startMemoryPressureMonitor() {
        memoryPressureMonitor?.cancel()
        let monitorID = UUID()
        memoryPressureMonitorID = monitorID
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.memoryPressureMonitorID == monitorID else { return }
                self.suspendLocalEnhancementsForMemoryPressure()
            }
        }
        memoryPressureMonitor = monitor
        monitor.resume()
    }

    /// Preserve the base audio/ASR/translation pipeline; never restart models in
    /// this capture after pressure, which would cause allocation/reload thrashing.
    func suspendLocalEnhancementsForMemoryPressure() {
        cancelRecognitionReviews(stopService: true)
        cancelTranslationRefinements(stopService: true)
        memoryPressureMonitor?.cancel()
        memoryPressureMonitor = nil
        memoryPressureMonitorID = nil
        AppLogger.log("Memory pressure: local enhancements released; keeping system subtitles")
    }

    func refinementContext(for request: FinalTranslationRequest) -> String {
        // The service may derive constrained terminology from this bounded
        // context, or resolve a tightly constrained grammatical ellipsis.
        // Raw background is never passed to the small translation model.
        guard let index = captionHistory.firstIndex(where: { $0.id == request.entryID }) else { return "" }
        return String(captionHistory[..<index].filter {
            $0.timestamp >= refinementContextStart && $0.sourceLanguage == request.output.language
        }.suffix(2).map(\.originalText).joined(separator: "\n").suffix(600))
    }

    func enqueueTranslationRefinement(_ request: FinalTranslationRequest) {
        guard let refiner = translationRefiner, refiner.isReady else { return }
        pendingTranslationRefinements.removeAll {
            if $0.entryID == request.entryID { releaseCaptionWork($0.entryID); return true }
            return false
        }
        if pendingTranslationRefinements.count == 2 {
            releaseCaptionWork(pendingTranslationRefinements.removeFirst().entryID)
        }
        retainCaptionWork(request.entryID)
        pendingTranslationRefinements.append(request)
        guard translationRefinementWorker == nil else { return }
        let workerID = UUID()
        translationRefinementWorkerID = workerID
        translationRefinementWorker = Task { [weak self] in
            while !Task.isCancelled, let self, !self.pendingTranslationRefinements.isEmpty {
                // Give source verification priority. It may already be fixing
                // the source of this translation; stale revisions are discarded.
                if let review = self.recognitionReviewWorker { await review.value }
                guard !Task.isCancelled, !self.pendingTranslationRefinements.isEmpty else { break }
                let request = self.pendingTranslationRefinements.removeFirst()
                defer { self.releaseCaptionWork(request.entryID) }
                guard self.isCurrentFinalTranslation(request) else { continue }
                let target = UserDefaults.standard.string(forKey: "translationTarget")
                    .flatMap(TranslationTarget.init(rawValue:)) ?? .simplifiedChinese
                let began = Date()
                do {
                    let raw = try await refiner.translate(request.sourceText,
                        sourceLanguage: request.output.language, target: target, context: self.refinementContext(for: request))
                    let translated = TranslationIntegrityPolicy.normalizedPercentUnits(raw, source: request.sourceText)
                    guard !Task.isCancelled, self.isCurrentFinalTranslation(request),
                          TranslationIntegrityPolicy.accepts(translated, for: request.sourceText) else { continue }
                    self.refinedSources[request.entryID] = request.sourceText
                    self.updateCaption(id: request.entryID,
                        english: request.output.language == .english ? request.sourceText : translated,
                        chinese: request.output.language == .chinese ? request.sourceText : translated,
                        sourceLanguage: request.output.language)
                    request.logger?.recordTranslation("translation_refined", segment: request.segment,
                        sourceText: request.sourceText, translatedText: translated,
                        direction: request.direction, duration: Date().timeIntervalSince(began))
                    AppLogger.log("Local Hy-MT final translation in \(Date().timeIntervalSince(began))s: \(translated)")
                } catch {
                    AppLogger.log("Local Hy-MT refinement failed; keeping Apple translation: \(error)")
                }
            }
            guard let self, self.translationRefinementWorkerID == workerID else { return }
            self.translationRefinementWorker = nil
            self.translationRefinementWorkerID = nil
        }
    }

    private func cancelTranslationRefinements(stopService: Bool) {
        translationRefinementWorker?.cancel()
        translationRefinementWorker = nil
        translationRefinementWorkerID = nil
        for request in pendingTranslationRefinements { releaseCaptionWork(request.entryID) }
        pendingTranslationRefinements = []
        if stopService {
            translationRefiner?.cancel()
            translationRefiner = nil
        }
    }

    private func isCurrentFinalTranslation(_ request: FinalTranslationRequest) -> Bool {
        request.generation == captionGeneration
            && captionForUpdate(request.entryID)?.originalText == request.sourceText
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
            cancelPendingPartialTranslation()
            captionTextStabilizer.reset()
            streamingStableOriginal = ""
            streamingDraftOriginal = ""
            lastPartialTranslationRequestText = ""
            lastPartialTranslationRequestAt = nil
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
        streamingSegmentEndSample = segment.endSample
        latestRecognizedOriginal = output.text
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
        streamingSegmentEndSample = segment.endSample
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
        if historyStore != nil {
            captionArchiveSessions[entry.id] = (companionSessionID, companionSessionStartedAt)
        }
        historyStore?.record(entry, sessionID: companionSessionID, startedAt: companionSessionStartedAt)
        if captionHistory.count > Self.maximumFloatingHistory {
            let removed = captionHistory.prefix(captionHistory.count - Self.maximumFloatingHistory)
            for old in removed where captionWorkCounts[old.id] == nil {
                captionArchiveSessions.removeValue(forKey: old.id)
                refinedSources.removeValue(forKey: old.id)
            }
            captionHistory.removeFirst(captionHistory.count - Self.maximumFloatingHistory)
        }
        historyRevision += 1
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
        guard let previous = captionForUpdate(id) else { return }
        let updated = CaptionEntry(
            id: id,
            timestamp: previous.timestamp,
            englishText: english,
            chineseText: chinese,
            sourceLanguage: sourceLanguage
        )
        if let historyIndex = captionHistory.firstIndex(where: { $0.id == id }) {
            captionHistory[historyIndex] = updated
        }
        if captionWorkCounts[id] != nil { retainedCaptionUpdates[id] = updated }
        // An old sentence may finish translating after a new recording starts.
        // Its archive session belongs to the sentence, not the current capture.
        let session = captionArchiveSessions[id] ?? (companionSessionID, companionSessionStartedAt)
        historyStore?.record(updated, sessionID: session.0, startedAt: session.1)
        historyRevision += 1
        if let recentIndex = recentCaptions.firstIndex(where: { $0.id == id }) {
            recentCaptions[recentIndex] = updated
        }
    }

    private func captionForUpdate(_ id: UUID) -> CaptionEntry? {
        captionHistory.first(where: { $0.id == id }) ?? retainedCaptionUpdates[id]
    }

    private func retainCaptionWork(_ id: UUID) {
        guard let entry = captionForUpdate(id) else { return }
        captionWorkCounts[id, default: 0] += 1
        retainedCaptionUpdates[id] = entry
    }

    private func releaseCaptionWork(_ id: UUID) {
        guard let count = captionWorkCounts[id] else { return }
        if count > 1 { captionWorkCounts[id] = count - 1; return }
        captionWorkCounts.removeValue(forKey: id)
        retainedCaptionUpdates.removeValue(forKey: id)
        if !captionHistory.contains(where: { $0.id == id }) {
            captionArchiveSessions.removeValue(forKey: id)
            refinedSources.removeValue(forKey: id)
        }
    }

    private func clearStreamingState() {
        cancelPendingPartialTranslation()
        streamingEnglish = ""
        streamingChinese = ""
        streamingWords = []
        streamingStableOriginal = ""
        streamingDraftOriginal = ""
        streamingSegmentStartSample = nil
        streamingSegmentEndSample = nil
        latestRecognizedOriginal = ""
        lastPartialTranslationRequestText = ""
        lastPartialTranslationRequestAt = nil
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
            // Final recognition intentionally cancels an obsolete draft. This
            // is normal control flow, not a user-visible translation failure.
            if Task.isCancelled || error is CancellationError {
                return TranslationAttempt(text: "", error: nil)
            }
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
