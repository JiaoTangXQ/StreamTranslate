import Testing
@testable import StreamTranslate

@Test func languageLocksAfterTwoMatchingPartials() {
    var context = TranscriptionContext()
    let first = segment(start: 100, count: 16_000)
    let second = segment(start: 100, count: 32_000)

    context.recordPartial(
        segment: first,
        output: output("Hello", language: .english, score: -0.3)
    )
    #expect(context.lockedLanguage(for: first) == nil)

    context.recordPartial(
        segment: second,
        output: output("Hello there", language: .english, score: -0.2)
    )
    #expect(context.lockedLanguage(for: second) == .english)
}

@Test func languageDisagreementRestartsAgreement() {
    var context = TranscriptionContext()
    let current = segment(start: 100, count: 16_000)

    context.recordPartial(
        segment: current,
        output: output("Hello", language: .english, score: -0.3)
    )
    context.recordPartial(
        segment: current,
        output: output("你好", language: .chinese, score: -0.3)
    )

    #expect(context.lockedLanguage(for: current) == nil)
}

@Test func promptIncludesRecentSameLanguageContextAndVocabulary() {
    var context = TranscriptionContext()
    context.recordFinal(
        segment: segment(start: 0, count: 16_000),
        output: output("Deploy Argo CD", language: .english, score: -0.2)
    )
    let current = segment(start: 16_000, count: 16_000)

    let prompt = context.prompt(
        for: current,
        language: .english,
        vocabulary: "Kubernetes, YAML"
    )

    #expect(prompt?.contains("Kubernetes, YAML") == true)
    #expect(prompt?.contains("Deploy Argo CD") == true)
}

@Test func shortLanguageDisagreementRequestsContextualRetry() {
    let context = RecognizedSegment(
        segment: segment(start: 0, count: 16_000),
        output: output("Can you hear me?", language: .english, score: -0.3)
    )
    let automatic = output("好看又会有你", language: .chinese, score: -1.1)

    #expect(
        TranscriptionSelectionPolicy.shouldRetryWithContextLanguage(
            automatic: automatic,
            context: context,
            sampleCount: 16_000
        )
    )
}

@Test func higherConfidenceContextualLanguageWins() {
    let automatic = output("好看又会有你", language: .chinese, score: -1.1)
    let contextual = output("Hello, can you hear me?", language: .english, score: -0.2)

    let selected = TranscriptionSelectionPolicy.chooseLanguageResult(
        automatic: automatic,
        contextual: contextual
    )
    #expect(selected?.text == "Hello, can you hear me?")
}

@Test func unsupportedDetectedLanguageRequestsBilingualRetry() {
    let automatic = TranscriptionOutput(
        text: "Vai, não tem nada.",
        language: .english,
        reportedLanguageCode: "pt",
        words: [],
        averageLogProbability: -0.55,
        noSpeechProbability: 0
    )

    #expect(
        TranscriptionSelectionPolicy.shouldRetryUnsupportedLanguage(automatic)
    )
}

@Test func highestConfidenceBilingualCandidateWins() {
    let automatic = TranscriptionOutput(
        text: "Well, I don't know, man.",
        language: .english,
        reportedLanguageCode: "en",
        words: [],
        averageLogProbability: -0.55,
        noSpeechProbability: 0
    )
    let chinese = output("哎，能听到吗？", language: .chinese, score: -0.46)
    let english = output("Well, I don't know, man.", language: .english, score: -0.55)

    let selected = TranscriptionSelectionPolicy.chooseBestScoredResult([
        automatic,
        chinese,
        english
    ])

    #expect(selected?.text == "哎，能听到吗？")
}

@Test func languageAnnotationCannotWinCandidateSelection() {
    let annotation = TranscriptionOutput(
        text: "[speaking Chinese]",
        language: .english,
        reportedLanguageCode: "en",
        words: [],
        averageLogProbability: -0.05,
        noSpeechProbability: 0
    )
    let speech = output("这是一段中文。", language: .chinese, score: -0.5)

    let selected = TranscriptionSelectionPolicy.chooseBestScoredResult([
        annotation,
        speech,
    ])

    #expect(selected?.text == "这是一段中文。")
}

@Test func emptyFinalKeepsLatestPartialText() {
    let partial = RecognizedSegment(
        segment: segment(start: 0, count: 16_000),
        output: output("Hello?", language: .english, score: -0.4)
    )
    let selected = TranscriptionSelectionPolicy.chooseFinalResult(
        candidate: nil,
        previousPartial: partial,
        finalSegment: segment(start: 0, count: 20_000)
    )

    #expect(selected?.text == "Hello?")
}

@Test func lowerConfidenceTrailingSilenceRegressionKeepsPartial() {
    let partial = RecognizedSegment(
        segment: segment(start: 0, count: 16_789),
        output: output("Hello, can you hear me?", language: .english, score: -0.25)
    )
    let candidate = output("Hello, Kyle here.", language: .english, score: -0.8)
    let selected = TranscriptionSelectionPolicy.chooseFinalResult(
        candidate: candidate,
        previousPartial: partial,
        finalSegment: segment(start: 0, count: 21_621)
    )

    #expect(selected?.text == "Hello, can you hear me?")
}

@Test func oneWordFinalCannotEraseACompleteLongPartial() {
    let partialText = "Partner, for example, ASIS, X-Rout team, China Jiu and the SQ."
    let partial = RecognizedSegment(
        segment: segment(start: 0, count: 112_000),
        output: output(partialText, language: .english, score: -0.35)
    )
    let candidate = output("For", language: .english, score: -0.1)
    let selected = TranscriptionSelectionPolicy.chooseFinalResult(
        candidate: candidate,
        previousPartial: partial,
        finalSegment: segment(start: 0, count: 126_400)
    )

    #expect(selected?.text == partialText)
}

@Test func finalLanguageChangeNeverKeepsWrongLanguagePartial() {
    let partial = RecognizedSegment(
        segment: segment(start: 0, count: 16_000),
        output: output("Hello?", language: .english, score: -0.1)
    )
    let candidate = output("你好。", language: .chinese, score: -0.5)

    let selected = TranscriptionSelectionPolicy.chooseFinalResult(
        candidate: candidate,
        previousPartial: partial,
        finalSegment: segment(start: 0, count: 20_000)
    )

    #expect(selected?.language == .chinese)
    #expect(selected?.text == "你好。")
}

@Test func finalExtensionIsNotDiscarded() {
    let partial = RecognizedSegment(
        segment: segment(start: 0, count: 16_000),
        output: output("I will introduce", language: .english, score: -0.3)
    )
    let candidate = output(
        "I will introduce my work.",
        language: .english,
        score: -0.35
    )
    let selected = TranscriptionSelectionPolicy.chooseFinalResult(
        candidate: candidate,
        previousPartial: partial,
        finalSegment: segment(start: 0, count: 21_000)
    )

    #expect(selected?.text == "I will introduce my work.")
}

@Test func finalTrimmedSilenceCanKeepBetterPartial() {
    let partial = RecognizedSegment(
        segment: segment(start: 0, count: 20_000),
        output: output("through every option", language: .english, score: -0.2)
    )
    let candidate = output("server area option", language: .english, score: -0.8)

    let selected = TranscriptionSelectionPolicy.chooseFinalResult(
        candidate: candidate,
        previousPartial: partial,
        finalSegment: segment(start: 0, count: 17_000)
    )

    #expect(selected?.text == "through every option")
}

@Test func rollingAudioPreservesGapsAndCurrentOffset() {
    var context = TranscriptionContext()
    let first = valuedSegment(start: 100, values: [1, 2, 3])
    let second = valuedSegment(start: 106, values: [4, 5])
    context.recordFinal(
        segment: first,
        output: output("first", language: .english, score: -0.2)
    )
    context.recordFinal(
        segment: second,
        output: output("second", language: .english, score: -0.2)
    )

    let current = valuedSegment(start: 110, values: [6, 7])
    let audio = context.contextualAudio(for: current, language: .english)

    #expect(audio?.samples == [1, 2, 3, 0, 0, 0, 4, 5, 0, 0, 6, 7])
    #expect(audio?.currentAudioOffset == 10.0 / 16_000.0)
}

@Test func rollingAudioStopsAtLanguageSwitch() {
    var context = TranscriptionContext()
    context.recordFinal(
        segment: valuedSegment(start: 0, values: [1, 2]),
        output: output("English", language: .english, score: -0.2)
    )
    context.recordFinal(
        segment: valuedSegment(start: 4, values: [3, 4]),
        output: output("中文", language: .chinese, score: -0.2)
    )

    let current = valuedSegment(start: 8, values: [5, 6])
    #expect(context.contextualAudio(for: current, language: .english) == nil)
}

@Test func rollingAudioResultWinsWhenAvailable() {
    let current = output("server area option", language: .english, score: -0.2)
    let contextual = output("through every option", language: .english, score: -0.4)

    let selected = TranscriptionSelectionPolicy.chooseAudioContextResult(
        currentOnly: current,
        contextual: contextual
    )

    #expect(selected?.text == "through every option")
}

@Test func rollingAudioFragmentCannotEraseCompleteCurrentResult() {
    let currentText = "The application is receiving words and translating them into Chinese."
    let current = output(currentText, language: .english, score: -0.35)
    let contextual = output("For", language: .english, score: -0.1)

    let selected = TranscriptionSelectionPolicy.chooseAudioContextResult(
        currentOnly: current,
        contextual: contextual
    )

    #expect(selected?.text == currentText)
}

@Test func rollingAudioIncludesPreviousFifteenSecondSegment() {
    let sampleRate = 16_000
    let segmentLength = sampleRate * 15
    var context = TranscriptionContext()
    context.recordFinal(
        segment: segment(start: 0, count: segmentLength),
        output: output("上一段", language: .chinese, score: -0.2)
    )

    let current = segment(start: Int64(segmentLength), count: segmentLength)
    let audio = context.contextualAudio(for: current, language: .chinese)

    #expect(audio?.samples.count == segmentLength * 2)
    #expect(audio?.currentAudioOffset == 15)
}

private func segment(start: Int64, count: Int) -> SpeechSegment {
    SpeechSegment(
        samples: Array(repeating: 0, count: count),
        startSample: start,
        endSample: start + Int64(count)
    )
}

private func valuedSegment(start: Int64, values: [Float]) -> SpeechSegment {
    SpeechSegment(
        samples: values,
        startSample: start,
        endSample: start + Int64(values.count)
    )
}

private func output(
    _ text: String,
    language: SpokenLanguage,
    score: Float
) -> TranscriptionOutput {
    TranscriptionOutput(
        text: text,
        language: language,
        reportedLanguageCode: language.rawValue,
        words: [],
        averageLogProbability: score,
        noSpeechProbability: 0.1
    )
}
