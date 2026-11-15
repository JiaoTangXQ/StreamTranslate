import Testing
@testable import StreamTranslate

@Test @MainActor func captionExportHTMLIsReadableAndEscapesTranscriptText() {
    let entry = CaptionEntry(timestamp: Date(timeIntervalSince1970: 0),
        englishText: "A <useful> & precise point", chineseText: "一个清晰的结论")
    let html = ConversationExportService.captionsHTML([entry])

    #expect(html.contains("字幕记录"))
    #expect(html.contains("A &lt;useful&gt; &amp; precise point"))
    #expect(html.contains("一个清晰的结论"))
    #expect(html.contains("@media print"))
    #expect(!html.contains("<useful>"))
}

@Test @MainActor func mindMapExportHTMLIncludesTopicsBranchesAndDetails() throws {
    let batch = SummaryBatch(records: [.init(sourceID: UUID(), text: "方案通过")])
    let map = try ConversationMindMap().adding(
        #"{"topic":"new:1","kind":"discussion","title":"住房政策","branch":"表决","text":"方案通过","detail":"经过表决后正式通过。","sources":[1]}"#,
        batch: batch
    )
    let html = ConversationExportService.mindMapHTML(map)

    #expect(html.contains("住房政策"))
    #expect(html.contains("表决"))
    #expect(html.contains("经过表决后正式通过。"))
    #expect(html.contains("class=\"mind-map\""))
}

@Test @MainActor func currentSessionCaptionsReturnsAllInMemoryRowsForExport() async throws {
    let vm = CaptionViewModel()
    vm.addCaption(english: "First", chinese: "第一")
    vm.addCaption(english: "Second", chinese: "第二")

    let entries = try await vm.currentSessionCaptions()
    #expect(entries.map(\.englishText) == ["First", "Second"])

    vm.clearCurrentSession()
    #expect(try await vm.currentSessionCaptions().isEmpty)
}
