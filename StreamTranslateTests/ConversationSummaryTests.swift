import Foundation
import Testing
@testable import StreamTranslate

// MARK: - Fixtures

private let wide = MindMapLimits.forSession(minutes: 5, local: false)

private func revision(_ topics: [[String: Any]], remove: [String] = []) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["topics": topics, "remove": remove]), as: UTF8.self)
}

private func topic(_ id: String, _ title: String, summary: String = "", kind: String = "discussion",
                   _ branches: [(String, [String])]) -> [String: Any] {
    ["id": id, "kind": kind, "title": title, "summary": summary,
     "branches": branches.map { ["title": $0.0, "points": $0.1.map { ["text": $0, "detail": ""] }] }]
}

/// Responds with one topic that keeps the existing T1 when the map has one,
/// so repeated updates rewrite instead of append.
@MainActor private final class MapStub: ConversationSummaryProviding {
    var prepared = 0
    var cancelled = false
    var requests: [MindMapRequest] = []
    var fails = false
    var delay: Duration = .zero
    var budget = 6_000
    var local = false
    var activeRequests = 0
    var maximumActiveRequests = 0
    var inputBudget: Int { budget }
    var usesLocalModel: Bool { local }
    var backendDescription: String { "AI 脑图 · 测试" }
    func prepare() async throws { prepared += 1 }
    func summarize(_ request: MindMapRequest, onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        requests.append(request)
        activeRequests += 1; maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }
        onUpdate("{\"topics\":[")
        if delay > .zero { try? await Task.sleep(for: delay) }
        if fails { throw SummaryError.invalidResult }
        let id = request.map.contains("\"id\":\"T1\"") ? "T1" : ""
        let last = request.newText.components(separatedBy: "\n").last ?? ""
        return revision([topic(id, "会议记录", summary: "第\(requests.count)次整理",
                               [("内容", [String(last.prefix(30))])])])
    }
    func cancel() { cancelled = true }
}

private func entries(_ texts: [String]) -> [CaptionEntry] {
    texts.map { CaptionEntry(timestamp: .now, englishText: $0, chineseText: "") }
}

@MainActor private func waitUntilIdle(_ model: ConversationSummaryModel, timeout: Int = 800) async {
    for _ in 0..<timeout {
        if !model.isGenerating && !model.isUpdateScheduled { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Mind map did not settle")
}

@MainActor private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Revisions

@Test func mindMapRevisionRewritesAContinuingTopicInPlaceAndAppendsNewOnes() throws {
    let first = try ConversationMindMap().applying(revision([
        topic("", "新版发布", [("时间", ["下周发布"])]),
        topic("", "招聘计划", [("岗位", ["招两名后端"])])
    ]), limits: wide)
    #expect(first.map.topics.map(\.id) == ["T1", "T2"])
    #expect(first.changedTopicIDs == ["T1", "T2"])
    // The second half of the release story arrives later and corrects the date.
    let second = try first.map.applying(revision([
        topic("T1", "新版发布", summary: "推迟到月底，先修性能", [("时间", ["推迟到月底发布"]), ("原因", ["性能问题未解决"])]),
        topic("", "预算", [("结论", ["预算不变"])])
    ]), limits: wide)
    #expect(second.map.topics.map(\.id) == ["T1", "T2", "T3"])
    #expect(second.map.topics[0].branches.map(\.title) == ["时间", "原因"])
    #expect(second.map.topics[0].branches[0].points.map(\.text) == ["推迟到月底发布"])
    #expect(second.map.topics[0].summary == "推迟到月底，先修性能")
    // Untouched topics keep their content and identity.
    #expect(second.map.topics[1] == first.map.topics[1])
    #expect(second.changedTopicIDs == ["T1", "T3"])
}

@Test func mindMapMergeKeepsOneIDAndRemovesAbsorbedTopics() throws {
    let start = try ConversationMindMap().applying(revision([
        topic("", "延迟问题", [("现象", ["字幕卡顿"])]),
        topic("", "识别引擎", [("选择", ["Whisper 分段"])]),
        topic("", "午餐", [("安排", ["十二点订餐"])])
    ]), limits: wide).map
    let merged = try start.applying(revision([
        topic("T1", "字幕卡顿与识别引擎", [("原因", ["Whisper 分段重复识别"]), ("方案", ["改用流式识别"])])
    ], remove: ["T2", "T9"]), limits: wide)
    #expect(merged.map.topics.map(\.id) == ["T1", "T3"])
    #expect(merged.map.topics[0].title == "字幕卡顿与识别引擎")
    // A topic that is both rewritten and listed for removal is kept.
    let kept = try merged.map.applying(revision([topic("T3", "午餐", [("安排", ["改到一点"])])], remove: ["T3"]), limits: wide)
    #expect(kept.map.topics.map(\.id) == ["T1", "T3"])
    // Removing topics without rewriting an existing one is not a merge:
    // they are folded into the overview instead of disappearing.
    let bare = try kept.map.applying(revision([topic("", "新话题", [("甲", ["一"])])], remove: ["T1", "T3"]), limits: wide).map
    #expect(bare.topics.map(\.title) == [ConversationMindMap.archiveTitle, "新话题"])
    #expect(bare.topics[0].branches[0].points.count == 2)
}

@Test func mindMapClipsOversizedOutputInsteadOfDiscardingTheUpdate() throws {
    let limits = MindMapLimits(topics: 2, branchesPerTopic: 2, pointsPerBranch: 2)
    let long = String(repeating: "很长的节点", count: 20)
    let result = try ConversationMindMap().applying(revision([
        topic("", "第一个主题", [("甲", [long, "二", "三"]), ("乙", ["一"]), ("丙", ["一"])]),
        topic("", "第二个主题", [("甲", ["一"])]),
        topic("", "第三个主题", [("甲", ["一"])])
    ]), limits: limits).map
    #expect(result.topics.count == 2)
    #expect(result.topics[0].branches.count == 2)
    #expect(result.topics[0].branches[0].points.count == 2)
    let clipped = result.topics[0].branches[0].points[0].text
    #expect(clipped.count == MindMapLimits.pointLength && clipped.hasSuffix("…"))
}

@Test func mindMapBudgetFoldsOldestUntouchedTopicsInsteadOfLosingThem() throws {
    let limits = MindMapLimits(topics: 2, branchesPerTopic: 2, pointsPerBranch: 2)
    let start = try ConversationMindMap().applying(revision([
        topic("", "旧话题", summary: "早先的结论", [("甲", ["一"])]), topic("", "当前话题", [("甲", ["一"])])
    ]), limits: limits).map
    let next = try start.applying(revision([topic("T2", "当前话题", [("甲", ["二"])]), topic("", "新话题", [("甲", ["一"])])]), limits: limits).map
    #expect(next.topics.map(\.title) == [ConversationMindMap.archiveTitle, "当前话题", "新话题"])
    #expect(next.topics[0].branches[0].points.map(\.text) == ["旧话题：早先的结论"])
    // Later overflow adds to the same overview topic.
    let later = try next.applying(revision([topic("", "第三个话题", [("甲", ["一"])])]), limits: limits).map
    #expect(later.topics.map(\.title) == [ConversationMindMap.archiveTitle, "新话题", "第三个话题"])
    #expect(later.topics[0].branches[0].points.count == 2)
    #expect(later.topics.filter { $0.title == ConversationMindMap.archiveTitle }.count == 1)
}

@Test func mindMapRejectsMalformedRevisionsAndAcceptsAnEmptyOne() throws {
    let map = try ConversationMindMap().applying(revision([topic("", "话题", [("甲", ["一"])])]), limits: wide).map
    for bad in ["not json", #"{"remove":[]}"#, #"{"topics":[{"id":"","branches":[]}],"remove":[]}"#] {
        #expect(throws: SummaryError.self) { try map.applying(bad, limits: wide) }
    }
    let unchanged = try map.applying(#"{"topics":[],"remove":[]}"#, limits: wide)
    #expect(unchanged.map == map && unchanged.changedTopicIDs.isEmpty)
    let fenced = try map.applying("```json\n" + revision([topic("T1", "话题", [("甲", ["二"])])]) + "\n```", limits: wide)
    #expect(fenced.map.topics[0].branches[0].points[0].text == "二")
}

@Test func mindMapUnknownOrRepeatedIDsCannotOverwriteAnotherTopic() throws {
    let map = try ConversationMindMap().applying(revision([topic("", "话题甲", [("甲", ["一"])])]), limits: wide).map
    let next = try map.applying(revision([
        topic("T1", "话题甲", [("甲", ["二"])]),
        topic("T1", "冒用编号", [("甲", ["三"])]),
        topic("T7", "未知编号", [("甲", ["四"])])
    ]), limits: wide).map
    #expect(next.topics.map(\.title) == ["话题甲", "冒用编号", "未知编号"])
    #expect(Set(next.topics.map(\.id)).count == 3)
}

@Test func mindMapNodeIdentityIsStableAcrossRewritesOfUnchangedText() throws {
    let first = try ConversationMindMap().applying(revision([topic("", "话题", [("甲", ["保持不变"])])]), limits: wide).map
    let second = try first.applying(revision([topic("T1", "话题", [("甲", ["保持不变", "新增"])])]), limits: wide).map
    #expect(second.topics[0].branches[0].id == first.topics[0].branches[0].id)
    #expect(second.topics[0].branches[0].points[0].id == first.topics[0].branches[0].points[0].id)
}

@Test func mindMapContextCarriesIDsAndFullContentForTheNextRevision() throws {
    let map = try ConversationMindMap().applying(revision([
        topic("", "话题\"引号\"", summary: "一句话", kind: "advertisement", [("甲", ["节点"])])
    ]), limits: wide).map
    let context = try #require(JSONSerialization.jsonObject(with: Data(map.modelContext.utf8)) as? [[String: Any]])
    #expect(context.first?["id"] as? String == "T1")
    #expect(context.first?["title"] as? String == "话题\"引号\"")
    #expect(context.first?["kind"] as? String == "advertisement")
    #expect(map.outline.contains("广告 / 赞助：话题\"引号\""))
}

// MARK: - Cadence and batching

@Test func mindMapCadenceProducesAFirstMapAfterAFewSentences() {
    #expect(MindMapCadence.delay(newCharacters: 30, hasMap: false, paneOpen: false, justOpened: false,
                                 sinceLastUpdate: nil, sessionElapsed: 20) == nil)
    #expect(MindMapCadence.delay(newCharacters: 90, hasMap: false, paneOpen: false, justOpened: false,
                                 sinceLastUpdate: nil, sessionElapsed: 20) == 0)
    // An open pane maps whatever exists instead of waiting for more.
    #expect(MindMapCadence.delay(newCharacters: 30, hasMap: false, paneOpen: true, justOpened: false,
                                 sinceLastUpdate: nil, sessionElapsed: 20) == 0)
    #expect(MindMapCadence.delay(newCharacters: 0, hasMap: false, paneOpen: true, justOpened: true,
                                 sinceLastUpdate: nil, sessionElapsed: 20) == nil)
}

@Test func mindMapCadenceIntervalGrowsWithSessionLengthAndStaysAnchored() {
    #expect(MindMapCadence.interval(sessionElapsed: 60) == 20)
    #expect(MindMapCadence.interval(sessionElapsed: 600) == 50)
    #expect(MindMapCadence.interval(sessionElapsed: 5 * 3_600) == 240)
    // Ten minutes in, 30 s after the last update: 20 s remain.
    #expect(MindMapCadence.delay(newCharacters: 300, hasMap: true, paneOpen: true, justOpened: false,
                                 sinceLastUpdate: 30, sessionElapsed: 600) == 20)
    // A short fragment waits for more text; a burst only waits for the gap.
    #expect(MindMapCadence.delay(newCharacters: 20, hasMap: true, paneOpen: true, justOpened: false,
                                 sinceLastUpdate: 300, sessionElapsed: 600) == nil)
    #expect(MindMapCadence.delay(newCharacters: 3_000, hasMap: true, paneOpen: false, justOpened: false,
                                 sinceLastUpdate: 5, sessionElapsed: 3_600) == 7)
    // Opening the pane refreshes now, but never closer than the minimum gap.
    #expect(MindMapCadence.delay(newCharacters: 50, hasMap: true, paneOpen: true, justOpened: true,
                                 sinceLastUpdate: 100, sessionElapsed: 3_600) == 0)
}

@Test func mindMapLimitsGrowWithSessionLengthAndStaySmallerLocally() {
    #expect(MindMapLimits.forSession(minutes: 10, local: false).topics == 5)
    #expect(MindMapLimits.forSession(minutes: 300, local: false).topics == 12)
    #expect(MindMapLimits.forSession(minutes: 300, local: true).topics == 6)
    #expect(MindMapLimits.forSession(minutes: 300, local: true).pointsPerBranch == 3)
}

@Test func mindMapBatcherCoversEveryCharacterWithinBudget() {
    let long = String(repeating: "长", count: 3_000)
    let rows = entries(["first", long, "last"])
    let fragments = MindMapBatcher.fragments(rows)
    #expect(fragments.map(\.text).joined() == "first" + long + "last")
    #expect(fragments.allSatisfy { $0.text.count < LocalSummaryService.inputBudget })
    #expect(fragments.filter(\.completesSource).map(\.sourceID) == rows.map(\.id))
    var remaining = fragments[...], batches = 0
    while !remaining.isEmpty {
        let batch = MindMapBatcher.batch(remaining, budget: 1_500)
        #expect(batch.reduce(0) { $0 + $1.text.count + 1 } <= 1_500)
        remaining = remaining[batch.endIndex...]; batches += 1
    }
    #expect(batches == 3)
}

// MARK: - Model lifecycle

@MainActor private final class RowSource {
    var rows: [CaptionEntry] = []
}

@Test @MainActor func mindMapStartsFromAnEmptyMapAndANewSessionForgetsIt() async {
    let engine = MapStub()
    let model = ConversationSummaryModel { engine }
    let first = entries(["We will ship next week.", "Then we test performance."])
    model.begin(sessionStartedAt: .now) { first }
    model.requestNow()
    await waitUntilIdle(model)
    #expect(engine.requests.count == 1)
    #expect(engine.requests[0].map == "[]")
    #expect(engine.requests[0].previousTail.isEmpty)
    #expect(engine.requests[0].newText == "We will ship next week.\nThen we test performance.")
    #expect(model.map.topics.map(\.id) == ["T1"])
    let second = entries(["A different meeting."])
    model.begin(sessionStartedAt: .now) { second }
    #expect(!model.map.hasContent)
    model.requestNow()
    await waitUntilIdle(model)
    #expect(engine.requests.last?.map == "[]")
    #expect(engine.requests.last?.newText == "A different meeting.")
}

@Test @MainActor func mindMapRewritesTheSameTopicAcrossUpdatesWithinASession() async {
    let engine = MapStub()
    let model = ConversationSummaryModel(cloudAvailable: { false }) { engine }
    let source = RowSource()
    source.rows = entries(["We will ship next week."])
    model.begin(sessionStartedAt: .now) { source.rows }
    model.isExpanded = true
    model.requestNow()
    await waitUntilIdle(model)
    source.rows += entries(["Actually the release slips to the end of the month."])
    model.requestNow()
    await waitUntilIdle(model)
    #expect(engine.requests.count == 2)
    #expect(engine.requests[1].newText == "Actually the release slips to the end of the month.")
    #expect(engine.requests[1].map.contains("\"id\":\"T1\""))
    #expect(engine.requests[1].previousTail == "We will ship next week.")
    #expect(model.map.topics.map(\.id) == ["T1"])
    #expect(model.map.topics[0].summary == "第2次整理")
    #expect(model.coveredCount == 2)
    #expect(engine.prepared == 1)
}

@Test @MainActor func longBacklogIsCommittedAfterEachRound() async {
    let engine = MapStub(); engine.budget = 60; engine.delay = .milliseconds(30)
    let model = ConversationSummaryModel { engine }
    let rows = entries((0..<6).map { "Sentence number \($0) carries some content." })
    model.begin(sessionStartedAt: .now) { rows }
    model.requestNow()
    await waitFor { model.map.hasContent }
    // The first committed round is visible while later rounds still run.
    #expect(model.isGenerating)
    await waitUntilIdle(model)
    #expect(engine.requests.count == 6)
    #expect(engine.requests.allSatisfy { $0.newText.count <= 60 })
    #expect(model.coveredCount == 6)
}

@Test @MainActor func cloudFailureResendsALargeBatchAtTheLocalBudget() async {
    let cloud = MapStub(); cloud.fails = true
    let local = MapStub(); local.local = true
    let service = AutomaticSummaryService(makeCloud: { cloud }, makeLocal: { local })
    let model = ConversationSummaryModel { service }
    let rows = entries((0..<30).map { "Sentence \($0) " + String(repeating: "x", count: 80) })
    model.begin(sessionStartedAt: .now) { rows }
    model.requestNow()
    await waitUntilIdle(model)
    #expect(cloud.requests.count == 1)
    #expect(cloud.requests[0].newText.count > LocalSummaryService.inputBudget)
    #expect(local.requests.count >= 3)
    #expect(local.requests.allSatisfy { $0.newText.count <= LocalSummaryService.inputBudget })
    #expect(local.requests.allSatisfy { $0.limits == MindMapLimits.forSession(minutes: 0, local: true) })
    #expect(model.coveredCount == 30)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func openPaneUpdatesAutomaticallyOnceThereIsEnoughText() async {
    let engine = MapStub()
    let model = ConversationSummaryModel(cadenceScale: 0.001, cloudAvailable: { false }) { engine }
    let vm = CaptionViewModel(conversationSummary: model)
    vm.addCaption(english: "Hello there.", chinese: "")
    try? await Task.sleep(for: .milliseconds(40))
    #expect(engine.requests.isEmpty)   // pane closed and no background provider
    vm.expandConversationSummary()
    await waitFor { !engine.requests.isEmpty }
    await waitUntilIdle(model)
    #expect(engine.requests.count == 1)
    vm.addCaption(english: "Short.", chinese: "")
    try? await Task.sleep(for: .milliseconds(60))
    #expect(engine.requests.count == 1)   // fragments wait for more text
    vm.addCaption(english: "Now a longer sentence that clearly carries new information.", chinese: "")
    await waitFor { engine.requests.count == 2 }
    await waitUntilIdle(model)
    #expect(engine.requests.count == 2)
    #expect(engine.requests[1].newText.hasPrefix("Short."))
    #expect(engine.maximumActiveRequests == 1)
    model.collapse()
    #expect(engine.cancelled)
}

@Test @MainActor func backgroundUpdatesNeedACloudProviderAndKeepRunningWhenThePaneCloses() async {
    let sentence = "Background speech " + String(repeating: "with content ", count: 8)
    for cloud in [false, true] {
        let engine = MapStub()
        let model = ConversationSummaryModel(cadenceScale: 0.001, cloudAvailable: { cloud }) { engine }
        let vm = CaptionViewModel(conversationSummary: model)
        model.backgroundUpdatesRequested = true
        #expect(model.isActive == cloud)
        vm.addCaption(english: sentence, chinese: "")
        if cloud { await waitFor { !engine.requests.isEmpty } } else { try? await Task.sleep(for: .milliseconds(60)) }
        await waitUntilIdle(model)
        #expect(engine.requests.count == (cloud ? 1 : 0))
        #expect(model.map.hasContent == cloud)
        // Closing the pane leaves background cloud work in place.
        model.collapse()
        #expect(!engine.cancelled)
        model.backgroundUpdatesRequested = false
    }
}

@Test @MainActor func pauseCancelsWorkAndResumeMapsThePendingText() async {
    let engine = MapStub(); engine.delay = .milliseconds(80)
    let model = ConversationSummaryModel(cadenceScale: 0.001, cloudAvailable: { false }) { engine }
    let vm = CaptionViewModel(conversationSummary: model)
    vm.addCaption(english: "First topic with enough words to start the very first map.", chinese: "")
    vm.expandConversationSummary()
    await waitFor { !engine.requests.isEmpty }
    model.pauseAutomaticUpdates()
    vm.addCaption(english: "A sentence spoken while paused, long enough to count as new.", chinese: "")
    try? await Task.sleep(for: .milliseconds(120))
    #expect(!model.map.hasContent)
    #expect(!model.isGenerating && !model.isUpdateScheduled && !model.isAutoUpdating)
    vm.resumeConversationSummary()
    await waitFor { model.map.hasContent }
    await waitUntilIdle(model)
    #expect(model.coveredCount == 2)
    model.collapse()
}

@Test @MainActor func failurePausesAutomaticUpdatesAndRetrySendsTheSameText() async {
    let engine = MapStub(); engine.fails = true
    let model = ConversationSummaryModel(cadenceScale: 0.001, cloudAvailable: { false }) { engine }
    let vm = CaptionViewModel(conversationSummary: model)
    vm.addCaption(english: "Something worth mapping, with enough characters to begin.", chinese: "")
    vm.expandConversationSummary()
    await waitFor { model.errorMessage != nil }
    #expect(!model.isAutoUpdating)
    vm.addCaption(english: "More speech arrives after the failure and must not retry by itself.", chinese: "")
    try? await Task.sleep(for: .milliseconds(60))
    #expect(engine.requests.count == 1)
    engine.fails = false
    vm.resumeConversationSummary()
    await waitFor { model.map.hasContent }
    await waitUntilIdle(model)
    #expect(engine.requests.last?.newText.contains("Something worth mapping") == true)
    #expect(model.coveredCount == 2 && model.errorMessage == nil)
    model.collapse()
}

@Test @MainActor func clearingOrCollapsingRejectsALateResultEvenIfTheBackendIgnoresCancellation() async {
    for clear in [false, true] {
        let engine = MapStub(); engine.delay = .milliseconds(60)
        let model = ConversationSummaryModel(cloudAvailable: { false }) { engine }
        let rows = entries(["Content"])
        model.begin(sessionStartedAt: .now) { rows }
        model.isExpanded = true
        model.requestNow()
        await waitFor { !engine.requests.isEmpty }
        if clear { model.reset() } else { model.collapse() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!model.map.hasContent)
        #expect(!model.isGenerating)
        #expect(engine.cancelled)
    }
}

@Test @MainActor func idleLocalWorkerIsReleasedAndOnlyNewTextIsSentAfterwards() async {
    var engines: [MapStub] = []
    let model = ConversationSummaryModel(idleTimeout: .milliseconds(20), cadenceScale: 0.001, cloudAvailable: { false }) {
        let engine = MapStub(); engines.append(engine); return engine
    }
    let vm = CaptionViewModel(conversationSummary: model)
    vm.addCaption(english: "First sentence that has enough characters to map.", chinese: "")
    vm.expandConversationSummary()
    await waitFor { model.map.hasContent }
    await waitUntilIdle(model)
    try? await Task.sleep(for: .milliseconds(60))
    #expect(engines.first?.cancelled == true)
    vm.addCaption(english: "New after idle, again with enough characters to count.", chinese: "")
    await waitFor { engines.count == 2 && !(engines.last?.requests.isEmpty ?? true) }
    await waitUntilIdle(model)
    #expect(engines.last?.requests.first?.newText == "New after idle, again with enough characters to count.")
    model.collapse()
}

@Test @MainActor func mindMapReadsTheFullSavedSessionBeyondTheLiveCaptionCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SummaryHistory.\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptionHistoryStore(directory: directory)
    let engine = MapStub()
    let summary = ConversationSummaryModel(cloudAvailable: { false }) { engine }
    let vm = CaptionViewModel(historyStore: store, conversationSummary: summary)
    vm.addCaption(english: "Previous conversation must be excluded", chinese: "")
    vm.beginCompanionSession()
    for index in 0..<150 { vm.addCaption(english: "Line \(index)", chinese: "") }
    #expect(vm.captionHistory.count == 100)
    #expect(try await store.captions(in: vm.companionSessionID).count == 150)
    vm.requestConversationSummary()
    await waitUntilIdle(summary)
    #expect(summary.coveredCount == 150)
    let input = engine.requests.map(\.newText).joined(separator: "\n")
    #expect(input.contains("Line 0\n"))
    #expect(input.contains("Line 149"))
    #expect(!input.contains("Previous conversation"))
    vm.clearHistory()
    #expect(!vm.conversationSummary.map.hasContent)
}

// MARK: - Providers

@Test @MainActor func mindMapPromptAsksForMergingAndStatesTheLimits() {
    let limits = MindMapLimits(topics: 9, branchesPerTopic: 4, pointsPerBranch: 3)
    let messages = MindMapPrompt.messages(MindMapRequest(map: "[]", previousTail: "上一句",
        newText: "新的记录", limits: limits, sessionMinutes: 75))
    #expect(messages.count == 2)
    #expect(messages[0]["content"]?.contains("最多9个主题") == true)
    #expect(messages[0]["content"]?.contains("最多3个节点") == true)
    #expect(messages[0]["content"]?.contains("沿用原id") == true)
    #expect(messages[0]["content"]?.contains("remove") == true)
    #expect(messages[1]["content"]?.contains("上一句") == true)
    #expect(messages[1]["content"]?.contains("新的记录") == true)
    #expect(messages[1]["content"]?.contains("75分钟") == true)
    let format = MindMapPrompt.responseFormat(limits: limits)
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: format, options: [.sortedKeys]), as: UTF8.self)
    #expect(json.contains("\"maxItems\":9"))
    #expect(json.contains("\"maxItems\":3"))
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
