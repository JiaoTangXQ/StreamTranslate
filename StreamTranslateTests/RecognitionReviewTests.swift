import Foundation
import Testing
@testable import StreamTranslate

@Test func sourceReviewCannotInsertCommaInsideAnExistingProblemPredicate() {
    let raw = "我们已经排除了内存泄漏问题出在缓存淘汰策略"
    let review = "我们已经排除了内存泄漏问题，出在缓存淘汰策略。"
    #expect(RecognitionReviewPolicy.consensus(primary: review, contextual: review, original: raw, language: .chinese)
        == "我们已经排除了内存泄漏，问题出在缓存淘汰策略。")
    #expect(RecognitionReviewPolicy.consensus(primary: review, contextual: review, original: review, language: .chinese)
        == review)
    let mixed = "第一个问题出在缓存。另外的问题，出在网络。"
    #expect(RecognitionReviewPolicy.consensus(primary: mixed, contextual: mixed, original: mixed, language: .chinese)
        == mixed)
    #expect(RecognitionReviewPolicy.consensus(primary: "问题，出在缓存淘汰策略。", contextual: "问题，出在缓存淘汰策略。",
        original: "问题出在缓存淘汰策略", language: .chinese) == "问题出在缓存淘汰策略。")
}

@Test func reviewAudioRingPreservesExactAbsoluteRangesAcrossWrap() {
    let buffer = ReviewAudioBuffer(capacity: 5)
    buffer.append([0, 1, 2])
    #expect(buffer.slice(start: 0, end: 3) == [0, 1, 2])
    buffer.append([3, 4, 5, 6])
    #expect(buffer.slice(start: 2, end: 7) == [2, 3, 4, 5, 6])
    #expect(buffer.slice(start: 0, end: 4) == nil)
    #expect(buffer.slice(start: 4, end: 8) == nil)
    #expect(buffer.slice(start: 4, end: 4) == nil)
    #expect(buffer.slice(start: -1, end: 2) == nil)
}

@Test func reviewAllowsLocalTechnicalCorrectionsButRejectsUnrelatedHallucinations() {
    #expect(RecognitionReviewPolicy.accepts("The model weights stay the same size, but the key-value cache keeps growing.",
        replacing: "The model waves stay the same size but the key value cash keeps growing", language: .english))
    #expect(RecognitionReviewPolicy.accepts("键值缓存还在增长。", replacing: "见只缓存还在增长", language: .chinese))
    #expect(!RecognitionReviewPolicy.accepts("Thank you for watching. Please subscribe to my channel.",
        replacing: "We should start now", language: .english))
    #expect(!RecognitionReviewPolicy.accepts("...", replacing: "Start the meeting", language: .english))
    #expect(!RecognitionReviewPolicy.accepts("这是完全不相干的幻觉", replacing: "缓存仍在增长", language: .chinese))
}

@Test func reviewAlignmentStripsNeighboringSpeechWithoutDiscardingWordCorrections() {
    #expect(RecognitionReviewPolicy.candidate("We ruled out a memory leak. It was.",
        for: "We ruled out a memory leak.", language: .english) == "We ruled out a memory leak.")
    #expect(RecognitionReviewPolicy.candidate("We ruled out a memory leak. It was a cache eviction problem. The model weights",
        for: "It was a cash eviction problem.", language: .english) == "It was a cache eviction problem.")
    #expect(RecognitionReviewPolicy.candidate("上一句结束了。模型权重没有变大，但键值缓存还在增长。下一句开始。",
        for: "模型权重没有变大但见只缓存还在增长", language: .chinese) == "模型权重没有变大，但键值缓存还在增长。")
    #expect(RecognitionReviewPolicy.candidate("Completely unrelated hallucination", for: "Start the meeting now", language: .english) == nil)
}

@Test func multiViewReviewDoesNotTurnCorrectCacheIntoCash() {
    let original = "The model weights stay the same size, but the key value cache keeps growing."
    let contextual = "The model weights stay the same size, but the key value cash keeps growing."
    #expect(RecognitionReviewPolicy.consensus(primary: original, contextual: contextual,
        original: original, language: .english) == nil)
}

@Test func multiViewReviewRetainsAgreedWordRepairWithoutImportingDisputedWords() {
    let original = "The model waves stay the same size, but the key value cache keeps growing."
    let primary = "Model weights stay the same size, but the key value cache keeps growing."
    let contextual = "The model weights stay the same size, but the key value cash keeps growing."
    #expect(RecognitionReviewPolicy.consensus(primary: primary, contextual: contextual,
        original: original, language: .english)
        == "The model weights stay the same size, but the key value cache keeps growing.")
}

@Test func multiViewReviewAcceptsSharedCorrectionAndPunctuation() {
    #expect(RecognitionReviewPolicy.consensus(primary: "模型权重没有变大，但键值缓存还在增长。",
        contextual: "前一句结束。模型权重没有变大，但键值缓存还在增长。",
        original: "模型权重没有变大但见只缓存还在增长", language: .chinese)
        == "模型权重没有变大，但键值缓存还在增长。")
}

@Test func precedingAppleHypothesisCanCorroborateOneQwenViewOnAnOrdinaryWord() {
    #expect(RecognitionReviewPolicy.consensus(primary: "It was a cash eviction problem.",
        contextual: "It was a cache eviction problem.", original: "It was a cash eviction problem.",
        language: .english, priorHypothesis: "It was a cache") == "It was a cache eviction problem.")
}

@Test func priorHypothesisCannotOverrideNewerNumbersOrNegation() {
    #expect(RecognitionReviewPolicy.consensus(primary: "Revenue fell by fifty percent.",
        contextual: "Revenue fell by fifteen percent.", original: "Revenue fell by fifty percent.",
        language: .english, priorHypothesis: "Revenue fell by fifteen") == nil)
    #expect(!RecognitionReviewPolicy.hasPriorDisagreement("We are discussing an unrelated topic", with: "It was a cash eviction problem", language: .english))
}

@Test func reviewCannotClipOrReplaceQuantitiesAtTheEndOfAnUtterance() {
    let source = "The patch reduced latency by a third, not to a third, the success rate rose from 95% to 98%."
    let clipped = "The patch reduced latency by a third—not to a third. The success rate rose from"
    #expect(!RecognitionReviewPolicy.accepts(clipped, replacing: source, language: .english))
    #expect(RecognitionReviewPolicy.consensus(primary: clipped, contextual: clipped, original: source, language: .english) == nil)
    #expect(!RecognitionReviewPolicy.accepts("成功率从", replacing: "成功率从95%提高到98%", language: .chinese))
    #expect(!RecognitionReviewPolicy.accepts("The success rate rose from 50% to 98%.", replacing: "The success rate rose from 95% to 98%.", language: .english))
}

@Test func reviewAlignsEquivalentSpokenPercentagesWithoutTrimmingTheirValues() {
    let source = "The success rate rose from 95% to 98%."
    let spoken = "The success rate rose from ninety-five percent to ninety-eight percent."
    #expect(RecognitionReviewPolicy.candidate(spoken, for: source, language: .english) == source)
    #expect(RecognitionReviewPolicy.consensus(primary: spoken, contextual: spoken, original: source, language: .english) == source)
    #expect(RecognitionReviewPolicy.candidate("成功率从百分之九十五提高到百分之九十八。", for: "成功率从95%提高到98%。", language: .chinese) == "成功率从95%提高到98%。")
    #expect(!RecognitionReviewPolicy.accepts("The success rate rose from ninety-eight percent to ninety-five percent.", replacing: source, language: .english))
}

@Test func reviewDoesNotInventQuotationScopeAcrossFollowingSentences() {
    let original = "She said we had not verified it yet. I used to think the update was safe. I no longer do."
    let reviewed = "She said, \"We had not verified it yet. I used to think the update was safe. I no longer do.\""
    let result = RecognitionReviewPolicy.consensus(primary: reviewed, contextual: reviewed, original: original, language: .english)
    #expect(result != nil)
    #expect(result?.contains("\"") == false)
    #expect(result?.contains("yet. I used") == true)
}

@Test func reviewCannotRemoveNegationOrAWholeTrailingClause() {
    #expect(!RecognitionReviewPolicy.accepts("We approved the new release.", replacing: "We have not approved the new release.", language: .english))
    #expect(!RecognitionReviewPolicy.accepts("我们批准了这次发布", replacing: "我们没有批准这次发布", language: .chinese))
    #expect(!RecognitionReviewPolicy.accepts("We do approve the release.", replacing: "We don't approve the release.", language: .english))
    #expect(!RecognitionReviewPolicy.accepts("We can approve this release.", replacing: "We cannot approve this release.", language: .english))
    #expect(!RecognitionReviewPolicy.accepts("The update is ready.", replacing: "The update is ready but the backup still needs verification.", language: .english))
}

@Test @MainActor func sourceReviewCannotEraseFinalPercentagesFromHistory() async {
    let vm = CaptionViewModel(), audio = ReviewAudioBuffer()
    audio.append(.init(repeating: 0.1, count: 16000))
    let source = "The success rate rose from 95% to 98%."
    vm.configureRecognitionReview(ReviewStub("The success rate rose from"), audio: audio)
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(reviewFinal(source), logger: nil, partialTranslations: queue)
    await vm.waitForFinalTranslations()
    #expect(vm.captionHistory.count == 1)
    #expect(vm.captionHistory[0].englishText == source)
    vm.clearHistory()
    await queue.finish()
}

@Test func reviewWAVIsBoundedMonoPCMAndSanitizesInvalidSamples() {
    let data = LocalQwenService.wavData([0, 1, -1, .nan, .infinity])
    #expect(data.count == 54)
    #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    #expect(Array(data[44...]) == [0, 0, 255, 127, 1, 128, 0, 0, 0, 0])
}

@Test @MainActor func reviewPreferenceDefaultsOnButPreservesExplicitOptOut() {
    let name = "StreamTranslate-review-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(CaptionSettings(defaults: defaults).recognitionReviewEnabled)
    defaults.set(false, forKey: "recognitionReviewEnabled")
    #expect(!CaptionSettings(defaults: defaults).recognitionReviewEnabled)
}

private final class ReviewStub: RecognitionReviewProviding, @unchecked Sendable {
    let text: String
    let delay: Duration
    var isReady: Bool { true }
    init(_ text: String, delay: Duration = .milliseconds(50)) { self.text = text; self.delay = delay }
    func transcribe(_ samples: [Float]) async throws -> String {
        // Deliberately ignore cancellation, like a native call already in flight.
        try? await Task.sleep(for: delay)
        return text
    }
    func cancel() {}
}

private func reviewFinal(_ text: String, start: Int64 = 0) -> StreamingTranscriptionUpdate {
    .init(output: .init(text: text, language: .english, reportedLanguageCode: "en", words: []),
          startSample: start, endSample: start + 16000, isFinal: true, processingLatency: 0)
}

@Test @MainActor func recognitionReviewRevisesSameHistoryEntryWithoutDuplicatingIt() async {
    let vm = CaptionViewModel(), audio = ReviewAudioBuffer()
    audio.append(.init(repeating: 0.1, count: 16000))
    vm.configureRecognitionReview(ReviewStub("The key-value cache keeps growing."), audio: audio)
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(reviewFinal("The key value cash keeps growing"), logger: nil, partialTranslations: queue)
    let id = vm.captionHistory.first?.id
    await vm.waitForFinalTranslations()
    #expect(vm.captionHistory.count == 1)
    #expect(vm.captionHistory.first?.id == id)
    #expect(vm.captionHistory.first?.englishText == "The key-value cache keeps growing.")
    vm.clearHistory()
    await queue.finish()
}

@Test @MainActor func clearHistoryRejectsLateNativeReviewEvenIfItIgnoresCancellation() async {
    let vm = CaptionViewModel(), audio = ReviewAudioBuffer()
    audio.append(.init(repeating: 0.1, count: 16000))
    vm.configureRecognitionReview(ReviewStub("The model weights stay the same size."), audio: audio)
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(reviewFinal("The model waves stay the same size"), logger: nil, partialTranslations: queue)
    try? await Task.sleep(for: .milliseconds(10))
    vm.clearHistory()
    vm.addCaption(english: "New unrelated caption", chinese: "新字幕")
    try? await Task.sleep(for: .milliseconds(100))
    #expect(vm.captionHistory.count == 1)
    #expect(vm.captionHistory.first?.englishText == "New unrelated caption")
    vm.clearHistory()
    await queue.finish()
}

@Test @MainActor func unrelatedReviewCannotReplaceFastRecognition() async {
    let vm = CaptionViewModel(), audio = ReviewAudioBuffer()
    audio.append(.init(repeating: 0.1, count: 16000))
    vm.configureRecognitionReview(ReviewStub("Thank you for watching. Subscribe to my channel."), audio: audio)
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(reviewFinal("The model weights stay the same size"), logger: nil, partialTranslations: queue)
    await vm.waitForFinalTranslations()
    #expect(vm.captionHistory.first?.englishText == "The model weights stay the same size")
    vm.clearHistory()
    await queue.finish()
}
