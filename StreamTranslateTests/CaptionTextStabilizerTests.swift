import Testing
@testable import StreamTranslate

@Test func firstSnapshotRemainsDraft() {
    var stabilizer = CaptionTextStabilizer()
    let value = stabilizer.update(
        text: "You can see my screen",
        segmentStartSample: 10,
        language: .english
    )

    #expect(value.stable.isEmpty)
    #expect(value.draft == "You can see my screen")
}

@Test func agreementCommitsOnlyThePrefixBehindTheLiveEdge() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(
        text: "You can see my screen",
        segmentStartSample: 10,
        language: .english
    )
    let value = stabilizer.update(
        text: "You can see my screen now",
        segmentStartSample: 10,
        language: .english
    )

    #expect(value.stable == "You can see")
    #expect(value.fullText == "You can see my screen now")
}

@Test func committedTextNeverRewritesWhenWhisperChangesItsMind() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(
        text: "I want to talk about architecture today",
        segmentStartSample: 10,
        language: .english
    )
    let agreed = stabilizer.update(
        text: "I want to talk about architecture today please",
        segmentStartSample: 10,
        language: .english
    )
    let rewritten = stabilizer.update(
        text: "We need to discuss a different design",
        segmentStartSample: 10,
        language: .english
    )

    #expect(agreed.stable == "I want to talk about")
    #expect(rewritten.stable == agreed.stable)
    #expect(rewritten.fullText.hasPrefix(agreed.stable))
    #expect(rewritten.fullText == "I want to talk about We need to discuss a different design")
}

@Test func newSegmentStartsWithAFreshDraft() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(
        text: "First sentence has enough words",
        segmentStartSample: 10,
        language: .english
    )
    _ = stabilizer.update(
        text: "First sentence has enough words now",
        segmentStartSample: 10,
        language: .english
    )
    let next = stabilizer.update(
        text: "Second sentence",
        segmentStartSample: 20,
        language: .english
    )

    #expect(next.stable.isEmpty)
    #expect(next.draft == "Second sentence")
}

@Test func finalUsesTheExactFinalRecognitionForTranscriptAccuracy() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(
        text: "I want to discuss the deployment process",
        segmentStartSample: 10,
        language: .english
    )
    _ = stabilizer.update(
        text: "I want to discuss the deployment process today",
        segmentStartSample: 10,
        language: .english
    )
    let final = stabilizer.finalize(
        text: "We should discuss the deployment process today.",
        segmentStartSample: 10
    )

    #expect(final.draft.isEmpty)
    #expect(final.stable == "We should discuss the deployment process today.")
}

@Test func chineseAgreementKeepsFourCharactersEditable() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(
        text: "我们正在讨论新的系统架构",
        segmentStartSample: 10,
        language: .chinese
    )
    let value = stabilizer.update(
        text: "我们正在讨论新的系统架构设计",
        segmentStartSample: 10,
        language: .chinese
    )

    #expect(value.stable == "我们正在讨论新的")
    #expect(value.fullText == "我们正在讨论新的系统架构设计")
}

@Test func translationPolicyThrottlesTinyStableGrowth() {
    #expect(PartialTranslationPolicy.shouldRequest(
        previousText: "",
        stableText: "We can",
        language: .english
    ))
    #expect(!PartialTranslationPolicy.shouldRequest(
        previousText: "We can",
        stableText: "We can now safely ship this",
        language: .english
    ))
    #expect(PartialTranslationPolicy.shouldRequest(
        previousText: "We can",
        stableText: "We can now safely ship this release",
        language: .english
    ))
}
