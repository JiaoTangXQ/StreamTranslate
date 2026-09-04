import Testing
import Foundation
@testable import StreamTranslate

// MARK: - Basic State

@Test @MainActor func initialStateIsNotRecording() {
    let vm = CaptionViewModel()
    #expect(vm.isRecording == false)
    #expect(vm.captionHistory.isEmpty)
    #expect(vm.recentCaptions.isEmpty)
}

@Test @MainActor func initialStateStreamingIsEmpty() {
    let vm = CaptionViewModel()
    #expect(vm.streamingEnglish == "")
    #expect(vm.streamingChinese == "")
    #expect(vm.streamingWords.isEmpty)
}

@Test @MainActor func captionContentRevisionIgnoresTextOnlyChanges() {
    let vm = CaptionViewModel()
    vm.streamingEnglish = "The source text"
    let beforeTranslation = vm.captionContentRevision

    vm.streamingChinese = "译文"

    #expect(vm.captionContentRevision == beforeTranslation)
}

@Test @MainActor func initialLoadingAndModelState() {
    let vm = CaptionViewModel()
    #expect(vm.isLoading == false)
    #expect(vm.isModelReady == false)
    #expect(vm.statusMessage == "")
}

// MARK: - addCaption

@Test @MainActor func addCaptionAppendsToHistory() {
    let vm = CaptionViewModel()
    vm.addCaption(english: "Hello", chinese: "你好")
    #expect(vm.captionHistory.count == 1)
    #expect(vm.captionHistory[0].englishText == "Hello")
    #expect(vm.captionHistory[0].chineseText == "你好")
}

@Test @MainActor func addCaptionAppendsToRecentCaptions() {
    let vm = CaptionViewModel()
    vm.addCaption(english: "Hello", chinese: "你好")
    #expect(vm.recentCaptions.count == 1)
    #expect(vm.recentCaptions[0].englishText == "Hello")
}

@Test @MainActor func recentCaptionsLimitedToTwo() {
    let vm = CaptionViewModel()
    vm.addCaption(english: "One", chinese: "一")
    vm.addCaption(english: "Two", chinese: "二")
    vm.addCaption(english: "Three", chinese: "三")
    #expect(vm.recentCaptions.count == 2)
    #expect(vm.recentCaptions[0].englishText == "Two")
    #expect(vm.recentCaptions[1].englishText == "Three")
}

@Test @MainActor func historyGrowsUnbounded() {
    let vm = CaptionViewModel()
    for i in 0..<10 {
        vm.addCaption(english: "Line \(i)", chinese: "行 \(i)")
    }
    #expect(vm.captionHistory.count == 10)
    #expect(vm.recentCaptions.count == 2)
}

@Test @MainActor func addCaptionWithEmptyStrings() {
    let vm = CaptionViewModel()
    vm.addCaption(english: "", chinese: "")
    #expect(vm.captionHistory.count == 1)
}

// MARK: - clearHistory

@Test @MainActor func clearHistoryRemovesAllEntries() {
    let vm = CaptionViewModel()
    vm.addCaption(english: "Test", chinese: "测试")
    vm.clearHistory()
    #expect(vm.captionHistory.isEmpty)
    #expect(vm.recentCaptions.isEmpty)
}

@Test @MainActor func clearHistoryClearsStreamingState() {
    let vm = CaptionViewModel()
    vm.streamingEnglish = "streaming"
    vm.streamingChinese = "流式"
    vm.clearHistory()
    #expect(vm.streamingEnglish == "")
    #expect(vm.streamingChinese == "")
    #expect(vm.streamingWords.isEmpty)
}

@Test @MainActor func clearHistoryOnEmptyIsNoop() {
    let vm = CaptionViewModel()
    vm.clearHistory()
    #expect(vm.captionHistory.isEmpty)
}

// MARK: - toggleCapture without model

@Test @MainActor func toggleCaptureWithoutModelDoesNotRecord() {
    let vm = CaptionViewModel()
    #expect(vm.isRecording == false)
}

// MARK: - Rapid addCaption

@Test @MainActor func rapidAddCaptionMaintainsOrder() {
    let vm = CaptionViewModel()
    for i in 1...20 {
        vm.addCaption(english: "Sentence \(i)", chinese: "句子 \(i)")
    }
    #expect(vm.captionHistory.count == 20)
    #expect(vm.captionHistory.first?.englishText == "Sentence 1")
    #expect(vm.captionHistory.last?.englishText == "Sentence 20")
    #expect(vm.recentCaptions.count == 2)
    #expect(vm.recentCaptions[0].englishText == "Sentence 19")
    #expect(vm.recentCaptions[1].englishText == "Sentence 20")
}

@Test @MainActor func captionHistoryEntriesHaveUniqueIds() {
    let vm = CaptionViewModel()
    vm.addCaption(english: "A", chinese: "甲")
    vm.addCaption(english: "B", chinese: "乙")
    vm.addCaption(english: "C", chinese: "丙")
    let ids = Set(vm.captionHistory.map { $0.id })
    #expect(ids.count == 3)
}

@Test @MainActor func completedCaptionsAreCommittedImmediatelyWithoutOverwriteWindow() {
    let vm = CaptionViewModel()

    vm.showCompleted(
        english: "Hello, can you hear me?",
        chinese: "你好，你能听到吗？",
        sourceLanguage: .english
    )
    vm.showCompleted(
        english: "The second sentence.",
        chinese: "第二句话。",
        sourceLanguage: .english
    )

    #expect(vm.captionHistory.map(\.englishText) == [
        "Hello, can you hear me?",
        "The second sentence."
    ])
}

// MARK: - Bilingual Reading Time

@Test func readingTimeShortSentence() {
    let time = CaptionViewModel.estimateReadingTime(english: "Hello", chinese: "你好")
    #expect(time == 2.5)
}

@Test func readingTimeMediumSentence() {
    let time = CaptionViewModel.estimateReadingTime(
        english: "This is a medium length sentence for testing",
        chinese: "这是一个中等长度的测试句子"
    )
    #expect(time >= 3.5 && time <= 4.5)
}

@Test func readingTimeLongChineseDominates() {
    let time = CaptionViewModel.estimateReadingTime(
        english: "Hi",
        chinese: "这是一个非常非常非常非常非常非常非常非常非常长的中文翻译"
    )
    #expect(time >= 4.0 && time <= 5.0)
}

@Test func readingTimeClampedToMax() {
    let longEN = String(repeating: "word ", count: 50)
    let longZH = String(repeating: "字", count: 100)
    let time = CaptionViewModel.estimateReadingTime(english: longEN, chinese: longZH)
    #expect(time == 10.0)
}

@Test func readingTimeEmptyStrings() {
    let time = CaptionViewModel.estimateReadingTime(english: "", chinese: "")
    #expect(time == 2.5)
}

// Model downloading is covered by live integration tests. Unit tests avoid
// starting a several-hundred-megabyte network transfer.

@Test func speechEventQueueCoalescesStalePartials() async {
    let queue = SpeechEventQueue()
    await queue.submit(.partial(testSegment(start: 0, count: 100)))
    await queue.submit(.partial(testSegment(start: 0, count: 200)))

    guard case .partial(let segment) = await queue.next() else {
        Issue.record("Expected the newest partial")
        return
    }
    #expect(segment.samples.count == 200)
}

@Test func speechEventQueuePrioritizesFinalAndDropsMatchingPartial() async {
    let queue = SpeechEventQueue()
    await queue.submit(.partial(testSegment(start: 0, count: 100)))
    await queue.submit(.final(testSegment(start: 0, count: 120)))
    await queue.finish()

    guard case .final(let segment) = await queue.next() else {
        Issue.record("Expected the final segment")
        return
    }
    #expect(segment.samples.count == 120)
    #expect(await queue.next() == nil)
}

@Test func partialTranslationQueueKeepsOnlyTheNewestRequest() async {
    let queue = PartialTranslationQueue()
    await queue.submit(testTranslationRequest(start: 0, text: "first"))
    await queue.submit(testTranslationRequest(start: 0, text: "newest"))

    let request = await queue.next()

    #expect(request?.output.text == "newest")
}

@Test func partialTranslationQueueCanDiscardACompletedSegment() async {
    let queue = PartialTranslationQueue()
    await queue.submit(testTranslationRequest(start: 42, text: "stale"))
    await queue.discard(segmentStartingAt: 42)
    await queue.finish()

    #expect(await queue.next() == nil)
}

private func testSegment(start: Int64, count: Int) -> SpeechSegment {
    SpeechSegment(
        samples: Array(repeating: 0, count: count),
        startSample: start,
        endSample: start + Int64(count)
    )
}


private func testTranslationRequest(
    start: Int64,
    text: String
) -> PartialTranslationRequest {
    PartialTranslationRequest(
        segment: testSegment(start: start, count: 100),
        output: TranscriptionOutput(
            text: text,
            language: .english,
            reportedLanguageCode: "en",
            words: [],
            averageLogProbability: -0.2,
            noSpeechProbability: 0
        ),
        sourceText: text,
        direction: .englishToChinese,
        generation: 0
    )
}
