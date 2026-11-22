import Foundation
import Testing
@testable import StreamTranslate

/// Builds a recognizer result whose tokens are spread evenly over its range.
private func result(_ tokens: [String], _ start: Double, _ end: Double,
                    final: Bool = false, confidence: Double? = nil) -> AppleRecognitionResult {
    let first = Int64(start * 16_000), last = Int64(end * 16_000)
    let step = tokens.isEmpty ? 0 : (last - first) / Int64(tokens.count)
    let runs = tokens.enumerated().map { index, text in
        AppleRecognitionResult.Run(text: text, startSample: first + Int64(index) * step,
            endSample: first + Int64(index + 1) * step, confidence: final ? confidence : nil)
    }
    return AppleRecognitionResult(text: tokens.joined().trimmingCharacters(in: .whitespaces), runs: runs,
        startSample: first, endSample: last, isFinal: final, processingLatency: 0)
}

/// One recognizer result spanning two consecutive token groups.
private func joined(_ head: AppleRecognitionResult, _ tail: AppleRecognitionResult) -> AppleRecognitionResult {
    AppleRecognitionResult(text: (head.runs + tail.runs).map(\.text).joined(), runs: head.runs + tail.runs,
        startSample: head.startSample, endSample: tail.endSample, isFinal: false, processingLatency: 0)
}

@Test func bilingualScriptDetectionUsesHanCharactersAgainstLatinWords() {
    #expect(BilingualRecognitionArbiter.scriptLanguage("各位朋友最近") == .chinese)
    #expect(BilingualRecognitionArbiter.scriptLanguage("So the mostemotant thin about") == .english)
    // A Chinese speaker using product names remains Chinese.
    #expect(BilingualRecognitionArbiter.scriptLanguage("我们用Kubernetes部署服务") == .chinese)
    // Too little evidence, or a balanced mixture, does not decide anything.
    #expect(BilingualRecognitionArbiter.scriptLanguage("好的") == nil)
    #expect(BilingualRecognitionArbiter.scriptLanguage("OK") == nil)
    #expect(BilingualRecognitionArbiter.scriptLanguage("我们用 Argo CD 部署 microservices") == nil)
    #expect(BilingualRecognitionArbiter.scriptLanguage("don't you think so") == .english)
}

@Test func bilingualArbiterForwardsOnlyTheLanguageBeingSpoken() {
    var arbiter = BilingualRecognitionArbiter()
    // English speech: zh_CN writes Latin words, en_US writes the real text.
    #expect(arbiter.accept(result(["So ", "the ", "most "], 0, 1), from: .chinese).isEmpty)
    #expect(arbiter.active == .english)
    let volatile = arbiter.accept(result(["So ", "the ", "most ", "important"], 0, 1.2), from: .english)
    #expect(volatile.map(\.output.text) == ["So the most important"])
    #expect(volatile.first?.output.language == .english)
    let final = arbiter.accept(result(["So ", "the ", "most ", "important ", "thing."], 0, 2, final: true, confidence: 0.97), from: .english)
    #expect(final.map(\.isFinal) == [true])
    #expect(arbiter.committedThrough == 32_000)
    // The zh_CN final for the same English audio is never shown.
    #expect(arbiter.accept(result(["So ", "themo ", "thin"], 0, 2, final: true, confidence: 0.7), from: .chinese).isEmpty)
}

@Test func bilingualArbiterSwitchesToChineseAndTrimsAudioAlreadyCommitted() {
    var arbiter = BilingualRecognitionArbiter()
    _ = arbiter.accept(result(["So ", "the ", "most "], 0, 1), from: .chinese)
    _ = arbiter.accept(result(["We ", "measured ", "it."], 0, 2, final: true, confidence: 0.95), from: .english)
    // zh_CN volatile still covers the English sentence, then Chinese speech.
    let english = result(["We ", "mesured ", "it"], 0, 2)
    let mixed = joined(english, result(["各", "位", "朋", "友"], 2, 3.5))
    // One Chinese vote is not enough to switch.
    #expect(arbiter.accept(mixed, from: .chinese).isEmpty)
    #expect(arbiter.active == .english)
    let next = arbiter.accept(joined(english, result(["各", "位", "朋", "友", "最", "近"], 2, 4)), from: .chinese)
    #expect(arbiter.active == .chinese)
    // Tokens before the committed English final are trimmed by audio time.
    #expect(next.map(\.output.text) == ["各位朋友最近"])
    #expect(next.first?.startSample == 32_000)
    #expect(next.first?.output.language == .chinese)
    // The English recognizer's pinyin-like guess for Chinese audio is dropped.
    #expect(arbiter.accept(result(["Wei ", "Pongyo"], 2, 4, final: true, confidence: 0.18), from: .english).isEmpty)
}

@Test func bilingualArbiterDoesNotCommitLowConfidenceEnglishWhenChineseIsIndicated() {
    var arbiter = BilingualRecognitionArbiter()
    _ = arbiter.accept(result(["Hello ", "there ", "everyone"], 0, 1), from: .chinese)
    #expect(arbiter.active == .english)
    // A single zh_CN vote for Chinese, then the English final for that audio
    // arrives first with low confidence: switch instead of committing it.
    _ = arbiter.accept(result(["各", "位", "朋", "友"], 1, 2), from: .chinese)
    let english = arbiter.accept(result(["Gay ", "way"], 1, 2, final: true, confidence: 0.5), from: .english)
    #expect(english.isEmpty)
    #expect(arbiter.active == .chinese)
    let chinese = arbiter.accept(result(["各", "位", "朋", "友", "好"], 1, 2.2, final: true, confidence: 0.98), from: .chinese)
    #expect(chinese.map(\.output.text) == ["各位朋友好"])
    #expect(chinese.first?.isFinal == true)
}

@Test func bilingualArbiterKeepsTrustedEnglishDespiteAStrayChineseName() {
    var arbiter = BilingualRecognitionArbiter()
    _ = arbiter.accept(result(["I ", "met ", "him "], 0, 1), from: .chinese)
    _ = arbiter.accept(result(["王", "小", "明"], 1, 1.6), from: .chinese)
    let final = arbiter.accept(result(["I ", "met ", "Wang ", "Xiaoming."], 0, 1.6, final: true, confidence: 0.9), from: .english)
    #expect(final.map(\.output.text) == ["I met Wang Xiaoming."])
    #expect(arbiter.active == .english)
}

@Test func bilingualArbiterReplaysAFinalThatArrivedBeforeTheSwitch() {
    var arbiter = BilingualRecognitionArbiter()
    _ = arbiter.accept(result(["各", "位", "朋", "友"], 0, 1), from: .chinese)
    #expect(arbiter.active == .chinese)
    _ = arbiter.accept(result(["大", "家", "好"], 0, 1.5, final: true, confidence: 0.99), from: .chinese)
    // English starts. Its en_US final happens to arrive before zh_CN evidence.
    #expect(arbiter.accept(result(["Thanks ", "for ", "coming."], 1.5, 3, final: true, confidence: 0.96), from: .english).isEmpty)
    let switched = arbiter.accept(result(["Thanks ", "for ", "coming"], 1.5, 3, final: true, confidence: 0.7), from: .chinese)
    #expect(arbiter.active == .english)
    #expect(switched.map(\.output.text) == ["Thanks for coming."])
    #expect(switched.first?.output.language == .english)
}

@Test func bilingualArbiterDecidesShortEnglishFromConfidentFinal() {
    var arbiter = BilingualRecognitionArbiter()
    // Two words never decide by script; a confident en_US final does.
    #expect(arbiter.accept(result(["Yes ", "sure"], 0, 0.8), from: .chinese).isEmpty)
    let final = arbiter.accept(result(["Yes, ", "sure."], 0, 0.8, final: true, confidence: 0.92), from: .english)
    #expect(arbiter.active == .english)
    #expect(final.map(\.output.text) == ["Yes, sure."])
}

@Test @MainActor func automaticLanguageUsesContinuousAppleStreamingAndMigratesOldWhisperDefault() {
    #expect(ASRModel.recommended(for: .automatic).id == ASRModel.bilingualAppleID)
    #expect(ASRModel.bilingualApple.usesNativeStreaming)
    #expect(ASRModel.bilingualApple.supports(.automatic))
    #expect(!ASRModel.bilingualApple.supports(.english))
    let suite = "BilingualMigration-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("automatic", forKey: "recognitionLanguageMode")
    defaults.set(ASRModel.whisperFallback.id, forKey: "selectedModelId")
    let migrated = CaptionSettings(defaults: defaults)
    #expect(migrated.selectedModelId == ASRModel.bilingualAppleID)
    #expect(migrated.recognitionLanguageMode == .automatic)
    // A Whisper choice made after the one-time migration is preserved.
    migrated.selectedModelId = ASRModel.whisperFallback.id
    let reloaded = CaptionSettings(defaults: defaults)
    #expect(reloaded.selectedModelId == ASRModel.whisperFallback.id)
    #expect(reloaded.recognitionLanguageMode == .automatic)
}
