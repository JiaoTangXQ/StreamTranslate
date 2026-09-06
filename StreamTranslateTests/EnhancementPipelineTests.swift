import Foundation
import Testing
@testable import StreamTranslate

@Test func standalonePunctuationIsNotSpeechButShortWordsAndNumbersAre() {
    #expect(TranscriptionTextPolicy.isNonSpeechOnly("。"))
    #expect(TranscriptionTextPolicy.isNonSpeechOnly(" ...！？ "))
    #expect(!TranscriptionTextPolicy.isNonSpeechOnly("好"))
    #expect(!TranscriptionTextPolicy.isNonSpeechOnly("15%"))
}

private func recognition(
    _ text: String, start: Int64 = 0, end: Int64 = 16_000,
    language: SpokenLanguage = .english, final: Bool = false
) -> StreamingTranscriptionUpdate {
    .init(output: .init(text: text, language: language,
                        reportedLanguageCode: language.rawValue, words: []),
          startSample: start, endSample: end, isFinal: final, processingLatency: 0)
}

private func nextRequest(
    _ queue: PartialTranslationQueue, within timeout: Duration = .seconds(2)
) async -> PartialTranslationRequest? {
    let deadline = Task {
        do { try await Task.sleep(for: timeout) } catch { return }
        await queue.finish()
    }
    defer { deadline.cancel() }
    return await queue.next()
}

@Test @MainActor func singleChineseCharacterNeverBypassesContextGuardViaTimer() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("大家好我们", language: .chinese), logger: nil, partialTranslations: queue)
    #expect(await nextRequest(queue, within: .milliseconds(800)) == nil)
    await vm.processStreamingUpdate(recognition("大家好", language: .chinese, final: true), logger: nil, partialTranslations: queue)
    #expect(vm.captionHistory.first?.chineseText == "大家好")
    vm.clearHistory()
}

@Test @MainActor func finalPipelineUsesCorrectedSourceInsteadOfFrozenPrefix() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("I want to discuss the deployment process"), logger: nil, partialTranslations: queue)
    await vm.processStreamingUpdate(recognition("I want to discuss the deployment process today", end: 32_000), logger: nil, partialTranslations: queue)
    #expect(vm.streamingStableOriginal.hasPrefix("I want to"))
    await vm.processStreamingUpdate(recognition("We should discuss the deployment process today.", end: 48_000, final: true), logger: nil, partialTranslations: queue)
    #expect(vm.captionHistory.count == 1)
    #expect(vm.captionHistory.first?.englishText == "We should discuss the deployment process today.")
    #expect(!vm.hasStreamingText)
    vm.clearHistory()
    await queue.finish()
}

@Test @MainActor func translationDeadlineFiresWithoutAnotherASRCallback() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("We can begin the meeting"), logger: nil, partialTranslations: queue)
    #expect(await nextRequest(queue)?.sourceText == "We can begin")
    let start = ContinuousClock.now
    await vm.processStreamingUpdate(recognition("We can begin the meeting now please", end: 32_000), logger: nil, partialTranslations: queue)
    let request = await nextRequest(queue)
    let duration = start.duration(to: .now)
    #expect(request?.sourceText == "We can begin the meeting")
    #expect(duration >= .milliseconds(400))
    #expect(duration < .milliseconds(1400))
    vm.clearHistory()
    await queue.finish()
}

@Test @MainActor func translationDeadlineCoalescesLatestPrefixWithoutBeingPostponed() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("We can begin the meeting"), logger: nil, partialTranslations: queue)
    _ = await nextRequest(queue)
    let start = ContinuousClock.now
    await vm.processStreamingUpdate(recognition("We can begin the meeting now please", end: 32_000), logger: nil, partialTranslations: queue)
    try? await Task.sleep(for: .milliseconds(250))
    await vm.processStreamingUpdate(recognition("We can begin the meeting now please everyone", end: 48_000), logger: nil, partialTranslations: queue)
    let request = await nextRequest(queue)
    #expect(request?.sourceText == "We can begin the meeting now")
    #expect(start.duration(to: .now) < .milliseconds(800))
    vm.clearHistory()
    await queue.finish()
}

@Test @MainActor func finalizationCancelsPendingTranslationDeadline() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("We can begin the meeting"), logger: nil, partialTranslations: queue)
    _ = await nextRequest(queue)
    await vm.processStreamingUpdate(recognition("We can begin the meeting now please", end: 32_000), logger: nil, partialTranslations: queue)
    await vm.processStreamingUpdate(recognition("We can begin the meeting now.", end: 48_000, final: true), logger: nil, partialTranslations: queue)
    #expect(await nextRequest(queue, within: .milliseconds(800)) == nil)
    #expect(vm.captionHistory.count == 1)
    vm.clearHistory()
}

@Test @MainActor func clearHistoryCancelsPendingTranslationDeadline() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("We can begin the meeting"), logger: nil, partialTranslations: queue)
    _ = await nextRequest(queue)
    await vm.processStreamingUpdate(recognition("We can begin the meeting now please", end: 32_000), logger: nil, partialTranslations: queue)
    vm.clearHistory()
    #expect(await nextRequest(queue, within: .milliseconds(800)) == nil)
    #expect(vm.captionHistory.isEmpty)
    #expect(!vm.hasStreamingText)
}

@Test @MainActor func newSegmentAndLanguageCancelOldPendingTranslation() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("We can begin the meeting"), logger: nil, partialTranslations: queue)
    _ = await nextRequest(queue)
    await vm.processStreamingUpdate(recognition("We can begin the meeting now please", end: 32_000), logger: nil, partialTranslations: queue)
    await vm.processStreamingUpdate(recognition("我们现在开始讨论今天的议题", start: 48_000, end: 64_000, language: .chinese), logger: nil, partialTranslations: queue)
    let request = await nextRequest(queue)
    #expect(request?.segment.startSample == 48_000)
    #expect(request?.direction == .chineseToEnglish)
    #expect(await nextRequest(queue, within: .milliseconds(800)) == nil)
    vm.clearHistory()
}

@Test @MainActor func lateFinalDoesNotResetNewSegmentsFrozenPrefix() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("We can now safely ship this release", start: 48_000, end: 64_000), logger: nil, partialTranslations: queue)
    await vm.processStreamingUpdate(recognition("We can now safely ship this release today", start: 48_000, end: 80_000), logger: nil, partialTranslations: queue)
    let frozen = vm.streamingStableOriginal
    await vm.processStreamingUpdate(recognition("An older sentence is complete.", start: 0, end: 32_000, final: true), logger: nil, partialTranslations: queue)
    await vm.processStreamingUpdate(recognition("A completely different hypothesis", start: 48_000, end: 96_000), logger: nil, partialTranslations: queue)
    #expect(!frozen.isEmpty)
    #expect(vm.streamingStableOriginal == frozen)
    #expect(vm.captionHistory.first?.englishText == "An older sentence is complete.")
    vm.clearHistory()
    await queue.finish()
}

@Test @MainActor func trimmedNativeFinalRetiresDraftAndItsTranslationDeadline() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("We can begin the meeting", start: 0, end: 300_000), logger: nil, partialTranslations: queue)
    _ = await nextRequest(queue)
    await vm.processStreamingUpdate(recognition("We can begin the meeting now please", start: 0, end: 309_120), logger: nil, partialTranslations: queue)
    // Captured Apple Speech pattern: the final trims leading/trailing silence.
    await vm.processStreamingUpdate(recognition("We can begin the meeting now.", start: 75_840, end: 304_320, final: true), logger: nil, partialTranslations: queue)
    #expect(vm.captionHistory.count == 1)
    #expect(!vm.hasStreamingText)
    #expect(await nextRequest(queue, within: .milliseconds(800)) == nil)
    vm.clearHistory()
}

@Test @MainActor func overlappingOlderFinalPreservesDraftThatExtendsIntoNewAudio() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("This is the next sentence", start: 30_000, end: 64_000), logger: nil, partialTranslations: queue)
    await vm.processStreamingUpdate(recognition("The previous sentence.", start: 0, end: 32_000, final: true), logger: nil, partialTranslations: queue)
    #expect(vm.hasStreamingText)
    #expect(vm.streamingOriginalText == "This is the next sentence")
    vm.clearHistory()
    await queue.finish()
}

@Test @MainActor func completeGreetingSettlesWithoutWaitingForMoreAudio() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    let start = ContinuousClock.now
    await vm.processStreamingUpdate(recognition("大家好", language: .chinese), logger: nil, partialTranslations: queue)
    #expect(await nextRequest(queue)?.sourceText == "大家好")
    #expect(start.duration(to: .now) >= .milliseconds(200))
    #expect(start.duration(to: .now) < .milliseconds(600))
    vm.clearHistory()
    await queue.finish()
}

@Test @MainActor func subwordBurstCannotSubmitAnObsoleteInitialPhrase() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("Hello everyone"), logger: nil, partialTranslations: queue)
    await vm.processStreamingUpdate(recognition("Hello everyone we"), logger: nil, partialTranslations: queue)
    #expect(await nextRequest(queue, within: .milliseconds(500)) == nil)
    vm.clearHistory()
}

@Test @MainActor func clearAndFinalCancelInitialSettling() async {
    for final in [false, true] {
        let vm = CaptionViewModel()
        let queue = PartialTranslationQueue()
        await vm.processStreamingUpdate(recognition("Hello everyone"), logger: nil, partialTranslations: queue)
        if final {
            await vm.processStreamingUpdate(recognition("Hello everyone.", final: true), logger: nil, partialTranslations: queue)
        } else { vm.clearHistory() }
        #expect(await nextRequest(queue, within: .milliseconds(500)) == nil)
        vm.clearHistory()
    }
}

@Test @MainActor func draftTranslationCanCorrectAnAlreadyFrozenRecognitionError() async {
    let vm = CaptionViewModel()
    let queue = PartialTranslationQueue()
    await vm.processStreamingUpdate(recognition("I want to discuss the deployment process"), logger: nil, partialTranslations: queue)
    _ = await nextRequest(queue)
    await vm.processStreamingUpdate(recognition("I want to discuss the deployment process today", end: 32_000), logger: nil, partialTranslations: queue)
    await vm.processStreamingUpdate(recognition("We should discuss the deployment process today", end: 48_000), logger: nil, partialTranslations: queue)
    let request = await nextRequest(queue)
    #expect(request?.sourceText.hasPrefix("We should discuss") == true)
    #expect(vm.streamingStableOriginal.hasPrefix("I want"))
    vm.clearHistory()
    await queue.finish()
}
