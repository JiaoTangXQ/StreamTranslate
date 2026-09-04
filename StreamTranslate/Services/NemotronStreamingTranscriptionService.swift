import Foundation

enum NemotronStreamingTranscriptionError: Error, LocalizedError {
    case assetsMissing(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .assetsMissing(let path):
            return "Nemotron is not installed. Run scripts/install-nemotron.sh; expected assets under \(path)"
        case .runtime(let message):
            return message
        }
    }
}

struct NemotronRuntimePaths: Sendable {
    static let modelFilename = "nemotron-speech-streaming-en-0.6b.q8_0.gguf"

    let library: URL
    let model: URL

    static var root: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("StreamTranslate", isDirectory: true)
        .appendingPathComponent("Nemotron", isDirectory: true)
    }

    static func installed() throws -> NemotronRuntimePaths {
        let root = root
        let paths = NemotronRuntimePaths(
            library: root
                .appendingPathComponent("runtime/nemo-speech/lib", isDirectory: true)
                .appendingPathComponent("libnemo_speech_asr_c.1.dylib"),
            model: root
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(modelFilename)
        )
        guard FileManager.default.isReadableFile(atPath: paths.library.path),
              FileManager.default.isReadableFile(atPath: paths.model.path) else {
            throw NemotronStreamingTranscriptionError.assetsMissing(root.path)
        }
        return paths
    }
}

private struct NemotronBridgeResult: Sendable {
    let text: String
    let isFinal: Bool
    let audioProcessed: TimeInterval
}

private final class NemotronEngineHandle: @unchecked Sendable {
    private let engine: OpaquePointer

    init(paths: NemotronRuntimePaths) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let created = paths.library.path.withCString { libraryPath in
            paths.model.path.withCString { modelPath in
                STNemotronEngineCreate(libraryPath, modelPath, &errorPointer)
            }
        }
        guard let created else {
            throw NemotronStreamingTranscriptionError.runtime(
                Self.takeError(&errorPointer, fallback: "Could not load Nemotron")
            )
        }
        engine = created
        if let errorPointer {
            STNemotronStringFree(errorPointer)
        }
    }

    deinit {
        STNemotronEngineDestroy(engine)
    }

    func start(vocabulary: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let succeeded = vocabulary.withCString {
            STNemotronEngineStart(engine, $0, &errorPointer)
        }
        guard succeeded else {
            throw NemotronStreamingTranscriptionError.runtime(
                Self.takeError(&errorPointer, fallback: "Could not start Nemotron")
            )
        }
        if let errorPointer {
            STNemotronStringFree(errorPointer)
        }
    }

    func push(samples: [Float]) throws -> [NemotronBridgeResult] {
        guard !samples.isEmpty else { return [] }
        var batch = STNemotronResultBatch(items: nil, count: 0)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let succeeded = samples.withUnsafeBufferPointer { buffer in
            STNemotronEnginePush(
                engine,
                buffer.baseAddress,
                buffer.count,
                16_000,
                &batch,
                &errorPointer
            )
        }
        guard succeeded else {
            throw NemotronStreamingTranscriptionError.runtime(
                Self.takeError(&errorPointer, fallback: "Nemotron rejected audio")
            )
        }
        return Self.takeResults(&batch)
    }

    func finish() throws -> [NemotronBridgeResult] {
        var batch = STNemotronResultBatch(items: nil, count: 0)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let succeeded = STNemotronEngineFinish(engine, &batch, &errorPointer)
        guard succeeded else {
            throw NemotronStreamingTranscriptionError.runtime(
                Self.takeError(&errorPointer, fallback: "Could not finalize Nemotron")
            )
        }
        return Self.takeResults(&batch)
    }

    func cancel() {
        STNemotronEngineCancel(engine)
    }

    private static func takeResults(
        _ batch: inout STNemotronResultBatch
    ) -> [NemotronBridgeResult] {
        defer { STNemotronResultBatchFree(&batch) }
        guard let items = batch.items else { return [] }
        return (0..<batch.count).compactMap { index in
            let item = items[index]
            guard let text = item.text else { return nil }
            return NemotronBridgeResult(
                text: String(cString: text),
                isFinal: item.isFinal,
                audioProcessed: TimeInterval(item.audioProcessed)
            )
        }
    }

    private static func takeError(
        _ pointer: inout UnsafeMutablePointer<CChar>?,
        fallback: String
    ) -> String {
        guard let value = pointer else { return fallback }
        pointer = nil
        defer { STNemotronStringFree(value) }
        return String(cString: value)
    }
}

/// Runs NVIDIA's stateful 0.6B English recognizer through its native Metal C
/// ABI. Runtime/model assets are optional and live in Application Support so
/// the low-memory Apple Speech path remains usable without a 667 MB download.
final class NemotronStreamingTranscriptionService:
    StreamingTranscriptionProviding, @unchecked Sendable {
    private static let sampleRate = 16_000.0

    private struct RunningOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let engine: NemotronEngineHandle
    private let lock = NSLock()
    private var runningOperation: RunningOperation?

    private init(engine: NemotronEngineHandle) {
        self.engine = engine
    }

    static func load() async throws -> NemotronStreamingTranscriptionService {
        let paths = try NemotronRuntimePaths.installed()
        let engine = try await Task.detached(priority: .userInitiated) {
            try NemotronEngineHandle(paths: paths)
        }.value
        return NemotronStreamingTranscriptionService(engine: engine)
    }

    func updates(
        from audioStream: AsyncStream<CapturedAudioChunk>,
        vocabulary: String
    ) -> AsyncThrowingStream<StreamingTranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let engine = self.engine
            let operationID = UUID()
            let previous = lock.withLock { runningOperation }
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    previous?.task.cancel()
                    await previous?.task.value
                    try Task.checkCancellation()
                    engine.cancel()
                    try engine.start(vocabulary: vocabulary)
                    var segmentStartSample: Int64 = 0
                    for await chunk in audioStream {
                        try Task.checkCancellation()
                        let started = ContinuousClock.now
                        let results = try engine.push(samples: chunk.samples)
                        let latency = Self.seconds(started.duration(to: .now))
                        Self.yield(
                            results,
                            segmentStartSample: &segmentStartSample,
                            processingLatency: latency,
                            continuation: continuation
                        )
                    }
                    try Task.checkCancellation()
                    let started = ContinuousClock.now
                    let results = try engine.finish()
                    Self.yield(
                        results,
                        segmentStartSample: &segmentStartSample,
                        processingLatency: Self.seconds(started.duration(to: .now)),
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    engine.cancel()
                    continuation.finish()
                } catch {
                    engine.cancel()
                    continuation.finish(throwing: error)
                }
                self?.clearRunningTask(matching: operationID)
            }

            lock.withLock {
                runningOperation = RunningOperation(id: operationID, task: task)
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
                self?.cancelEngineIfCurrent(operationID)
            }
        }
    }

    func cancel() {
        let operation = lock.withLock { () -> RunningOperation? in
            let operation = runningOperation
            runningOperation = nil
            return operation
        }
        operation?.task.cancel()
        engine.cancel()
    }

    private func clearRunningTask(matching operationID: UUID) {
        lock.withLock {
            if runningOperation?.id == operationID {
                runningOperation = nil
            }
        }
    }

    private func cancelEngineIfCurrent(_ operationID: UUID) {
        let shouldCancel = lock.withLock {
            runningOperation?.id == operationID
        }
        if shouldCancel {
            engine.cancel()
        }
    }

    private static func yield(
        _ results: [NemotronBridgeResult],
        segmentStartSample: inout Int64,
        processingLatency: TimeInterval,
        continuation: AsyncThrowingStream<StreamingTranscriptionUpdate, Error>.Continuation
    ) {
        for result in results {
            let endSample = max(
                segmentStartSample,
                Int64((result.audioProcessed * sampleRate).rounded())
            )
            let startSample = segmentStartSample
            if result.isFinal {
                segmentStartSample = endSample
            }
            let text = result.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty,
                  !TranscriptionTextPolicy.isNonSpeechOnly(text),
                  !TranscriptionTextPolicy.isDegenerateRepetition(text) else {
                continue
            }
            continuation.yield(
                StreamingTranscriptionUpdate(
                    output: TranscriptionOutput(
                        text: text,
                        language: .english,
                        reportedLanguageCode: "en",
                        words: []
                    ),
                    startSample: startSample,
                    endSample: endSample,
                    isFinal: result.isFinal,
                    processingLatency: processingLatency
                )
            )
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
