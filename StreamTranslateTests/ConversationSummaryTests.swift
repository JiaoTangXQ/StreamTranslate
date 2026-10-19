import Foundation
import Testing
@testable import StreamTranslate

@MainActor private final class SummaryStub: ConversationSummaryProviding {
    var prepared = 0
    var cancelled = false
    var requests: [(String, String)] = []
    var fails = false
    var delay: Duration = .zero
    var activeRequests = 0
    var maximumActiveRequests = 0
    func prepare() async throws { prepared += 1 }
    func summarize(_ text: String, previous: String, onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        requests.append((text, previous))
        activeRequests += 1; maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }
        onUpdate("在聊什么\n正在生成的草稿")
        if delay > .zero { try? await Task.sleep(for: delay) }
        onUpdate("在聊什么\n迟到或完成的草稿")
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

@MainActor private func waitForAutomaticSummary(_ model: ConversationSummaryModel) async {
    for _ in 0..<600 {
        if !model.isGenerating && !model.isUpdateScheduled { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Automatic summary did not settle")
    model.collapse()
}

@Test @MainActor func automaticSummaryCoalescesBusyChangesAndReusesOneWorker() async {
    let engine = SummaryStub(); engine.delay = .milliseconds(40)
    let model = ConversationSummaryModel(updateDelay: .milliseconds(10), idleTimeout: .seconds(5)) { engine }
    let vm = CaptionViewModel(conversationSummary: model)
    vm.addCaption(english: "First topic", chinese: "")
    #expect(engine.prepared == 0)
    vm.expandConversationSummary()
    for _ in 0..<200 {
        if !engine.requests.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(2))
    }
    #expect(!model.draftText.isEmpty)
    vm.addCaption(english: "Second topic", chinese: "")
    vm.addCaption(english: "Third topic", chinese: "")
    await waitForAutomaticSummary(model)
    #expect(engine.requests.count == 2)
    #expect(engine.requests.last?.0 == "Second topic\nThird topic\n")
    #expect(engine.requests.last?.1.isEmpty == false)
    #expect(engine.maximumActiveRequests == 1)
    #expect(engine.prepared == 1)
    #expect(!engine.cancelled)
    #expect(model.coveredCount == 3)
    #expect(model.completedSourceRevision == vm.conversationSourceRevision)
    #expect(model.draftText.isEmpty)
    model.collapse()
    #expect(engine.cancelled)
}

@Test @MainActor func automaticSummaryPauseRejectsDraftAndPendingWorkThenResumes() async {
    var engines: [SummaryStub] = []
    let model = ConversationSummaryModel(updateDelay: .milliseconds(5)) {
        let engine = SummaryStub(); engine.delay = .milliseconds(80); engines.append(engine); return engine
    }
    let vm = CaptionViewModel(conversationSummary: model)
    vm.addCaption(english: "First topic", chinese: "")
    vm.expandConversationSummary()
    for _ in 0..<200 {
        if !model.draftText.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(2))
    }
    vm.addCaption(english: "Queued topic", chinese: "")
    model.pauseAutomaticUpdates()
    vm.addCaption(english: "Topic while paused", chinese: "")
    try? await Task.sleep(for: .milliseconds(100))
    #expect(engines.count == 1)
    #expect(model.text.isEmpty && model.draftText.isEmpty)
    #expect(!model.isGenerating && !model.isUpdateScheduled)
    #expect(!model.isAutoUpdating)
    #expect(engines[0].cancelled)
    vm.resumeConversationSummary()
    await waitForAutomaticSummary(model)
    #expect(engines.count == 2)
    #expect(model.coveredCount == 3)
    model.collapse()
}

@Test @MainActor func automaticSummaryReleasesIdleWorkerAndOnlyProcessesNewContentOnReturn() async {
    var engines: [SummaryStub] = []
    let model = ConversationSummaryModel(updateDelay: .milliseconds(5), idleTimeout: .milliseconds(20)) {
        let engine = SummaryStub(); engines.append(engine); return engine
    }
    let vm = CaptionViewModel(conversationSummary: model)
    vm.addCaption(english: "First", chinese: "")
    vm.expandConversationSummary()
    await waitForAutomaticSummary(model)
    try? await Task.sleep(for: .milliseconds(60))
    #expect(engines.first?.cancelled == true)
    vm.addCaption(english: "New after idle", chinese: "")
    await waitForAutomaticSummary(model)
    #expect(engines.count == 2)
    #expect(engines.last?.requests.first?.0 == "New after idle\n")
    model.collapse()
}

@Test @MainActor func automaticSummaryFailurePausesInsteadOfRetryingEveryCaption() async {
    var engines: [SummaryStub] = []
    let model = ConversationSummaryModel(updateDelay: .milliseconds(5)) {
        let engine = SummaryStub(); engine.fails = engines.isEmpty; engines.append(engine); return engine
    }
    let vm = CaptionViewModel(conversationSummary: model)
    vm.addCaption(english: "First", chinese: "")
    vm.expandConversationSummary()
    await waitForAutomaticSummary(model)
    #expect(!model.isAutoUpdating && model.errorMessage != nil)
    vm.addCaption(english: "Second", chinese: "")
    try? await Task.sleep(for: .milliseconds(30))
    #expect(engines.count == 1)
    vm.resumeConversationSummary()
    await waitForAutomaticSummary(model)
    #expect(engines.count == 2)
    #expect(model.coveredCount == 2)
    #expect(model.errorMessage == nil)
    model.collapse()
}

@Test func summaryEventDecoderPreservesSplitUnicodeAndStreamsBeforeCompletion() throws {
    func frame(_ delta: String, reason: String? = nil) throws -> Data {
        let choice: [String: Any] = ["delta": ["content": delta], "finish_reason": reason as Any? ?? NSNull()]
        let json = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }
    let expected = "在聊什么\n讨论🙂窗口和新决定。"
    let data = try frame("在聊什么\n") + frame("讨论🙂窗口") + frame("和新决定。", reason: "stop")
    var decoder = SummaryEventDecoder(), snapshots: [String] = []
    for byte in data {
        if try decoder.append(Data([byte])) { snapshots.append(decoder.text) }
    }
    #expect(snapshots.count == 3)
    #expect(snapshots.first == "在聊什么\n")
    #expect(try decoder.finish() == expected)
}

@Test func summaryEventDecoderRejectsTruncatedAndTokenLimitedOutput() throws {
    var decoder = SummaryEventDecoder()
    _ = try decoder.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"部分摘要\"}}]}\n\n".utf8))
    #expect(throws: SummaryError.self) { _ = try decoder.finish() }
    #expect(throws: SummaryError.self) {
        _ = try decoder.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n".utf8))
    }
}

@Test @MainActor func summaryStartupReportsActualWorkerExitInsteadOfGenericUnavailable() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SummaryWorkerExit.\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("llama-server")
    try "#!/bin/sh\nexit 42\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let model = folder.appendingPathComponent("model.gguf")
    try Data([1]).write(to: model)
    let service = LocalSummaryService(assets: .init(executable: executable, model: model), startupTimeout: .seconds(2))
    defer { service.cancel() }
    do {
        try await service.prepare()
        Issue.record("An exited worker must not report ready")
    } catch {
        #expect(error.localizedDescription.contains("42"))
    }
}

@Test func mindMapPreservesTopicBranchesAndTheirOwnPoints() {
    let source = "主题：幸福与伴侣关系\n- 婚姻选择\n  - 有人看重住房条件。\n  - 发言者表达惊讶。\n- 幸福理解\n  - 双方正在讨论何为美好生活。"
    let map = ConversationMindMap.parse(source)
    #expect(map?.topic == "幸福与伴侣关系")
    #expect(map?.branches.map(\.title) == ["婚姻选择", "幸福理解"])
    #expect(map?.branches[0].points == ["有人看重住房条件。", "发言者表达惊讶。"])
    #expect(map?.branches[1].points == ["双方正在讨论何为美好生活。"])
}

@Test func streamedMindMapWaitsForTopicAndAddsIncompleteNodesWithoutChangingParents() {
    #expect(ConversationMindMap.parse("主", isDraft: true) == nil)
    #expect(ConversationMindMap.parse("主题：", isDraft: true) == nil)
    let early = ConversationMindMap.parse("主题：幸福\n- 关系\n  -", isDraft: true)
    #expect(early?.topic == "幸福")
    #expect(early?.branches.count == 1)
    #expect(early?.branches[0].points.isEmpty == true)
    let next = ConversationMindMap.parse("主题：幸福\n- 关系\n  - 住房条件\n- 不同看法\n  - 仍在讨论", isDraft: true)
    #expect(next?.branches[0].points == ["住房条件"])
    #expect(next?.branches[1].points == ["仍在讨论"])
}

@Test func mindMapLimitsVisibleNodesWithoutDroppingOverflowFacts() {
    let source = "主题：测试\n" + (0..<9).map { branch in
        "- 话题\(branch)\n" + (0..<5).map { "  - P\(branch).\($0)\n" }.joined()
    }.joined()
    let map = ConversationMindMap.parse(source)!
    #expect(map.branches.count <= 5)
    #expect(map.branches.allSatisfy { $0.points.count <= 3 })
    let displayed = map.branches.flatMap { [$0.title] + $0.points }.joined(separator: "\n")
    for branch in 0..<9 {
        for point in 0..<5 { #expect(displayed.contains("P\(branch).\(point)")) }
    }
}

@Test func nonOutlineSummaryKeepsAllOriginalTextAsReadableFallback() {
    let source = "在聊什么\n软件使用体验。\n\n主要内容\n一个尚未解决的问题。"
    let map = ConversationMindMap.parse(source)
    #expect(map?.branches.first?.points == [source])
}

@Test func mindMapKeepsOrphanProseAndRecognizesMarkdownStarBullets() {
    let prose = ConversationMindMap.parse("主题：发布计划\n先完成测试，再决定上线。")
    #expect(prose?.branches.first?.points == ["先完成测试，再决定上线。"])
    let mixed = ConversationMindMap.parse("主题：发布计划\n暂未决定上线。\n* 测试\n  * 先检查字幕。\n- 发布\n  - 等待结果。")
    #expect(mixed?.branches.map(\.title) == ["对话大意", "测试", "发布"])
    #expect(mixed?.branches.first?.points == ["暂未决定上线。"])
    #expect(mixed?.branches.dropFirst().first?.points == ["先检查字幕。"])
    #expect(mixed?.branches.dropFirst(2).first?.points == ["等待结果。"])
}

@Test @MainActor func summaryStartupTimeoutIsDistinctAndStopsItsWorker() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SummaryWorkerTimeout.\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("llama-server")
    try "#!/bin/sh\nexec /bin/sleep 5\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let model = folder.appendingPathComponent("model.gguf")
    try Data([1]).write(to: model)
    let service = LocalSummaryService(assets: .init(executable: executable, model: model), startupTimeout: .milliseconds(20))
    defer { service.cancel() }
    do {
        try await service.prepare()
        Issue.record("An unready worker must time out")
    } catch SummaryError.startupTimedOut {
        // The missing-health path is distinct from worker exit and model absence.
    } catch { Issue.record("Wrong startup error: \(error)") }
}
