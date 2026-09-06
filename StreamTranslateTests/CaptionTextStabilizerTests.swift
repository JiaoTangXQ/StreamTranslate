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

@Test func oneConflictingHypothesisDoesNotDuplicateOrRewriteTheReadingSurface() {
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
    #expect(rewritten.fullText == agreed.fullText)
}

@Test func independentlyConfirmedCorrectionReplacesAnIncorrectFrozenPrefix() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(text: "I want to discuss the deployment process", segmentStartSample: 0, language: .english, evidenceEndSample: 16_000)
    _ = stabilizer.update(text: "I want to discuss the deployment process today", segmentStartSample: 0, language: .english, evidenceEndSample: 32_000)
    let held = stabilizer.update(text: "We should discuss the deployment process today", segmentStartSample: 0, language: .english, evidenceEndSample: 48_000)
    #expect(held.fullText.hasPrefix("I want"))
    let corrected = stabilizer.update(text: "We should discuss the deployment process today please", segmentStartSample: 0, language: .english, evidenceEndSample: 64_000)
    #expect(corrected.fullText == "We should discuss the deployment process today please")
    #expect(corrected.stable.hasPrefix("We should"))
}

@Test func sameAudioSubwordCallbacksCannotConfirmAFrozenCorrection() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(text: "I want to discuss the deployment process", segmentStartSample: 0, language: .english, evidenceEndSample: 16_000)
    let before = stabilizer.update(text: "I want to discuss the deployment process today", segmentStartSample: 0, language: .english, evidenceEndSample: 32_000)
    _ = stabilizer.update(text: "We should discuss the deployment process today", segmentStartSample: 0, language: .english, evidenceEndSample: 48_000)
    let sameAudio = stabilizer.update(text: "We should discuss the deployment process today please", segmentStartSample: 0, language: .english, evidenceEndSample: 48_000)
    #expect(sameAudio == before)
}

@Test func aRejectedRewriteDoesNotStopLaterAppendOnlyProgress() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(text: "We can discuss the deployment process", segmentStartSample: 0, language: .english)
    _ = stabilizer.update(text: "We can discuss the deployment process today", segmentStartSample: 0, language: .english)
    _ = stabilizer.update(text: "A different recognition mistake appears", segmentStartSample: 0, language: .english)
    let recovered = stabilizer.update(text: "We can discuss the deployment process today please", segmentStartSample: 0, language: .english)
    #expect(recovered.fullText == "We can discuss the deployment process today please")
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

@Test func finalSeparatesFrozenPresentationFromCorrectedTranscript() {
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

    #expect(final.presentation.draft.isEmpty)
    #expect(final.presentation.stable == "I want to discuss the deployment process today.")
    #expect(final.recognizedText == "We should discuss the deployment process today.")
}

@Test func partialTranslationDeadlineDoesNotRepeatUnchangedText() {
    #expect(!PartialTranslationPolicy.shouldRequest(
        previousText: "We can", stableText: "We can", language: .english,
        elapsedSinceLastRequest: 10
    ))
    #expect(!PartialTranslationPolicy.shouldRequest(
        previousText: "We can", stableText: "", language: .english,
        elapsedSinceLastRequest: 10
    ))
}

@Test func draftTranslationRequiresMeaningfulContextEvenAfterDeadline() {
    for (text, language) in [("大", SpokenLanguage.chinese), ("大家好", .chinese), ("This", .english)] {
        #expect(!PartialTranslationPolicy.shouldRequest(
            previousText: "", stableText: text, language: language,
            elapsedSinceLastRequest: 10
        ))
    }
    #expect(PartialTranslationPolicy.hasEnoughContext("大家好我们", language: .chinese))
    #expect(PartialTranslationPolicy.hasEnoughContext("We can", language: .english))
}

@Test func partialTranslationDeadlineAllowsSmallEnglishAndChineseGrowth() {
    for (previous, current, language) in [
        ("We can", "We can now", SpokenLanguage.english),
        ("我们现在", "我们现在开始", SpokenLanguage.chinese)
    ] {
        #expect(!PartialTranslationPolicy.shouldRequest(
            previousText: previous, stableText: current, language: language,
            elapsedSinceLastRequest: 0.59
        ))
        #expect(PartialTranslationPolicy.shouldRequest(
            previousText: previous, stableText: current, language: language,
            elapsedSinceLastRequest: 0.6
        ))
    }
}

@Test func finalChineseNumbersAndNegationComeFromRecognizer() {
    var stabilizer = CaptionTextStabilizer()
    _ = stabilizer.update(text: "收入上涨百分之五十会议开始", segmentStartSample: 0, language: .chinese)
    _ = stabilizer.update(text: "收入上涨百分之五十会议开始了", segmentStartSample: 0, language: .chinese)
    let final = stabilizer.finalize(text: " 收入下降百分之十五，不是百分之五十。 ", segmentStartSample: 0)
    #expect(final.recognizedText == "收入下降百分之十五，不是百分之五十。")
    #expect(final.presentation.fullText != final.recognizedText)
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
