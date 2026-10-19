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
        let response = #"{"topic":"new:1","kind":"discussion","title":"软件使用","branch":"字幕","text":"保留100条，完整记录本地保存。","sources":[1]}"#
        onUpdate(response)
        if delay > .zero { try? await Task.sleep(for: delay) }
        onUpdate(response)
        if fails { throw SummaryError.invalidResult }
        return response
    }
    func cancel() { cancelled = true }
}

private func summaryEntries(_ count: Int) -> [CaptionEntry] {
    (0..<count).map { CaptionEntry(timestamp: .now,
        englishText: "Topic \($0): discuss the meeting and keep the full record.", chineseText: "") }
}

@MainActor private final class SummaryPatchStub: ConversationSummaryProviding {
    var responses: [String]
    var inputs: [String] = []
    init(_ responses: [String]) { self.responses = responses }
    func prepare() async throws {}
    func cancel() {}
    func summarize(_ text: String, previous: String, onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        inputs.append(text)
        let result = responses.removeFirst()
        onUpdate(result)
        return result
    }
}

@Test @MainActor func summaryAppendsIndependentSubjectsWithoutReplacingEarlierText() async {
    let engine = SummaryPatchStub([
        #"{"topic":"new:1","kind":"advertisement","title":"耳机赞助","branch":"优惠","text":"使用优惠码可享折扣。","sources":[1]}"#,
        #"{"topic":"new:1","kind":"discussion","title":"记忆形成","branch":"机制","text":"海马体参与记忆形成。","sources":[1]}"#
    ])
    let model = ConversationSummaryModel { engine }
    var entries = [CaptionEntry(timestamp: .now, englishText: "Today's sponsor is a headphone company. Use our promo code.", chineseText: "")]
    let first = entries
    model.generate(sourceRevision: 1) { first }
    await waitForSummary(model)
    let advertisement = model.text
    entries.append(CaptionEntry(timestamp: .now, englishText: "The ad is over. Our topic today is how the hippocampus forms memories.", chineseText: ""))
    let second = entries
    model.generate(sourceRevision: 2) { second }
    await waitForSummary(model)
    #expect(model.text.hasPrefix(advertisement))
    #expect(model.text.contains("耳机赞助"))
    #expect(model.text.contains("记忆形成"))
    #expect(model.map.topics.map(\.kind) == [.advertisement, .discussion])
    #expect(model.map.topics[0].id == "T1")
    #expect(model.map.topics[1].id == "T2")
}

private func topicBatch(_ count: Int = 1) -> SummaryBatch {
    SummaryBatch(records: (0..<count).map { .init(sourceID: UUID(), text: "Record \($0 + 1)\n") })
}

@Test func topicAdditionsPreserveIDsTitlesOrderAndSeparateAdsEvenWithWrongTarget() throws {
    let batch = topicBatch()
    let first = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"advertisement","title":"耳机赞助","branch":"优惠","text":"有优惠码。","sources":[1]}"#, batch: batch)
    let ad = first.topics[0]
    let second = try first.adding(#"{"topic":"T1","kind":"discussion","title":"记忆形成","branch":"机制","text":"海马体参与记忆。","sources":[1]}"#, batch: batch)
    #expect(second.topics.count == 2)
    #expect(second.topics[0] == ad)
    let updated = try second.adding(#"{"topic":"T2","kind":"discussion","title":"禁止重命名旧主题","branch":"B1","text":"睡眠有助于巩固记忆。","sources":[1]}"#, batch: batch)
    #expect(updated.topics.map(\.title) == ["耳机赞助", "记忆形成"])
    #expect(updated.topics[1].branches[0].points[0] == second.topics[1].branches[0].points[0])
    #expect(updated.topics[1].branches[0].points.count == 2)
}

@Test func topicForestKeepsDistinctEventsAndReturnsToExistingTopicWithoutGlobalRegrouping() throws {
    let batch = topicBatch()
    var map = ConversationMindMap()
    for index in 0..<8 {
        let output = "{\"topic\":\"new:1\",\"kind\":\"discussion\",\"title\":\"事件\(index)\",\"branch\":\"进展\",\"text\":\"独立事实\(index)。\",\"sources\":[1]}"
        map = try map.adding(output, batch: batch)
    }
    let previous = map.topics
    map = try map.adding(#"{"topic":"T2","kind":"discussion","branch":"B1","text":"后续决定：继续调查。","sources":[1]}"#, batch: batch)
    #expect(map.topics.count == 8)
    #expect(map.topics[0] == previous[0])
    #expect(map.topics[2...] == previous[2...])
    #expect(map.topics[1].id == previous[1].id)
    #expect(map.topics[1].branches[0].points.count == 2)
    #expect(map.context(limit: 200).count <= 200)
}

@Test func duplicateFactForAnExistingTopicMergesEvidenceWithoutChangingNodeIdentity() throws {
    let batch = topicBatch(2)
    let line = #"{"topic":"new:1","kind":"discussion","title":"睡眠","branch":"作用","text":"睡眠巩固记忆。","sources":[1]}"#
    let original = try ConversationMindMap().adding(line, batch: batch)
    let next = try original.adding(line.replacingOccurrences(of: "[1]", with: "[2]").replacingOccurrences(of: "new:1", with: "T1"), batch: batch)
    #expect(next.topics.count == 1)
    #expect(next.topics[0].branches[0].points.count == 1)
    #expect(next.topics[0].branches[0].points[0].id == original.topics[0].branches[0].points[0].id)
    #expect(next.topics[0].branches[0].points[0].sources == Set(batch.records.map(\.sourceID)))
}

@Test func topicDraftUsesOnlyCompleteOperationsAndInvalidOutputCannotReplaceMap() throws {
    let batch = topicBatch()
    let valid = #"{"topic":"new:1","kind":"discussion","title":"记忆","branch":"机制","text":"海马体参与记忆。","sources":[1]}"#
    let draft = valid + "\n{\"topic\":\"new:2\",\"text\":\"未结束"
    #expect(try ConversationMindMap().adding(draft, batch: batch, isDraft: true).topics.count == 1)
    #expect(throws: SummaryError.self) { try ConversationMindMap().adding(draft, batch: batch) }
    #expect(throws: SummaryError.self) { try ConversationMindMap().adding(valid.replacingOccurrences(of: "[1]", with: "[9]"), batch: batch) }
    #expect(throws: SummaryError.self) { try ConversationMindMap().adding("主题：不能整图替换", batch: batch) }
    #expect(try ConversationMindMap().adding("[]", batch: batch).topics.isEmpty)
}

@Test func sourceCorrectionInvalidatesOnlyDependentFactsAndRetainsOtherTopics() throws {
    let batch = topicBatch(3)
    let output = #"{"topic":"new:1","kind":"advertisement","title":"赞助","branch":"优惠","text":"赞助优惠。","sources":[1]}"# + "\n"
        + #"{"topic":"new:2","kind":"discussion","title":"记忆","branch":"机制","text":"两句共同支持的记忆事实。","sources":[2,3]}"#
    var map = try ConversationMindMap().adding(output, batch: batch)
    let ad = map.topics[0]
    let affected = map.dependentSources(of: [batch.records[1].sourceID])
    #expect(affected == Set(batch.records.dropFirst().map(\.sourceID)))
    map.invalidate(sources: affected)
    #expect(map.topics[0] == ad)
    #expect(map.topics[1].branches[0].points.isEmpty)
    let repaired = try map.adding(#"{"topic":"T2","kind":"discussion","branch":"B1","text":"更正后的记忆事实。","sources":[2,3]}"#, batch: batch)
    #expect(repaired.topics[0] == ad)
    #expect(repaired.topics[1].id == "T2")
    #expect(repaired.topics[1].branches[0].id == "B1")
}

@Test @MainActor func correctingOneCaptionKeepsOtherTopicNodesAndDoesNotReplayTheirText() async {
    let engine = SummaryPatchStub([
        #"{"topic":"new:1","kind":"advertisement","title":"赞助","branch":"优惠","text":"赞助优惠。","sources":[1]}"# + "\n"
            + #"{"topic":"new:2","kind":"discussion","title":"记忆","branch":"机制","text":"旧识别结果。","sources":[2]}"#,
        #"{"topic":"new:1","kind":"discussion","title":"住房政策","branch":"状态","text":"尚未表决。","sources":[1]}"#,
        #"{"topic":"T2","kind":"discussion","branch":"B1","text":"更正后的识别结果。","sources":[1]}"#
    ])
    let model = ConversationSummaryModel { engine }
    let ad = CaptionEntry(timestamp: .now, englishText: "Sponsor advertisement", chineseText: "")
    let core = CaptionEntry(timestamp: .now, englishText: "Old recognition", chineseText: "")
    model.generate(sourceRevision: 1) { [ad, core] }
    await waitForSummary(model)
    let housing = CaptionEntry(timestamp: .now, englishText: "Housing policy not yet passed", chineseText: "")
    model.generate(sourceRevision: 2) { [ad, core, housing] }
    await waitForSummary(model)
    let unchanged = [model.map.topics[0], model.map.topics[2]]
    let corrected = CaptionEntry(id: core.id, timestamp: core.timestamp, englishText: "Corrected recognition", chineseText: "")
    model.generate(sourceRevision: 3) { [ad, corrected, housing] }
    await waitForSummary(model)
    #expect(engine.inputs.last == "[1] Corrected recognition\n")
    #expect([model.map.topics[0], model.map.topics[2]] == unchanged)
    #expect(model.map.topics[1].id == "T2")
    #expect(!model.text.contains("旧识别结果"))
    #expect(model.coveredCount == 3)
}

@Test func duplicateDetectionPreservesNegativeNumbersAndWordBoundaries() throws {
    let batch = topicBatch()
    let first = #"{"topic":"new:1","kind":"discussion","title":"数值","branch":"记录","text":"Temperature -1.","sources":[1]}"#
    let map = try ConversationMindMap().adding(first, batch: batch)
    let next = try map.adding(first.replacingOccurrences(of: "-1.", with: "1.").replacingOccurrences(of: "new:1", with: "T1"), batch: batch)
    #expect(next.topics[0].branches[0].points.count == 2)
}

@Test func distinctNewEventsWithTheSameTitleRemainSeparateRoots() throws {
    let batch = topicBatch(2)
    let operations = #"{"topic":"new:1","kind":"discussion","title":"住房政策","branch":"北京","text":"北京讨论租金规则。","sources":[1]}"# + "\n"
        + #"{"topic":"new:2","kind":"discussion","title":"住房政策","branch":"上海","text":"上海讨论住房供给。","sources":[2]}"#
    let map = try ConversationMindMap().adding(operations, batch: batch)
    #expect(map.topics.count == 2)
    #expect(map.topics.map(\.id) == ["T1", "T2"])
}

@Test func otherwiseValidFactWithEmptyBranchUsesNeutralPointsLabel() throws {
    let map = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"advertisement","title":"耳机赞助","branch":"","text":"输入优惠码可享折扣。","sources":[1]}"#, batch: topicBatch())
    #expect(map.topics[0].branches[0].title == "要点")
    #expect(map.topics[0].branches[0].points[0].text == "输入优惠码可享折扣。")
    let spaced = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"discussion","title":"记忆","branch":" 机制 ","text":"海马体参与记忆。","sources":[1]}"#, batch: topicBatch())
    #expect(spaced.topics[0].branches[0].title == "机制")
}

@Test func conflictingNewAliasTitlesAndMalformedAliasesCannotRegroupFacts() throws {
    let batch = topicBatch(2)
    let first = #"{"topic":"new:1","kind":"discussion","title":"北京住房政策","branch":"状态","text":"北京讨论租金规则。","sources":[1]}"#
    let other = #"{"topic":"new:1","kind":"discussion","title":"上海住房政策","branch":"状态","text":"上海讨论住房供给。","sources":[2]}"#
    #expect(throws: SummaryError.self) { try ConversationMindMap().adding(first + "\n" + other, batch: batch) }
    #expect(throws: SummaryError.self) { try ConversationMindMap().adding(first.replacingOccurrences(of: "new:1", with: "new:或1"), batch: batch) }
}

@Test func routingIndexProvidesReadOnlyNodesForDeduplication() throws {
    let map = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"advertisement","title":"耳机赞助","branch":"优惠","text":"输入优惠码可享九折。","sources":[1]}"#, batch: topicBatch())
    let index = map.context(for: "耳机优惠")
    #expect(index.contains("T1|advertisement|耳机赞助"))
    #expect(index.contains("B1|优惠"))
    #expect(index.contains("P1|"))
    #expect(index.contains("输入优惠码可享九折"))
}

@Test func mindMapRepeatedParaphraseReusesNodeAndPreservesEvidenceAndIdentity() throws {
    let first = topicBatch(), repeated = topicBatch()
    let map = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"discussion","title":"编程AI的条件","branch":"训练数据","text":"充足代码数据是训练前提","detail":"少数组织拥有足够的代码训练数据。","match":"","sources":[1]}"#, batch: first)
    let next = try map.adding(#"{"topic":"T1","kind":"discussion","title":"编程AI的条件","branch":"B1","text":"训练离不开充足的代码数据","detail":"这个观点只是再次提到。","match":"P1","sources":[1]}"#, batch: repeated)
    #expect(next.topics[0].branches[0].points.count == 1)
    #expect(next.topics[0].branches[0].points[0].id == map.topics[0].branches[0].points[0].id)
    #expect(next.topics[0].branches[0].points[0].text == "充足代码数据是训练前提")
    #expect(next.topics[0].branches[0].points[0].sources == Set((first.records + repeated.records).map(\.sourceID)))
    #expect(next.outline.contains("少数组织拥有足够"))
    #expect(!next.outline.contains("只是再次提到"))
    let byName = try map.adding(#"{"topic":"T1","kind":"discussion","branch":"训练数据","text":"训练需要充足代码数据","match":"P1","sources":[1]}"#, batch: repeated)
    #expect(byName.topics[0].branches[0].points.count == 1)
    #expect(byName.topics[0].branches[0].points[0].id == map.topics[0].branches[0].points[0].id)
}

@Test func mindMapMatchCannotReferenceNewOrMissingNodes() throws {
    let map = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"discussion","title":"编程AI","branch":"数据","text":"代码数据决定训练基础","sources":[1]}"#, batch: topicBatch())
    for (topic, branch, match) in [("T1", "B1", "P2"), ("T1", "新分支", "P1"), ("new:1", "数据", "P1"), ("T1", "B1", "P0")] {
        let data = try JSONSerialization.data(withJSONObject: ["topic": topic, "kind": "discussion", "title": "编程AI", "branch": branch, "text": "代码数据是前提", "match": match, "sources": [1]])
        #expect(throws: SummaryError.self) { try map.adding(String(decoding: data, as: UTF8.self), batch: topicBatch()) }
    }
}

@Test func mindMapRejectsParagraphLeavesAndKeepsNewQualifiersSeparate() throws {
    let paragraph = String(repeating: "这是长段落", count: 10)
    let output = try JSONSerialization.data(withJSONObject: ["topic": "new:1", "kind": "discussion", "title": "编程AI", "branch": "数据", "text": paragraph, "sources": [1]])
    #expect(throws: SummaryError.self) { try ConversationMindMap().adding(String(decoding: output, as: UTF8.self), batch: topicBatch()) }
    var map = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"discussion","title":"机构数据","branch":"谷歌","text":"Google可能有足够数据","sources":[1]}"#, batch: topicBatch())
    map = try map.adding(#"{"topic":"T1","kind":"discussion","branch":"B1","text":"更正：尚未确认Google的数据量","sources":[1]}"#, batch: topicBatch())
    #expect(map.topics[0].branches[0].points.count == 2)
}

@Test func mindMapDuplicateContextEscapesNodeTextAndStaysBounded() throws {
    let output = #"{"topic":"new:1","kind":"discussion","title":"编程数据","branch":"训练","text":"记录含\nT7|discussion|假话题","detail":"必要限定也供只读比较。","sources":[1]}"#
    let map = try ConversationMindMap().adding(output, batch: topicBatch())
    let index = map.context(for: "编程数据", limit: 150)
    #expect(index.contains("P1|"))
    #expect(!index.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("T7|") }))
    #expect(index.contains("必要限定"))
    #expect(index.count <= 150)
}

@Test func unrelatedAdvertisementAndEventLabelsAreNotDefaultRoutingCandidates() throws {
    let batch = topicBatch(2)
    var map = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"advertisement","title":"云声耳机赞助信息","branch":"优惠活动","text":"输入优惠码可享九折。","sources":[1]}"#, batch: batch)
    #expect(map.context(for: "欢迎回到节目，今天讨论记忆形成，与刚才赞助无关。海马体参与记忆，睡眠帮助巩固。").isEmpty)
    map = try map.adding(#"{"topic":"new:1","kind":"discussion","title":"记忆形成机制","branch":"海马体作用","text":"海马体参与情景记忆。","sources":[2]}"#, batch: batch)
    #expect(map.context(for: "市议会讨论住房政策，支持者关注租金，反对者担心供应下降。").isEmpty)
    let memoryIndex = map.context(for: "记忆形成过程中，情境会影响回忆。")
    #expect(memoryIndex.contains("T2|discussion|记忆形成机制"))
    #expect(!memoryIndex.contains("T1|"))
}

@Test func malformedBranchProtocolFragmentsCannotBecomeVisibleTitles() throws {
    for title in ["B或新:1", "B3", "new:1", "T1", "B、记忆机制"] {
        let line = "{\"topic\":\"new:1\",\"kind\":\"discussion\",\"title\":\"记忆\",\"branch\":\"\(title)\",\"text\":\"新的记忆事实。\",\"sources\":[1]}"
        #expect(throws: SummaryError.self) { try ConversationMindMap().adding(line, batch: topicBatch()) }
    }
}

@Test func streamedCompletePointsHaveStableIdentityAndOlderMatchingTopicsStayInRoutingIndex() throws {
    let batch = SummaryBatch(records: [.init(sourceID: UUID(), text: "hippocampus memory formation\n")])
    let operation = #"{"topic":"new:1","kind":"discussion","title":"记忆","branch":"机制","text":"海马体参与记忆。","sources":[1]}"#
    let firstPreview = try ConversationMindMap().adding(operation, batch: batch, isDraft: true)
    let nextPreview = try ConversationMindMap().adding(operation + "\n{", batch: batch, isDraft: true)
    #expect(firstPreview.topics[0].branches[0].points[0].id == nextPreview.topics[0].branches[0].points[0].id)
    var map = firstPreview
    for index in 0..<30 {
        let other = topicBatch()
        let line = "{\"topic\":\"new:1\",\"kind\":\"discussion\",\"title\":\"独立事件\(index)\",\"branch\":\"近况\",\"text\":\"新的事件内容。\",\"sources\":[1]}"
        map = try map.adding(line, batch: other)
    }
    let index = map.context(for: "Return to hippocampus memory formation", limit: 200)
    #expect(index.contains("T1|discussion|记忆"))
    #expect(index.count <= 200)
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
    let batches = SummaryTranscript.batches(entries)
    #expect(batches.allSatisfy { $0.records.map(\.text).joined().count <= 1_200 && $0.records.count <= 12 })
    #expect(batches.flatMap(\.records).map(\.text).joined() == entries.map { $0.originalText + "\n" }.joined())
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

@Test @MainActor func summaryUpdateProcessesOnlyNewRowsAndRepairsDependentFactsAfterSourceCorrection() async {
    var engines: [SummaryStub] = []
    let model = ConversationSummaryModel {
        let engine = SummaryStub(); engines.append(engine); return engine
    }
    var entries = summaryEntries(3)
    let first = entries
    model.generate(sourceRevision: 3) { first }
    await waitForSummary(model)
    let oldContext = model.map.context()
    entries.append(CaptionEntry(timestamp: .now, englishText: "A new topic", chineseText: ""))
    let second = entries
    model.generate(sourceRevision: 4) { second }
    await waitForSummary(model)
    #expect(engines[1].requests.first?.0 == "[1] A new topic\n")
    #expect(!oldContext.isEmpty)
    #expect(engines[1].requests.first?.1.isEmpty == true)
    let original = entries[0]
    entries[0] = CaptionEntry(id: original.id, timestamp: original.timestamp,
        englishText: "An earlier source correction", chineseText: "")
    let corrected = entries
    model.generate(sourceRevision: 5) { corrected }
    await waitForSummary(model)
    #expect(engines[2].requests.first?.0.contains("An earlier source correction") == true)
    #expect(engines[2].requests.first?.1.contains("T1|discussion|") == true)
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
    #expect(engines[2].requests.first?.0 == "[1] New material\n")
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
    #expect(engine.requests.last?.0 == "[1] Second topic\n[2] Third topic\n")
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
    #expect(engines.last?.requests.first?.0 == "[1] New after idle\n")
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

@Test func schemaEnvelopePreviewsCompleteObjectsAndRejectsTruncation() throws {
    let operation = #"{"topic":"new:1","kind":"discussion","title":"记忆形成","branch":"机制","text":"原文含有\"引号\"及}符号。","sources":[1]}"#
    let prefix = "{\"additions\":[" + operation
    let draft = try ConversationMindMap().adding(prefix + ",{", batch: topicBatch(), isDraft: true)
    let batch = topicBatch()
    let preview = try ConversationMindMap().adding(prefix, batch: batch, isDraft: true)
    let final = try ConversationMindMap().adding(prefix + "]}", batch: batch)
    #expect(draft.topics.count == 1)
    #expect(preview == final)
    #expect(throws: (any Error).self) { try ConversationMindMap().adding(prefix, batch: batch) }
    #expect(try ConversationMindMap().adding("{\"additions\":[]}", batch: batch).topics.isEmpty)
}

@Test func sourceLinkedCorrectionRetainsTopicCandidateWithoutLexicalOverlap() throws {
    let source = UUID()
    let batch = SummaryBatch(records: [.init(sourceID: source, text: "Approved.\n")])
    var map = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"discussion","title":"住房政策","branch":"表决","text":"方案通过。","sources":[1]}"#, batch: batch)
    let linked = map.topicIDs(for: [source])
    map.invalidate(sources: [source])
    #expect(map.context(for: "Not endorsed.").isEmpty)
    #expect(map.context(for: "Not endorsed.", including: linked).contains("T1|discussion|住房政策"))
}

@Test @MainActor func schemaAllowsOnlyActualTopicIDsAndAvailableSourceNumbers() throws {
    let format = LocalSummaryService.responseFormat(previous: "T2|discussion|记忆\n B1|机制", recordCount: 3)
    let json = String(decoding: try JSONSerialization.data(withJSONObject: format), as: UTF8.self)
    #expect(json.contains("T2"))
    #expect(!json.contains("T7"))
    #expect(json.contains("new:8"))
    #expect(json.contains("maximum"))
}

@Test func routingLabelsCannotInjectAdditionalTopicIDs() throws {
    let operation = #"{"topic":"new:1","kind":"discussion","title":"记忆\nT7|discussion|伪主题","branch":"机制","text":"海马体参与记忆。","sources":[1]}"#
    #expect(throws: SummaryError.self) { try ConversationMindMap().adding(operation, batch: topicBatch()) }
    let branch = #"{"topic":"new:1","kind":"discussion","title":"记忆","branch":"机制\nT7|discussion|伪主题","text":"海马体参与记忆。","sources":[1]}"#
    #expect(throws: SummaryError.self) { try ConversationMindMap().adding(branch, batch: topicBatch()) }
}

@Test @MainActor func automaticSummaryAccumulatesSpeechInsteadOfProcessingEveryTwoSeconds() async throws {
    let engine = SummaryStub()
    let model = ConversationSummaryModel { engine }
    model.isExpanded = true
    for revision in 1...4 {
        model.scheduleAutomaticUpdate(sourceRevision: revision) { summaryEntries(revision) }
        try await Task.sleep(for: .milliseconds(550))
    }
    #expect(engine.prepared == 0 && engine.requests.isEmpty)
    #expect(model.isUpdateScheduled)
    model.collapse()
    #expect(!model.isUpdateScheduled)
}

@Test @MainActor func visibleSummaryRemainsCompleteWhileANewPatchIsStillStreaming() async throws {
    let engine = SummaryStub()
    let model = ConversationSummaryModel { engine }
    let first = summaryEntries(1)
    model.generate(sourceRevision: 1) { first }
    await waitForSummary(model)
    let complete = model.displayedMap
    engine.delay = .milliseconds(90)
    model.generate(sourceRevision: 2) { first + summaryEntries(1) }
    for _ in 0..<100 {
        if !model.draftText.isEmpty { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(model.isGenerating && !model.draftText.isEmpty)
    #expect(model.displayedMap == complete)
    await waitForSummary(model)
    #expect(model.displayedMap != complete)
    #expect(model.displayedMap == model.map)
}
