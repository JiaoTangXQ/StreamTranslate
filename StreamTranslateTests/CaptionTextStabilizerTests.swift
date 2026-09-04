import Testing
@testable import StreamTranslate

@Test func conservativeEnglishTranslationPrefixKeepsTwoEditableWords() {
    var stabilizer = CaptionTextStabilizer()
    let text = "Today we are testing continuous English speech"

    _ = stabilizer.update(
        text: text,
        segmentStartSample: 0,
        language: .english,
        evidenceEndSample: 16_000
    )

    #expect(
        stabilizer.conservativeTranslationPrefix(in: text, language: .english)
            == "Today we are testing continuous"
    )
}

@Test func conservativeTranslationPrefixNeverDropsFrozenText() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(
        text: "We can now safely ship this release",
        segmentStartSample: 0,
        language: .english,
        evidenceEndSample: 16_000
    )
    let presentation = stabilizer.update(
        text: "We can now safely ship this release today",
        segmentStartSample: 0,
        language: .english,
        evidenceEndSample: 32_000
    )

    let prefix = stabilizer.conservativeTranslationPrefix(
        in: "A completely rewritten live hypothesis",
        language: .english
    )

    #expect(!presentation.stable.isEmpty)
    #expect(prefix == presentation.stable)
}

@Test func partialTranslationPolicyReplacesARewrittenEarlyPrefix() {
    #expect(PartialTranslationPolicy.shouldRequest(
        previousText: "Today we test the old",
        stableText: "Today we test a revised",
        language: .english
    ))
}

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

@Test func finalOnlyRevisesTextAfterTheFrozenPrefix() {
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
    #expect(final.stable == "I want to discuss the deployment process today.")
}

@Test func repeatedUpdatesForTheSameAudioDoNotFreezeSubwordBursts() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(
        text: "Today",
        segmentStartSample: 10,
        language: .english,
        evidenceEndSample: 16_000
    )
    let sameAudio = stabilizer.update(
        text: "Today we are testing",
        segmentStartSample: 10,
        language: .english,
        evidenceEndSample: 16_000
    )
    let moreAudio = stabilizer.update(
        text: "Today we are testing the stream",
        segmentStartSample: 10,
        language: .english,
        evidenceEndSample: 32_000
    )

    #expect(sameAudio.stable.isEmpty)
    #expect(moreAudio.stable == "Today we")
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
