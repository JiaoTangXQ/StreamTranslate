import Testing
@testable import StreamTranslate

@Test func silenceDoesNotCreateUtterance() {
    var segmenter = SpeechSegmenter(sampleRate: 100)
    let events = segmenter.append(Array(repeating: 0, count: 200))
    #expect(events.isEmpty)
    #expect(segmenter.finish() == nil)
}

@Test func steadyRoomNoiseDoesNotCreateUtterance() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        minimumSpeechDuration: 0.2,
        previewInterval: 0.5,
        maximumUtteranceDuration: 1
    )

    for _ in 0..<10 {
        #expect(segmenter.append(Array(repeating: 0.02, count: 10)).isEmpty)
    }
    #expect(segmenter.finish() == nil)
}

@Test func speechAboveCalibratedRoomNoiseStillFinalizes() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        minimumSpeechDuration: 0.2,
        endingSilenceDuration: 0.5,
        retainedSilenceDuration: 0.1,
        previewInterval: 10
    )

    for _ in 0..<6 {
        #expect(segmenter.append(Array(repeating: 0.02, count: 10)).isEmpty)
    }
    #expect(segmenter.append(Array(repeating: 0.08, count: 40)).isEmpty)

    let events = segmenter.append(Array(repeating: 0.02, count: 60))
    #expect(events.count == 1)
    if case .final(let segment) = events[0] {
        #expect(segment.samples.count >= 40)
        #expect(segment.samples.count < 110)
    } else {
        Issue.record("Expected speech above the calibrated noise floor to finalize")
    }
}

@Test func speechFinalizesAfterPause() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        minimumSpeechDuration: 0.2,
        endingSilenceDuration: 0.5,
        retainedSilenceDuration: 0.1,
        previewInterval: 10
    )
    #expect(segmenter.append(Array(repeating: 0.1, count: 40)).isEmpty)
    let events = segmenter.append(Array(repeating: 0, count: 60))
    #expect(events.count == 1)
    if case .final(let segment) = events[0] {
        #expect(segment.samples.count >= 40)
        #expect(segment.samples.count < 100)
    } else {
        Issue.record("Expected a final utterance")
    }
}

@Test func longSpeechEmitsPreview() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        minimumSpeechDuration: 0.2,
        previewInterval: 0.5,
        maximumUtteranceDuration: 5
    )
    let events = segmenter.append(Array(repeating: 0.1, count: 60))
    #expect(events.count == 1)
    if case .partial(let segment) = events[0] {
        #expect(segment.samples.count == 60)
    } else {
        Issue.record("Expected a partial utterance")
    }
}

@Test func normalHalfSecondPauseDoesNotSplitDefaultUtterance() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        previewInterval: 10,
        maximumUtteranceDuration: 10
    )

    #expect(segmenter.append(Array(repeating: 0.1, count: 40)).isEmpty)
    #expect(segmenter.append(Array(repeating: 0, count: 50)).isEmpty)
    #expect(segmenter.append(Array(repeating: 0.1, count: 40)).isEmpty)

    let events = segmenter.append(Array(repeating: 0, count: 80))
    #expect(events.count == 1)
    if case .final(let segment) = events[0] {
        #expect(segment.startSample == 0)
        #expect(segment.endSample == Int64(segment.samples.count))
        #expect(segment.samples.count >= 150)
    } else {
        Issue.record("Expected one utterance containing both sides of the pause")
    }
}

@Test func quietSpeechAfterRoomCalibrationIsNotDropped() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        previewInterval: 10,
        maximumUtteranceDuration: 10
    )

    for _ in 0..<20 {
        #expect(segmenter.append(Array(repeating: 0.003, count: 10)).isEmpty)
    }

    let measuredQuietSpeech: [Float] = [
        0.0196, 0.0245, 0.0201, 0.0129, 0.0138,
        0.0213, 0.0281, 0.0178, 0.0123
    ]
    var events: [SpeechSegmentEvent] = []
    for level in measuredQuietSpeech {
        events.append(contentsOf: segmenter.append(
            Array(repeating: level, count: 10)
        ))
    }
    events.append(contentsOf: segmenter.append(Array(repeating: 0, count: 80)))

    #expect(events.contains { event in
        if case .final = event { return true }
        return false
    })
}

@Test func farFieldSensitivityRetainsSpeechBelowAutomaticThreshold() {
    func finalizesSpeech(using sensitivity: SpeechDetectionSensitivity) -> Bool {
        var segmenter = SpeechSegmenter(
            sensitivity: sensitivity,
            sampleRate: 100,
            minimumSpeechDuration: 0.2,
            endingSilenceDuration: 0.5,
            retainedSilenceDuration: 0.1,
            previewInterval: 10,
            maximumUtteranceDuration: 10
        )

        for _ in 0..<10 {
            _ = segmenter.append(Array(repeating: 0.003, count: 10))
        }
        _ = segmenter.append(Array(repeating: 0.008, count: 40))
        let events = segmenter.append(Array(repeating: 0.003, count: 60))
        return events.contains { event in
            if case .final = event { return true }
            return false
        }
    }

    #expect(!finalizesSpeech(using: .automatic))
    #expect(finalizesSpeech(using: .farField))
}

@Test func defaultPreviewAppearsAfterAboutOneSecond() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        minimumSpeechDuration: 0.2,
        maximumUtteranceDuration: 5
    )

    let events = segmenter.append(Array(repeating: 0.1, count: 110))
    #expect(events.count == 1)
    if case .partial = events[0] {
        // Expected.
    } else {
        Issue.record("Expected a low-latency partial preview")
    }
}

@Test func defaultPreviewCadenceKeepsSourceTextNearLiveSpeech() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        minimumSpeechDuration: 0.2,
        maximumUtteranceDuration: 5
    )

    #expect(segmenter.append(Array(repeating: 0.1, count: 110)).count == 1)
    #expect(segmenter.append(Array(repeating: 0.1, count: 80)).count == 1)
}

@Test func laterPreviewsUseALowerFrequencyWithoutDelayingTheFirst() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        minimumSpeechDuration: 0.2,
        previewInterval: 1,
        subsequentPreviewInterval: 1.5,
        maximumUtteranceDuration: 10
    )

    #expect(segmenter.append(Array(repeating: 0.1, count: 110)).count == 1)
    #expect(segmenter.append(Array(repeating: 0.1, count: 100)).isEmpty)
    let secondPreview = segmenter.append(Array(repeating: 0.1, count: 50))
    #expect(secondPreview.count == 1)
}

@Test func maximumDurationForcesFinalUtterance() {
    var segmenter = SpeechSegmenter(
        sampleRate: 100,
        minimumSpeechDuration: 0.2,
        previewInterval: 10,
        maximumUtteranceDuration: 1
    )
    let events = segmenter.append(Array(repeating: 0.1, count: 100))
    #expect(events.count == 1)
    if case .final = events[0] {
        // Expected.
    } else {
        Issue.record("Expected a final utterance")
    }
}
