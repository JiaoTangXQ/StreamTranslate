import Foundation

struct SpeechSegment: Sendable {
    let samples: [Float]
    let startSample: Int64
    let endSample: Int64
}

enum SpeechSegmentEvent: Sendable {
    case partial(SpeechSegment)
    case final(SpeechSegment)
}

/// Splits a continuous 16 kHz mono stream into utterances. It waits for a
/// short pause to finalize a sentence and emits periodic snapshots so the UI
/// can still show text while somebody speaks for a long time.
struct SpeechSegmenter {
    private let sampleRate: Int
    private let minimumVoiceThreshold: Float
    private let quietVoiceThreshold: Float
    private let noiseMultiplier: Float
    private let noiseMargin: Float
    private let noiseCalibrationSamples: Int
    private let minimumSpeechSamples: Int
    private let endingSilenceSamples: Int
    private let retainedSilenceSamples: Int
    private let preRollSamples: Int
    private let firstPreviewIntervalSamples: Int
    private let subsequentPreviewIntervalSamples: Int
    private let maximumUtteranceSamples: Int

    private var preRoll: [Float] = []
    private var pendingVoice: [Float] = []
    private var utterance: [Float] = []
    private var noiseFloor: Float
    private var voicedSamples = 0
    private var consecutiveSilenceSamples = 0
    private var samplesAtLastPreview = 0
    private var totalSamples: Int64 = 0
    private var preRollStartSample: Int64 = 0
    private var pendingVoiceStartSample: Int64 = 0
    private var utteranceStartSample: Int64 = 0

    init(
        sampleRate: Int = 16_000,
        voiceThreshold: Float = 0.02,
        quietVoiceThreshold: Float = 0.01,
        noiseMultiplier: Float = 2.0,
        noiseMargin: Float = 0.006,
        noiseCalibrationDuration: TimeInterval = 0.5,
        minimumSpeechDuration: TimeInterval = 0.25,
        endingSilenceDuration: TimeInterval = 0.8,
        retainedSilenceDuration: TimeInterval = 0.2,
        preRollDuration: TimeInterval = 0.25,
        previewInterval: TimeInterval = 0.75,
        subsequentPreviewInterval: TimeInterval = 0.75,
        maximumUtteranceDuration: TimeInterval = 15.0
    ) {
        self.sampleRate = sampleRate
        minimumVoiceThreshold = voiceThreshold
        self.quietVoiceThreshold = quietVoiceThreshold
        self.noiseMultiplier = noiseMultiplier
        self.noiseMargin = noiseMargin
        noiseFloor = min(voiceThreshold, 0.006)
        noiseCalibrationSamples = Int(
            noiseCalibrationDuration * Double(sampleRate)
        )
        minimumSpeechSamples = Int(minimumSpeechDuration * Double(sampleRate))
        endingSilenceSamples = Int(endingSilenceDuration * Double(sampleRate))
        retainedSilenceSamples = Int(retainedSilenceDuration * Double(sampleRate))
        preRollSamples = Int(preRollDuration * Double(sampleRate))
        firstPreviewIntervalSamples = Int(previewInterval * Double(sampleRate))
        subsequentPreviewIntervalSamples = Int(
            subsequentPreviewInterval * Double(sampleRate)
        )
        maximumUtteranceSamples = Int(maximumUtteranceDuration * Double(sampleRate))
    }

    init(
        sensitivity: SpeechDetectionSensitivity,
        sampleRate: Int = 16_000,
        noiseCalibrationDuration: TimeInterval = 0.5,
        minimumSpeechDuration: TimeInterval = 0.25,
        endingSilenceDuration: TimeInterval = 0.8,
        retainedSilenceDuration: TimeInterval = 0.2,
        preRollDuration: TimeInterval = 0.25,
        previewInterval: TimeInterval = 0.75,
        subsequentPreviewInterval: TimeInterval = 0.75,
        maximumUtteranceDuration: TimeInterval = 15.0
    ) {
        let thresholds: (
            voice: Float,
            quietVoice: Float,
            noiseMultiplier: Float,
            noiseMargin: Float
        ) = switch sensitivity {
        case .automatic:
            (0.02, 0.01, 2.0, 0.006)
        case .farField:
            (0.012, 0.006, 1.5, 0.003)
        case .nearby:
            (0.025, 0.015, 2.3, 0.008)
        }

        self.init(
            sampleRate: sampleRate,
            voiceThreshold: thresholds.voice,
            quietVoiceThreshold: thresholds.quietVoice,
            noiseMultiplier: thresholds.noiseMultiplier,
            noiseMargin: thresholds.noiseMargin,
            noiseCalibrationDuration: noiseCalibrationDuration,
            minimumSpeechDuration: minimumSpeechDuration,
            endingSilenceDuration: endingSilenceDuration,
            retainedSilenceDuration: retainedSilenceDuration,
            preRollDuration: preRollDuration,
            previewInterval: previewInterval,
            subsequentPreviewInterval: subsequentPreviewInterval,
            maximumUtteranceDuration: maximumUtteranceDuration
        )
    }

    mutating func append(_ samples: [Float]) -> [SpeechSegmentEvent] {
        guard !samples.isEmpty else { return [] }
        let chunkStartSample = totalSamples
        totalSamples += Int64(samples.count)
        let energy = Self.rootMeanSquare(samples)
        let containsVoice = energy > currentVoiceThreshold

        if utterance.isEmpty {
            if containsVoice {
                if pendingVoice.isEmpty {
                    pendingVoiceStartSample = chunkStartSample
                }
                pendingVoice.append(contentsOf: samples)
                guard pendingVoice.count >= minimumSpeechSamples else { return [] }

                utterance = preRoll + pendingVoice
                utteranceStartSample = preRoll.isEmpty
                    ? pendingVoiceStartSample
                    : preRollStartSample
                preRoll.removeAll(keepingCapacity: true)
                voicedSamples = pendingVoice.count
                pendingVoice.removeAll(keepingCapacity: true)
                consecutiveSilenceSamples = 0
                samplesAtLastPreview = 0
            } else {
                updateNoiseFloor(with: energy)
                if !pendingVoice.isEmpty {
                    appendToPreRoll(
                        pendingVoice,
                        startSample: pendingVoiceStartSample
                    )
                    pendingVoice.removeAll(keepingCapacity: true)
                }
                appendToPreRoll(samples, startSample: chunkStartSample)
                return []
            }
        } else {
            utterance.append(contentsOf: samples)
            if containsVoice {
                voicedSamples += samples.count
                consecutiveSilenceSamples = 0
            } else {
                consecutiveSilenceSamples += samples.count
            }
        }

        if consecutiveSilenceSamples >= endingSilenceSamples {
            return finalizeUtterance()
        }

        if utterance.count >= maximumUtteranceSamples {
            return finalizeUtterance()
        }

        let previewInterval = samplesAtLastPreview == 0
            ? firstPreviewIntervalSamples
            : subsequentPreviewIntervalSamples
        if utterance.count - samplesAtLastPreview >= previewInterval,
           voicedSamples >= minimumSpeechSamples {
            samplesAtLastPreview = utterance.count
            return [.partial(currentSegment())]
        }

        return []
    }

    mutating func finish() -> SpeechSegmentEvent? {
        let event = finalizeUtterance().first
        pendingVoice.removeAll(keepingCapacity: true)
        return event
    }

    private mutating func finalizeUtterance() -> [SpeechSegmentEvent] {
        guard !utterance.isEmpty else { return [] }

        let removableSilence = max(0, consecutiveSilenceSamples - retainedSilenceSamples)
        if removableSilence > 0, removableSilence < utterance.count {
            utterance.removeLast(removableSilence)
        }

        let result = currentSegment()
        let hasEnoughSpeech = voicedSamples >= minimumSpeechSamples
        reset()
        return hasEnoughSpeech ? [.final(result)] : []
    }

    private mutating func appendToPreRoll(
        _ samples: [Float],
        startSample: Int64
    ) {
        if preRoll.isEmpty {
            preRollStartSample = startSample
        }
        preRoll.append(contentsOf: samples)
        if preRoll.count > preRollSamples {
            let removedCount = preRoll.count - preRollSamples
            preRoll.removeFirst(removedCount)
            preRollStartSample += Int64(removedCount)
        }
    }

    private func currentSegment() -> SpeechSegment {
        SpeechSegment(
            samples: utterance,
            startSample: utteranceStartSample,
            endSample: utteranceStartSample + Int64(utterance.count)
        )
    }

    private mutating func reset() {
        utterance.removeAll(keepingCapacity: true)
        pendingVoice.removeAll(keepingCapacity: true)
        voicedSamples = 0
        consecutiveSilenceSamples = 0
        samplesAtLastPreview = 0
    }

    private var currentVoiceThreshold: Float {
        let calibratedMinimum = totalSamples >= Int64(noiseCalibrationSamples)
            ? quietVoiceThreshold
            : minimumVoiceThreshold
        return max(
            calibratedMinimum,
            noiseFloor * noiseMultiplier,
            noiseFloor + noiseMargin
        )
    }

    private mutating func updateNoiseFloor(with energy: Float) {
        // Track stationary room noise slowly. Speech-like bursts are excluded
        // by the gate above, so a nearby speaker cannot raise the threshold.
        noiseFloor = (noiseFloor * 0.9) + (energy * 0.1)
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Float {
        let sum = samples.reduce(Float.zero) { partial, sample in
            partial + sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }
}
