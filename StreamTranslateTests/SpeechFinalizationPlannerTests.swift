import Testing
@testable import StreamTranslate

@Test func forcedFinalizationWaitsForAConditionalConsequence() {
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0.1, count: 240_000))
    planner.recognized(through: 224_000, isFinal: false, text: "我们还没有批准发布，只有两项检查都通过")
    #expect(planner.nextBoundary() == nil)
    planner.recognized(through: 226_000, isFinal: false, text: "我们还没有批准发布，只有两项检查都通过才能")
    #expect(planner.nextBoundary() == nil)
    planner.recognized(through: 230_000, isFinal: false, text: "我们还没有批准发布，只有两项检查都通过才能重启")
    #expect(planner.nextBoundary() == nil)
    planner.observe(.init(repeating: 0, count: 8_000))
    #expect(planner.nextBoundary() == 242_560)
    #expect(!TranslationDraftPlanner.hasClosedChineseConditions("只要有一项失败"))
    #expect(TranslationDraftPlanner.hasClosedChineseConditions("只要有一项失败就继续运行旧版本"))
    #expect(!TranslationDraftPlanner.hasClosedChineseConditions("只有第一项通过才继续。只有第二项也通过"))
}

@Test func realAudioPauseCanFinalizeANumberWhileSpeculativeDraftHoldsItBack() {
    let text = "成功率从95%提高到98"
    #expect(TranslationDraftPlanner.hasUnsafeEnding(text, language: .chinese))
    #expect(TranslationDraftPlanner.hasClosedChineseConditions(text))
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0.1, count: 160_000))
    planner.recognized(through: 160_000, isFinal: false, text: text)
    planner.observe(.init(repeating: 0, count: 8_000))
    #expect(planner.nextBoundary() == 162_560)
}

@Test func leadingSilenceDoesNotSpendTheUtteranceFinalizationBudget() {
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0, count: 960_000))
    planner.observe(.init(repeating: 0.1, count: 128_000))
    planner.recognized(through: 1_088_000, isFinal: false, text: "模型权重没有变大")
    #expect(planner.nextBoundary() == nil)
    planner.observe(.init(repeating: 0, count: 8_000))
    #expect(planner.nextBoundary() == 1_090_560)
}

@Test func longUtteranceCannotBeForcedBetweenNegationAndItsPredicate() {
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0.1, count: 240_000))
    planner.recognized(through: 230_000, isFinal: false, text: "模型权重没有")
    #expect(planner.nextBoundary() == nil)
    planner.recognized(through: 235_000, isFinal: false, text: "模型权重没有变大")
    #expect(planner.nextBoundary() == nil)
    planner.observe(.init(repeating: 0, count: 8_000))
    #expect(planner.nextBoundary() == 242_560)
}

@Test func silenceAfterAFinalDoesNotSpendTheNextUtteranceBudget() {
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0.1, count: 80_000))
    planner.recognized(through: 80_000, isFinal: true)
    planner.observe(.init(repeating: 0, count: 960_000))
    planner.observe(.init(repeating: 0.1, count: 128_000))
    planner.recognized(through: 1_168_000, isFinal: false, text: "模型权重没有变大")
    #expect(planner.nextBoundary() == nil)
}

@Test func boundedFinalizationWaitsForPauseAndDoesNotRepeatRequests() {
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0.1, count: 80_000))
    planner.recognized(through: 80_000, isFinal: false)
    #expect(planner.nextBoundary() == nil)
    planner.observe(.init(repeating: 0, count: 8_000))
    #expect(planner.nextBoundary() == 82_560)
    #expect(planner.nextBoundary() == nil)
}

@Test func boundedFinalizationDoesNotCutSilenceOrShortUtterances() {
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0, count: 480_000))
    #expect(planner.nextBoundary() == nil)
    let short = SpeechFinalizationPlanner()
    short.observe(.init(repeating: 0.1, count: 16_000))
    short.observe(.init(repeating: 0, count: 16_000))
    #expect(short.nextBoundary() == nil)
}

@Test func continuousSpeechNeverUsesAggregateResultEndAsAHardCut() {
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0.1, count: 240_000))
    planner.recognized(through: 208_000, isFinal: false)
    #expect(planner.nextBoundary() == nil)
    #expect(planner.nextBoundary() == nil)
}

@Test func audioNoiseAndOneCharacterCannotTriggerPauseFinalization() {
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0.1, count: 16_000))
    planner.observe(.init(repeating: 0, count: 160_000))
    #expect(planner.nextBoundary() == nil)
    planner.recognized(through: 16_000, isFinal: false, text: "我")
    #expect(planner.nextBoundary() == nil)
}

@Test func systemFinalPreventsUnnecessaryForcedFinalization() {
    let planner = SpeechFinalizationPlanner()
    planner.observe(.init(repeating: 0.1, count: 240_000))
    planner.recognized(through: 230_000, isFinal: true)
    planner.observe(.init(repeating: 0, count: 8_000))
    #expect(planner.nextBoundary() == nil)
}
