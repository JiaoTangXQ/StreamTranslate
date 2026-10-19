import Foundation
import Testing
@testable import StreamTranslate

@MainActor private final class SummaryStub: ConversationSummaryProviding {
    var prepared = 0
    var cancelled = false
    var requests: [(String, String)] = []
    var fails = false
    var delay: Duration = .zero
    func prepare() async throws { prepared += 1 }
    func summarize(_ text: String, previous: String) async throws -> String {
        requests.append((text, previous))
        if delay > .zero { try? await Task.sleep(for: delay) }
        if fails { throw SummaryError.invalidResult }
        return "在聊什么\n讨论窗口卡顿。\n讨论进展\n保留100条，完整记录本地保存。\n待确认\n停字幕原因仍未复现。"
    }
    func cancel() { cancelled = true }
}

private func summaryEntries(_ count: Int) -> [CaptionEntry] {
    (0..<count).map { CaptionEntry(timestamp: .now,
        englishText: "Topic \($0): discuss the meeting and keep the full record.", chineseText: "") }
}

@MainActor private func waitForSummary(_ model: ConversationSummaryModel) async {
    for _ in 0..<400 {
        if !model.isGenerating { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Summary fixture did not complete")
    model.cancel()
}

@Test func summaryChunksCoverEveryCharacterWithoutOversizedRequests() {
    let entries = [CaptionEntry(timestamp: .now, englishText: String(repeating: "中🙂A", count: 900), chineseText: ""),
                   CaptionEntry(timestamp: .now, englishText: "Last topic", chineseText: "")]
    let chunks = SummaryTranscript.chunks(entries[...])
    #expect(chunks.allSatisfy { $0.count <= 1_200 })
    #expect(chunks.joined() == entries.map { $0.originalText + "\n" }.joined())
}

@Test @MainActor func collapsedSummaryDoesNotLoadAModel() {
    let engine = SummaryStub()
    let model = ConversationSummaryModel { engine }
    #expect(!model.isExpanded)
    #expect(engine.prepared == 0)
    #expect(!model.isGenerating)
}

@Test @MainActor func summaryCoversMoreThanThe100LiveCaptionsAndReleasesModel() async {
    let engine = SummaryStub()
    let model = ConversationSummaryModel { engine }
    let entries = summaryEntries(250)
    model.generate(sourceRevision: 250) { entries }
    await waitForSummary(model)
    #expect(model.coveredCount == 250)
    #expect(engine.requests.map { $0.0 }.joined().contains("Topic 0:"))
    #expect(engine.requests.map { $0.0 }.joined().contains("Topic 249:"))
    #expect(engine.requests.dropFirst().allSatisfy { !$0.1.isEmpty })
    #expect(engine.cancelled)
}

@Test @MainActor func summaryUpdateProcessesOnlyNewRowsAndRestartsAfterSourceCorrection() async {
    var engines: [SummaryStub] = []
    let model = ConversationSummaryModel {
        let engine = SummaryStub(); engines.append(engine); return engine
    }
    var entries = summaryEntries(3)
    let first = entries
    model.generate(sourceRevision: 3) { first }
    await waitForSummary(model)
    let oldText = model.text
    entries.append(CaptionEntry(timestamp: .now, englishText: "A new topic", chineseText: ""))
    let second = entries
    model.generate(sourceRevision: 4) { second }
    await waitForSummary(model)
    #expect(engines[1].requests.first?.0 == "A new topic\n")
    #expect(engines[1].requests.first?.1 == oldText)
    let original = entries[0]
    entries[0] = CaptionEntry(id: original.id, timestamp: original.timestamp,
        englishText: "An earlier source correction", chineseText: "")
    let corrected = entries
    model.generate(sourceRevision: 5) { corrected }
    await waitForSummary(model)
    #expect(engines[2].requests.first?.0.contains("An earlier source correction") == true)
    #expect(engines[2].requests.first?.1.isEmpty == true)
}

@Test @MainActor func clearingOrCollapsingRejectsLateSummaryEvenIfBackendIgnoresCancellation() async {
    for clear in [false, true] {
        let engine = SummaryStub(); engine.delay = .milliseconds(60)
        let model = ConversationSummaryModel { engine }
        model.isExpanded = true
        model.generate(sourceRevision: 1) { summaryEntries(1) }
        for _ in 0..<100 {
            if !engine.requests.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if clear { model.reset() } else { model.collapse() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.text.isEmpty)
        #expect(!model.isGenerating)
        #expect(engine.cancelled)
    }
}

@Test @MainActor func summaryFailureKeepsPreviousResultAndRetriesUnseenRows() async {
    var engines: [SummaryStub] = []
    let model = ConversationSummaryModel {
        let engine = SummaryStub(); engine.fails = engines.count == 1
        engines.append(engine); return engine
    }
    let first = summaryEntries(1)
    model.generate(sourceRevision: 1) { first }
    await waitForSummary(model)
    let prior = model.text
    let second = first + [CaptionEntry(timestamp: .now, englishText: "New material", chineseText: "")]
    model.generate(sourceRevision: 2) { second }
    await waitForSummary(model)
    #expect(model.text == prior)
    #expect(model.coveredCount == 1)
    #expect(model.errorMessage != nil)
    model.generate(sourceRevision: 2) { second }
    await waitForSummary(model)
    #expect(engines[2].requests.first?.0 == "New material\n")
    #expect(model.coveredCount == 2)
}

@Test @MainActor func summaryReadsFullSavedCurrentSessionAndClearRetiresIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SummaryHistory.\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptionHistoryStore(directory: directory)
    let engine = SummaryStub()
    let summary = ConversationSummaryModel { engine }
    let vm = CaptionViewModel(historyStore: store, conversationSummary: summary)
    vm.addCaption(english: "Previous conversation must be excluded", chinese: "")
    vm.beginCompanionSession()
    for index in 0..<150 { vm.addCaption(english: "Line \(index)", chinese: "") }
    #expect(vm.captionHistory.count == 100)
    #expect(try await store.captions(in: vm.companionSessionID).count == 150)
    vm.requestConversationSummary()
    await waitForSummary(summary)
    #expect(summary.coveredCount == 150)
    let input = engine.requests.map { $0.0 }.joined()
    #expect(input.contains("Line 0\n"))
    #expect(input.contains("Line 149\n"))
    #expect(!input.contains("Previous conversation"))
    let revision = vm.conversationSourceRevision
    vm.clearHistory()
    #expect(vm.conversationSourceRevision == 0)
    #expect(revision == 150)
    #expect(vm.conversationSummary.text.isEmpty)
}
