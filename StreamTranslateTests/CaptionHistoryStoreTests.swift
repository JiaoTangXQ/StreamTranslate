import Foundation
import Testing
@testable import StreamTranslate

@Test @MainActor func savedHistorySurvivesRelaunchAndFoldsTranslationUpdates() async throws {
    let directory = historyTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptionHistoryStore(directory: directory)
    let session = UUID()
    let first = CaptionEntry(timestamp: .now, englishText: "First", chineseText: "")
    let next = CaptionEntry(timestamp: .now, englishText: "Second", chineseText: "第二句")
    store.record(first, sessionID: session, startedAt: first.timestamp)
    store.record(next, sessionID: session, startedAt: first.timestamp)
    store.record(CaptionEntry(id: first.id, timestamp: first.timestamp,
        englishText: "First", chineseText: "第一句"), sessionID: session, startedAt: first.timestamp)
    try await store.flush()

    let reopened = CaptionHistoryStore(directory: directory)
    let sessions = try await reopened.sessions()
    #expect(sessions.map(\.id) == [session])
    let captions = try await reopened.captions(in: session)
    #expect(captions.map(\.id) == [first.id, next.id])
    #expect(captions.first?.chineseText == "第一句")
}

@Test @MainActor func clearingSavedHistoryOrdersPendingWritesAndAllowsNewRecording() async throws {
    let directory = historyTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptionHistoryStore(directory: directory)
    let oldSession = UUID()
    for index in 0..<100 {
        store.record(CaptionEntry(timestamp: .now, englishText: "Old \(index)", chineseText: "旧记录"),
            sessionID: oldSession, startedAt: .now)
    }
    try await store.clear()
    #expect(try await store.sessions().isEmpty)
    let newSession = UUID()
    store.record(CaptionEntry(timestamp: .now, englishText: "New", chineseText: "新记录"),
        sessionID: newSession, startedAt: .now)
    #expect(try await store.sessions().map(\.id) == [newSession])
    #expect(try await store.captions(in: oldSession).isEmpty)
}

@Test @MainActor func historyKeepsCompleteLinesAfterAnInterruptedWrite() async throws {
    let directory = historyTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptionHistoryStore(directory: directory)
    let session = UUID()
    store.record(CaptionEntry(timestamp: .now, englishText: "Saved", chineseText: "已保存"),
        sessionID: session, startedAt: .now)
    try await store.flush()
    let journal = directory.appendingPathComponent(session.uuidString).appendingPathComponent("captions.jsonl")
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"id\":".utf8))
    try handle.close()
    #expect(try await store.captions(in: session).map(\.englishText) == ["Saved"])
}

@Test @MainActor func floatingHistoryStopsAt100WhileFullHistoryIsSaved() async throws {
    let directory = historyTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptionHistoryStore(directory: directory)
    let vm = CaptionViewModel(historyStore: store)
    vm.beginCompanionSession()
    for index in 0..<350 { vm.addCaption(english: "Line \(index)", chinese: "第\(index)句") }
    #expect(vm.floatingCaptionHistory.count == 100)
    #expect(vm.captionHistory.count == 100)
    #expect(vm.floatingCaptionHistory.first?.englishText == "Line 250")
    #expect(vm.floatingCaptionHistory.last?.englishText == "Line 349")
    #expect(try await store.captions(in: vm.companionSessionID).count == 350)
    vm.streamingEnglish = "Still speaking"
    #expect(vm.floatingCaptionHistory.count == 99)
    #expect(vm.floatingCaptionHistory.count + 1 == 100)
}

@Test @MainActor func translationOfEvictedCaptionStillUpdatesSavedRecord() async throws {
    let directory = historyTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptionHistoryStore(directory: directory)
    let vm = CaptionViewModel(historyStore: store)
    vm.beginCompanionSession()
    vm.addCaption(english: "The model weights stay the same size.", chinese: "模型重量保持不变。")
    let entry = vm.captionHistory[0]
    let request = FinalTranslationRequest(entryID: entry.id,
        segment: .init(samples: [], startSample: 0, endSample: 16_000),
        output: .init(text: entry.originalText, language: .english, reportedLanguageCode: "en", words: []),
        sourceText: entry.originalText, direction: .englishToChinese,
        generation: 0, queuedAt: .now, logger: nil)
    vm.configureTranslationRefinement(HistoryRefinerStub())
    vm.enqueueTranslationRefinement(request)
    for index in 0..<150 { vm.addCaption(english: "Line \(index)", chinese: "第\(index)句") }
    #expect(!vm.captionHistory.contains(where: { $0.id == entry.id }))
    await vm.waitForFinalTranslations()
    let saved = try await store.captions(in: vm.companionSessionID)
    #expect(saved.count == 151)
    #expect(saved.first?.chineseText == "模型权重大小保持不变。")
    #expect(vm.captionHistory.count == 100)
}

@Test @MainActor func lateTranslationStaysInItsOriginalSavedSession() async throws {
    let directory = historyTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptionHistoryStore(directory: directory)
    let vm = CaptionViewModel(historyStore: store)
    vm.beginCompanionSession()
    let originalSession = vm.companionSessionID
    vm.addCaption(english: "The model weights stay the same size.", chinese: "模型重量保持不变。")
    let entry = vm.captionHistory[0]
    let request = FinalTranslationRequest(entryID: entry.id,
        segment: .init(samples: [], startSample: 0, endSample: 16_000),
        output: .init(text: entry.originalText, language: .english, reportedLanguageCode: "en", words: []),
        sourceText: entry.originalText, direction: .englishToChinese,
        generation: 0, queuedAt: .now, logger: nil)
    vm.configureTranslationRefinement(HistoryRefinerStub())
    vm.enqueueTranslationRefinement(request)
    vm.beginCompanionSession()
    vm.addCaption(english: "Next session", chinese: "下一次")
    await vm.waitForFinalTranslations()
    let old = try await store.captions(in: originalSession)
    let new = try await store.captions(in: vm.companionSessionID)
    #expect(old.count == 1)
    #expect(old.first?.chineseText == "模型权重大小保持不变。")
    #expect(new.map(\.englishText) == ["Next session"])

    vm.enqueueTranslationRefinement(request)
    vm.clearHistory()
    try await store.clear()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(try await store.sessions().isEmpty)
}

@MainActor private final class HistoryRefinerStub: TranslationRefinementProviding {
    var isReady = true
    func translate(_ text: String, sourceLanguage: SpokenLanguage,
        target: TranslationTarget, context: String) async throws -> String {
        try? await Task.sleep(for: .milliseconds(20))
        return "模型权重大小保持不变。"
    }
    func cancel() { isReady = false }
}

private func historyTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("StreamTranslate.history-tests.\(UUID())")
}

@Test @MainActor func damagedSessionIndexDoesNotHideOtherHistoryAndCanBeCleared() async throws {
    let directory = historyTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptionHistoryStore(directory: directory)
    let session = UUID()
    store.record(CaptionEntry(timestamp: .now, englishText: "Kept", chineseText: "保留"),
        sessionID: session, startedAt: .now)
    try await store.flush()
    let broken = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    #expect(try await store.sessions().map(\.id) == [session])
    #expect(store.readWarning != nil)
    #expect(try await store.captions(in: session).first?.englishText == "Kept")
    try await store.clear()
    #expect(try await store.sessions().isEmpty)
    #expect(store.readWarning == nil)
}
