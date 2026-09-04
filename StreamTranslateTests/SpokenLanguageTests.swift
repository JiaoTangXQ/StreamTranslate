import Testing
import Foundation
@testable import StreamTranslate

@Test func keyboardAndTypingAnnotationsAreNotSpeech() {
    #expect(TranscriptionTextPolicy.isNonSpeechOnly("(typing)"))
    #expect(TranscriptionTextPolicy.isNonSpeechOnly("(keyboard clicking)"))
    #expect(TranscriptionTextPolicy.isNonSpeechOnly("（键盘声）"))
}

@Test func whisperBlankAudioMarkersAreNotSpeech() {
    #expect(TranscriptionTextPolicy.isNonSpeechOnly("[BLANK_AUDIO]"))
    #expect(TranscriptionTextPolicy.isNonSpeechOnly("[blank audio]"))
}

@Test func whisperLanguageAnnotationsAreNotSpeech() {
    #expect(TranscriptionTextPolicy.isNonSpeechOnly("[speaking Chinese]"))
    #expect(TranscriptionTextPolicy.isNonSpeechOnly("[speaking English]"))
    #expect(TranscriptionTextPolicy.isNonSpeechOnly("[FOREIGN]"))
}

@Test func spokenParentheticalTextIsNotDiscarded() {
    #expect(!TranscriptionTextPolicy.isNonSpeechOnly("(Can you hear me?)"))
    #expect(!TranscriptionTextPolicy.isNonSpeechOnly("正常说话"))
}

@Test func runawayWhisperRepetitionIsNotTreatedAsSpeech() {
    let repeated = Array(
        repeating: "we can build our agents",
        count: 20
    ).joined(separator: ", ")

    #expect(TranscriptionTextPolicy.isDegenerateRepetition(repeated))
}

@Test func ordinaryEmphasisIsNotTreatedAsRunawayRepetition() {
    #expect(!TranscriptionTextPolicy.isDegenerateRepetition(
        "No, no, no, that is not what I meant."
    ))
}

@Test func whisperEnglishCodeResolvesToEnglish() {
    #expect(SpokenLanguage.resolve(whisperCode: "en", text: "Good morning") == .english)
}

@Test func whisperChineseCodeResolvesToChinese() {
    #expect(SpokenLanguage.resolve(whisperCode: "zh", text: "早上好") == .chinese)
}

@Test func chineseScriptCorrectsShortUtteranceLanguage() {
    #expect(SpokenLanguage.resolve(whisperCode: "en", text: "你好世界") == .chinese)
}

@Test func unsupportedLanguageDoesNotResolveAsEnglish() {
    #expect(SpokenLanguage.resolve(whisperCode: "ru", text: "Привет") == .unknown)
}

@Test func recognitionModesOnlyForceLanguageWhenExplicitlySelected() {
    #expect(RecognitionLanguageMode.automatic.languageHint == nil)
    #expect(RecognitionLanguageMode.chinese.languageHint == .chinese)
    #expect(RecognitionLanguageMode.english.languageHint == .english)
}

@Test func translationDirectionFollowsDetectedSource() {
    #expect(TranslationDirection.forSource(.english) == .englishToChinese)
    #expect(TranslationDirection.forSource(.chinese) == .chineseToEnglish)
}

@Test func chineseCaptionKeepsOriginalBeforeTranslation() {
    let entry = CaptionEntry(
        timestamp: .now,
        englishText: "This is a test",
        chineseText: "这是测试",
        sourceLanguage: .chinese
    )
    #expect(entry.originalText == "这是测试")
    #expect(entry.translatedText == "This is a test")
}

@Test func whisperFinalPassKeepsOneFallbackButAvoidsUnusedTimestamps() {
    let options = WhisperTranscriptionService.decodingOptions
    #expect(options.detectLanguage)
    #expect(options.temperatureFallbackCount > 0)
    #expect(options.firstTokenLogProbThreshold != nil)
    #expect(options.withoutTimestamps)
    #expect(!options.wordTimestamps)
}

@Test func whisperPreviewPassAvoidsExpensiveFallbackAndTimestamps() {
    let options = WhisperTranscriptionService.previewDecodingOptions
    #expect(options.temperatureFallbackCount == 0)
    #expect(options.firstTokenLogProbThreshold == nil)
    #expect(options.withoutTimestamps)
    #expect(!options.wordTimestamps)
}

@Test func completeLocalWhisperModelCanBeUsedWithoutNetwork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "StreamTranslate-model-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(
        to: root.appendingPathComponent("config.json")
    )
    for name in [
        "AudioEncoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "TextDecoder.mlmodelc",
    ] {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: false
        )
        try Data([0]).write(
            to: folder.appendingPathComponent("coremldata.bin")
        )
    }

    #expect(WhisperTranscriptionService.isCompleteModelFolder(root))
    try FileManager.default.removeItem(
        at: root.appendingPathComponent("TextDecoder.mlmodelc")
    )
    #expect(!WhisperTranscriptionService.isCompleteModelFolder(root))
}
