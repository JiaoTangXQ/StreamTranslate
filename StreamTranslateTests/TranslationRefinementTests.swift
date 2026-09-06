import Foundation
import Testing
@testable import StreamTranslate

@Test @MainActor func refinementReusesExactPromptPrefixesWithoutAppendingConversationHistory() throws {
    let body = LocalHYTranslationService.requestBody("The meeting has started.", sourceLanguage: .english,
        target: .simplifiedChinese, context: "Unrelated earlier conversation.")
    #expect(body["cache_prompt"] as? Bool == true)
    #expect(body["max_tokens"] as? Int == 384)
    #expect(body["stream"] as? Bool == false)
    let messages = body["messages"] as? [[String: String]]
    #expect(messages?.count == 1)
    #expect(messages?.first?["role"] == "user")
    #expect(messages?.first?["content"]?.contains("Unrelated earlier") == false)
    #expect(messages?.first?["content"]?.hasSuffix("The meeting has started.") == true)
    #expect(JSONSerialization.isValidJSONObject(body))
}

@MainActor private final class TranslationRefinerStub: TranslationRefinementProviding {
    var isReady = true
    let text: String
    let delay: Duration
    init(_ text: String, delay: Duration = .milliseconds(50)) { self.text = text; self.delay = delay }
    func translate(_ text: String, sourceLanguage: SpokenLanguage, target: TranslationTarget, context: String) async throws -> String {
        try? await Task.sleep(for: delay)
        return self.text
    }
    func cancel() { isReady = false }
}

@Test @MainActor func softwareContextSuppliesOnlyMatchingHomophoneTerminology() {
    let prompt = LocalHYTranslationService.prompt("It was a cash eviction problem.", target: .simplifiedChinese,
        context: "We ruled out a memory leak.")
    #expect(prompt.contains("cash eviction -> 缓存淘汰"))
    #expect(!prompt.contains("[Background Information]"))
    #expect(!prompt.contains("We ruled out a memory leak."))
    #expect(LocalHYTranslationService.contextualTerminology(for: "The key-value cash keeps growing.",
        context: "The current model weights stay the same size.").first?.1 == "键值缓存")
}

@Test @MainActor func financialContextAndUnrelatedCashExpressionsVetoSoftwareCorrections() {
    #expect(LocalHYTranslationService.contextualTerminology(for: "It was a cash eviction problem.",
        context: "The tenant has to pay rent.").isEmpty)
    #expect(LocalHYTranslationService.contextualTerminology(for: "It was a cash eviction problem.",
        context: "We fixed a memory leak. Now the tenant has to pay rent.").isEmpty)
    #expect(LocalHYTranslationService.contextualTerminology(for: "Cash collection failed.",
        context: "The server has a memory leak.").isEmpty)
    #expect(LocalHYTranslationService.contextualTerminology(for: "The cash balance keeps growing.",
        context: "We ruled out a memory leak.").isEmpty)
}

private func refinementRequest(_ entry: CaptionEntry) -> FinalTranslationRequest {
    .init(entryID: entry.id, segment: .init(samples: [], startSample: 0, endSample: 16000),
          output: .init(text: entry.originalText, language: entry.sourceLanguage, reportedLanguageCode: entry.sourceLanguage.rawValue, words: []),
          sourceText: entry.originalText, direction: TranslationDirection.forSource(entry.sourceLanguage)!, generation: 0, queuedAt: .now, logger: nil)
}

@Test @MainActor func chineseTranslationRefinementPreservesSourceAndReplacesEnglish() async {
    let vm = CaptionViewModel()
    vm.addCaption(english: "final consistency", chinese: "最终一致性", sourceLanguage: .chinese)
    vm.configureTranslationRefinement(TranslationRefinerStub("eventual consistency"))
    vm.enqueueTranslationRefinement(refinementRequest(vm.captionHistory[0]))
    await vm.waitForFinalTranslations()
    #expect(vm.captionHistory[0].englishText == "eventual consistency")
    #expect(vm.captionHistory[0].chineseText == "最终一致性")
    #expect(vm.captionHistory[0].sourceLanguage == .chinese)
    vm.clearHistory()
}

@Test @MainActor func refinementRejectsNumericRegressionAndKeepsFastTranslation() async {
    let vm = CaptionViewModel()
    vm.addCaption(english: "By a third, not to a third.", chinese: "减少三分之一，不是降到三分之一。")
    vm.configureTranslationRefinement(TranslationRefinerStub("减少三分之一，而非三分之二。"))
    vm.enqueueTranslationRefinement(refinementRequest(vm.captionHistory[0]))
    await vm.waitForFinalTranslations()
    #expect(vm.captionHistory[0].chineseText == "减少三分之一，不是降到三分之一。")
    vm.clearHistory()
}

@Test @MainActor func refinementRejectsDroppedNegativeContrastAndKeepsFastTranslation() async {
    let vm = CaptionViewModel()
    vm.addCaption(english: "Latency fell by a third, not to a third.", chinese: "延迟降低了三分之一，不是降低到三分之一。", sourceLanguage: .chinese)
    vm.configureTranslationRefinement(TranslationRefinerStub("Latency fell by a third."))
    vm.enqueueTranslationRefinement(refinementRequest(vm.captionHistory[0]))
    await vm.waitForFinalTranslations()
    #expect(vm.captionHistory[0].englishText == "Latency fell by a third, not to a third.")
    vm.clearHistory()
}

@Test @MainActor func refinementContextNeverIncludesPreviousCaptureOrCurrentSentence() {
    let vm = CaptionViewModel()
    vm.addCaption(english: "Unrelated previous capture.", chinese: "上次记录")
    vm.configureTranslationRefinement(TranslationRefinerStub(""))
    vm.addCaption(english: "I used to think the update was safe.", chinese: "我曾认为更新安全")
    vm.addCaption(english: "I no longer do.", chinese: "我不再这样认为")
    let context = vm.refinementContext(for: refinementRequest(vm.captionHistory[2]))
    #expect(context == "I used to think the update was safe.")
    vm.clearHistory()
}

@Test @MainActor func memoryPressureCancelsLateRefinementWithoutRemovingCaption() async {
    let vm = CaptionViewModel()
    vm.addCaption(english: "The meeting has started.", chinese: "会议开始")
    let refiner = TranslationRefinerStub("会议已经开始。")
    vm.configureTranslationRefinement(refiner)
    vm.enqueueTranslationRefinement(refinementRequest(vm.captionHistory[0]))
    try? await Task.sleep(for: .milliseconds(10))
    vm.suspendLocalEnhancementsForMemoryPressure()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(!refiner.isReady)
    #expect(vm.captionHistory.count == 1)
    #expect(vm.captionHistory[0].chineseText == "会议开始")
    vm.clearHistory()
}

@Test @MainActor func translationRefinementUpdatesSameEntryAndPreservesTimestamp() async {
    let vm = CaptionViewModel()
    vm.addCaption(english: "The model weights stay the same size.", chinese: "模型重量保持不变。")
    let entry = vm.captionHistory[0]
    let revision = vm.captionContentRevision
    vm.configureTranslationRefinement(TranslationRefinerStub("模型权重大小保持不变。"))
    vm.enqueueTranslationRefinement(refinementRequest(entry))
    await vm.waitForFinalTranslations()
    #expect(vm.captionHistory.count == 1)
    #expect(vm.captionHistory[0].id == entry.id)
    #expect(vm.captionHistory[0].timestamp == entry.timestamp)
    #expect(vm.captionHistory[0].chineseText == "模型权重大小保持不变。")
    #expect(vm.captionContentRevision != revision)
    vm.clearHistory()
}

@Test @MainActor func translationRefinementCannotOverwriteNewerSourceRevision() async {
    let vm = CaptionViewModel()
    vm.addCaption(english: "The key value cash keeps growing.", chinese: "旧译文")
    let entry = vm.captionHistory[0]
    vm.configureTranslationRefinement(TranslationRefinerStub("错误现金译文"))
    vm.enqueueTranslationRefinement(refinementRequest(entry))
    try? await Task.sleep(for: .milliseconds(10))
    vm.captionHistory[0] = .init(id: entry.id, timestamp: entry.timestamp,
        englishText: "The key-value cache keeps growing.", chineseText: "键值缓存持续增长。")
    await vm.waitForFinalTranslations()
    #expect(vm.captionHistory[0].chineseText == "键值缓存持续增长。")
    vm.clearHistory()
}

@Test @MainActor func translationRefinementCannotRepopulateClearedHistory() async {
    let vm = CaptionViewModel()
    vm.addCaption(english: "The meeting has started.", chinese: "会议开始")
    vm.configureTranslationRefinement(TranslationRefinerStub("会议已经开始。"))
    vm.enqueueTranslationRefinement(refinementRequest(vm.captionHistory[0]))
    try? await Task.sleep(for: .milliseconds(10))
    vm.clearHistory()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(vm.captionHistory.isEmpty)
}

@Test @MainActor func refinementGlossaryOnlyAppliesMatchingTermsAndRespectsChineseScript() {
    let plain = LocalHYTranslationService.prompt("The meeting has started.", target: .simplifiedChinese)
    #expect(!plain.contains("terminology"))
    let technical = LocalHYTranslationService.prompt("The model weights and key-value cache grow.", target: .simplifiedChinese)
    #expect(technical.contains("model weights -> 模型权重"))
    #expect(technical.contains("key-value cache -> 键值缓存"))
    #expect(!technical.contains("readiness probe"))
    let traditional = LocalHYTranslationService.prompt("The model weights grow.", target: .traditionalChineseTaiwan)
    #expect(traditional.contains("模型權重"))
    #expect(traditional.contains("Traditional Chinese (Taiwan)"))
    let chinese = LocalHYTranslationService.prompt("最终一致性", sourceLanguage: .chinese, target: .simplifiedChinese)
    #expect(chinese.contains("into English"))
    #expect(!chinese.contains("terminology"))
    let contextual = LocalHYTranslationService.prompt("I no longer do.", target: .simplifiedChinese,
        context: "I used to think the update was safe.")
    #expect(!contextual.contains("[Background Information]"))
    #expect(contextual.hasSuffix("I no longer think the update was safe."))
}
