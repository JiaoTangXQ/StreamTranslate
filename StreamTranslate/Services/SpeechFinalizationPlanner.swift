import Foundation

/// Requests a commit only at a real audio pause with substantive recognized
/// text. Aggregate result ranges are not used as mid-speech cutting points.
/// Samples still flow continuously; the recognizer is not restarted.
final class SpeechFinalizationPlanner: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    private var lastVoice: Int64 = 0
    private var firstVoice: Int64?
    private var finalized: Int64 = 0
    private var recognizedEnd: Int64 = 0
    private var requested: Int64 = 0
    private var recognizedCanCommit = true
    private var recognizedUnits = 0

    func observe(_ samples: [Float]) {
        lock.withLock {
            // Fixed 20 ms energy windows keep the policy independent of the
            // audio callback's buffer size (replay and actual capture differ).
            for offset in stride(from: 0, to: samples.count, by: 320) {
                let end = min(offset + 320, samples.count)
                let energy = samples[offset..<end].reduce(Float(0)) { $0 + $1 * $1 }
                total += Int64(end - offset)
                if energy / Float(end - offset) > 0.0001 {
                    if firstVoice == nil || lastVoice <= max(finalized, requested) {
                        firstVoice = total - Int64(end - offset)
                    }
                    lastVoice = total
                }
            }
        }
    }

    func recognized(through end: Int64, isFinal: Bool, text: String = "") {
        // A number at the end of a volatile result is unsafe for speculative
        // draft translation, but a REAL audio pause can finalize that number.
        // Waiting for its delayed '%' token misses the pause and merges the
        // next speaker/sentence. Keep only unresolved conditional dependencies.
        let canCommit = text.isEmpty || TranslationDraftPlanner.hasClosedChineseConditions(text)
        let units = text.isEmpty ? 4 : CaptionTextStabilizer.semanticUnitCount(in: text)
        lock.withLock {
            if end >= recognizedEnd {
                recognizedCanCommit = canCommit
                recognizedUnits = units
            }
            recognizedEnd = max(recognizedEnd, end)
            if isFinal { finalized = max(finalized, end) }
        }
    }

    func nextBoundary() -> Int64? {
        lock.withLock {
            let base = max(finalized, requested)
            guard let firstVoice else { return nil }
            // Capture may run silently for minutes before a speaker starts.
            // Count this utterance's speech span, never time since recording.
            let speechBase = max(base, firstVoice)
            guard recognizedEnd > speechBase, recognizedUnits >= 4, recognizedCanCommit,
                  total - speechBase >= 64_000, lastVoice > base,
                  total - lastVoice >= 7_200 else { return nil }
            let boundary = min(total, lastVoice + 2_560)
            guard boundary > base else { return nil }
            requested = boundary
            return boundary
        }
    }
}
