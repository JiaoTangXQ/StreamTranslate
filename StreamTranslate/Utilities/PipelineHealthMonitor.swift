import Foundation

/// Leaves evidence for intermittent caption gaps without logging transcripts.
/// It distinguishes "no audio was delivered" (capture) from "audible audio kept
/// arriving but no recognition result came out" (recognizer/pipeline), and
/// records how long each gap lasted once captions resume.
final class PipelineHealthMonitor: @unchecked Sendable {
    struct Report: Equatable, Sendable {
        let message: String
    }

    static let audibleLevel: Float = 0.01
    static let recognitionGap: TimeInterval = 20
    static let audioGap: TimeInterval = 10

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var lastAudioAt: TimeInterval
    private var lastRecognitionAt: TimeInterval
    private var audibleSinceRecognition: Double = 0
    private var reportedRecognitionGap = false
    private var reportedAudioGap = false

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        let now = clock()
        lastAudioAt = now
        lastRecognitionAt = now
    }

    func audio(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let energy = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count)
        let audible = energy.squareRoot() >= Self.audibleLevel
        lock.withLock {
            lastAudioAt = clock()
            if audible { audibleSinceRecognition += Double(samples.count) / 16_000 }
        }
    }

    /// Returns a recovery line when this result ends a reported gap.
    @discardableResult
    func recognized() -> Report? {
        lock.withLock {
            let now = clock()
            defer {
                lastRecognitionAt = now
                audibleSinceRecognition = 0
                reportedRecognitionGap = false
            }
            guard reportedRecognitionGap else { return nil }
            return Report(message: String(format: "Captions resumed after %.0fs without recognition", now - lastRecognitionAt))
        }
    }

    func check() -> Report? {
        lock.withLock {
            let now = clock()
            if now - lastAudioAt >= Self.audioGap {
                guard !reportedAudioGap else { return nil }
                reportedAudioGap = true
                return Report(message: String(format: "No audio delivered for %.0fs while capturing", now - lastAudioAt))
            }
            if reportedAudioGap {
                reportedAudioGap = false
                return Report(message: "Audio delivery resumed")
            }
            guard !reportedRecognitionGap, now - lastRecognitionAt >= Self.recognitionGap,
                  audibleSinceRecognition >= Self.recognitionGap * 0.6 else { return nil }
            reportedRecognitionGap = true
            return Report(message: String(format: "No recognition result for %.0fs while %.0fs of audible audio arrived",
                now - lastRecognitionAt, audibleSinceRecognition))
        }
    }
}
