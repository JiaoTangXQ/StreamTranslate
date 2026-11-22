import Foundation
import CompanionKit

/// Anything that produces the ordered 16 kHz mono chunks the recognizers use.
protocol AudioCaptureProviding: AnyObject, Sendable {
    /// Must be called before `start()`.
    func makeAudioStream() -> AsyncStream<CapturedAudioChunk>
    func start() async throws
    func stop() async
}

/// Turns decrypted phone uploads into the same chunk stream a local
/// microphone produces. Frames lost in transit become silence of the same
/// length, so recognizer time stays aligned with the speaker and Apple's
/// pause detection still sees the gap; a long outage is capped rather than
/// replayed as minutes of silence.
final class PhoneAudioCaptureService: AudioCaptureProviding, @unchecked Sendable {
    static let maximumGapFrames: UInt32 = 20

    let stream: String
    private let lock = NSLock()
    private let chunks: AsyncStream<CapturedAudioChunk>
    private var continuation: AsyncStream<CapturedAudioChunk>.Continuation?
    private var nextFrame: UInt32?
    private var sequence: Int64 = 0
    private var finished = false

    init(stream: String) {
        self.stream = stream
        // The first upload arrives before recognition has asked for the
        // stream, so it exists from the start and buffers about a minute
        // of audio instead of dropping the opening words.
        let (chunks, continuation) = AsyncStream<CapturedAudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(600))
        self.chunks = chunks
        self.continuation = continuation
    }

    /// The single stream for this phone capture; it already holds any audio
    /// appended before this call.
    func makeAudioStream() -> AsyncStream<CapturedAudioChunk> { chunks }

    func start() async throws {}

    func stop() async { finish() }

    func finish() {
        let continuation = lock.withLock { () -> AsyncStream<CapturedAudioChunk>.Continuation? in
            finished = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    /// Returns the chunks emitted for this batch (for tests); they are also
    /// yielded to the recognizer stream.
    @discardableResult
    func append(_ batch: PhoneAudioBatch) -> [CapturedAudioChunk] {
        guard batch.stream == stream else { return [] }
        let chunks = lock.withLock { () -> [CapturedAudioChunk] in
            guard !finished else { return [] }
            var produced: [CapturedAudioChunk] = []
            let size = PhoneAudioBatch.frameSamples
            let expected = nextFrame ?? batch.firstFrame
            var offset = 0
            if batch.firstFrame > expected {
                // Missing frames become silence, capped for a long outage.
                let missing = min(batch.firstFrame - expected, Self.maximumGapFrames)
                for _ in 0..<missing { produced.append(chunk([Float](repeating: 0, count: size))) }
            } else if batch.firstFrame < expected {
                // Audio already delivered (a retried upload) is not repeated.
                offset = Int(expected - batch.firstFrame) * size
            }
            if offset < batch.samples.count {
                let samples = batch.samples[offset...].map { Float($0) / 32_768 }
                for start in stride(from: 0, to: samples.count, by: size) {
                    produced.append(chunk(Array(samples[start..<min(start + size, samples.count)])))
                }
            }
            let frames = UInt32((batch.samples.count + size - 1) / size)
            nextFrame = max(expected, batch.firstFrame &+ frames)
            for item in produced { continuation?.yield(item) }
            return produced
        }
        if batch.isEnd { finish() }
        return chunks
    }

    private func chunk(_ samples: [Float]) -> CapturedAudioChunk {
        defer { sequence += 1 }
        return CapturedAudioChunk(samples: samples, sequence: sequence, capturedAt: Date(), sourceTimestamp: nil)
    }
}
