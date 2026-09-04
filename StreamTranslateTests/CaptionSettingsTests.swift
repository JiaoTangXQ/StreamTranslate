import Testing
import Foundation
@testable import StreamTranslate

func makeTestDefaults(
    file: StaticString = #fileID,
    function: StaticString = #function
) -> UserDefaults {
    let safeName = "\(file).\(function)"
        .replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression)
    let domainName = "com.jiaotangxq.StreamTranslateTests.\(safeName)"
    guard let defaults = UserDefaults(suiteName: domainName) else {
        preconditionFailure("Unable to create isolated test defaults")
    }
    defaults.removePersistentDomain(forName: domainName)
    return defaults
}

@Test @MainActor func microphoneIsDefaultAudioInput() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "audioInputSource")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.audioInputSource == .microphone)

    defaults.removeObject(forKey: "audioInputSource")
}

@Test @MainActor func audioInputRoundTripPersistence() {
    let defaults = makeTestDefaults()
    defaults.set(AudioInputSource.systemAudio.rawValue, forKey: "audioInputSource")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.audioInputSource == .systemAudio)

    settings.audioInputSource = .microphone
    let reloaded = CaptionSettings(defaults: defaults)
    #expect(reloaded.audioInputSource == .microphone)

    defaults.removeObject(forKey: "audioInputSource")
}

// MARK: - ASRModel

@Test func asrModelAvailableIsNotEmpty() {
    #expect(!ASRModel.available.isEmpty)
}

@Test func asrModelDefaultModelExistsInAvailable() {
    let defaultModel = ASRModel.defaultModel
    let found = ASRModel.available.contains { $0.id == defaultModel.id }
    #expect(found)
}

@Test func asrModelHasUniqueIds() {
    let ids = ASRModel.available.map { $0.id }
    #expect(Set(ids).count == ids.count)
}

@Test func asrModelDefaultIsNativeStreamingEnglish() {
    #expect(ASRModel.defaultModel.id == "apple-speech-transcriber-en")
    #expect(ASRModel.defaultModel.backend == .appleSpeech)
}

@Test func asrModelOffersSpeedAndAccuracyPriorities() {
    let modelsByPriority = Dictionary(
        uniqueKeysWithValues: ASRModel.available.map { ($0.priorityName, $0) }
    )

    #expect(modelsByPriority["速度优先"]?.id == "openai_whisper-small")
    #expect(
        modelsByPriority["准确度优先"]?.id
            == "openai_whisper-large-v3-v20240930_626MB"
    )
}

@Test func asrModelProfilesMatchTheirLatencyTradeoff() {
    let modelsByPriority = Dictionary(
        uniqueKeysWithValues: ASRModel.available.map { ($0.priorityName, $0) }
    )

    #expect(modelsByPriority["速度优先"]?.maximumUtteranceDuration == 8)
    #expect(modelsByPriority["速度优先"]?.firstPreviewInterval == 0.75)
    #expect(modelsByPriority["速度优先"]?.subsequentPreviewInterval == 0.75)
    #expect(modelsByPriority["速度优先"]?.usesRollingAudioContext == false)
    #expect(modelsByPriority["准确度优先"]?.maximumUtteranceDuration == 15)
    #expect(modelsByPriority["准确度优先"]?.firstPreviewInterval == 1)
    #expect(modelsByPriority["准确度优先"]?.subsequentPreviewInterval == 1.5)
    #expect(modelsByPriority["准确度优先"]?.usesRollingAudioContext == true)
}

// MARK: - CaptionSettings

@Test @MainActor func captionSettingsDefaultValues() {
    // Clear stored values to test defaults
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "panelWidth")
    defaults.removeObject(forKey: "panelHeight")
    defaults.removeObject(forKey: "fontSize")
    defaults.removeObject(forKey: "selectedModelId")
    defaults.removeObject(forKey: "speechDetectionSensitivity")
    defaults.removeObject(forKey: "recognitionLanguageMode")
    defaults.removeObject(forKey: "recognitionVocabulary")
    defaults.removeObject(forKey: "captureDiagnosticsEnabled")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.panelWidth == 620)
    #expect(settings.panelHeight == 200)
    #expect(settings.fontSize == 15)
    #expect(settings.selectedModelId == ASRModel.defaultModel.id)
    #expect(settings.speechDetectionSensitivity == .automatic)
    #expect(settings.recognitionLanguageMode == .english)
    #expect(settings.recognitionVocabulary.isEmpty)
    #expect(!settings.captureDiagnosticsEnabled)
}

@Test @MainActor func recognitionVocabularyRoundTripPersistence() {
    let defaults = makeTestDefaults()
    let settings = CaptionSettings(defaults: defaults)
    settings.recognitionVocabulary = "Argo CD, Kubernetes, YAML"

    let reloaded = CaptionSettings(defaults: defaults)
    #expect(reloaded.recognitionVocabulary == "Argo CD, Kubernetes, YAML")

    defaults.removeObject(forKey: "recognitionVocabulary")
}

@Test @MainActor func captureDiagnosticsRoundTripPersistence() {
    let defaults = makeTestDefaults()
    let settings = CaptionSettings(defaults: defaults)
    settings.captureDiagnosticsEnabled = true

    let reloaded = CaptionSettings(defaults: defaults)
    #expect(reloaded.captureDiagnosticsEnabled)

    defaults.removeObject(forKey: "captureDiagnosticsEnabled")
}

@Test @MainActor func recognitionLanguageModeRoundTripPersistence() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "recognitionLanguageMode")

    let settings = CaptionSettings(defaults: defaults)
    settings.recognitionLanguageMode = .chinese

    let reloaded = CaptionSettings(defaults: defaults)
    #expect(reloaded.recognitionLanguageMode == .chinese)

    defaults.removeObject(forKey: "recognitionLanguageMode")
}

@Test @MainActor func invalidRecognitionLanguageModeFallsBackToModelCompatibleDefault() {
    let defaults = makeTestDefaults()
    defaults.set("unsupported", forKey: "recognitionLanguageMode")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.recognitionLanguageMode == .english)

    defaults.removeObject(forKey: "recognitionLanguageMode")
}

@Test @MainActor func nonEnglishModeSelectsWhisperFallback() {
    let defaults = makeTestDefaults()
    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.selectedModel.backend == .appleSpeech)

    settings.recognitionLanguageMode = .chinese

    #expect(settings.selectedModel.id == ASRModel.whisperFallback.id)
    #expect(settings.recognitionLanguageMode == .chinese)
}

@Test @MainActor func selectingAppleStreamingForcesEnglishMode() {
    let defaults = makeTestDefaults()
    defaults.set(ASRModel.whisperFallback.id, forKey: "selectedModelId")
    defaults.set(RecognitionLanguageMode.automatic.rawValue, forKey: "recognitionLanguageMode")
    let settings = CaptionSettings(defaults: defaults)

    settings.selectedModelId = ASRModel.defaultModel.id

    #expect(settings.recognitionLanguageMode == .english)
}

@Test @MainActor func speechDetectionSensitivityRoundTripPersistence() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "speechDetectionSensitivity")

    let settings = CaptionSettings(defaults: defaults)
    settings.speechDetectionSensitivity = .farField

    let reloaded = CaptionSettings(defaults: defaults)
    #expect(reloaded.speechDetectionSensitivity == .farField)

    defaults.removeObject(forKey: "speechDetectionSensitivity")
}

@Test @MainActor func invalidSpeechDetectionSensitivityFallsBackToAutomatic() {
    let defaults = makeTestDefaults()
    defaults.set("unsupported", forKey: "speechDetectionSensitivity")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.speechDetectionSensitivity == .automatic)

    defaults.removeObject(forKey: "speechDetectionSensitivity")
}

@Test @MainActor func captionSettingsSelectedModelProperty() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "selectedModelId")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.selectedModel.id == ASRModel.defaultModel.id)
    #expect(settings.selectedModel.name == ASRModel.defaultModel.name)
}

@Test @MainActor func captionSettingsPersistsPanelWidth() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "panelWidth")

    let settings = CaptionSettings(defaults: defaults)
    settings.panelWidth = 800
    #expect(defaults.double(forKey: "panelWidth") == 800)
}

@Test @MainActor func captionSettingsPersistsPanelHeight() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "panelHeight")

    let settings = CaptionSettings(defaults: defaults)
    settings.panelHeight = 360
    #expect(defaults.double(forKey: "panelHeight") == 360)

    defaults.removeObject(forKey: "panelHeight")
}

@Test @MainActor func captionSettingsPersistsFontSize() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "fontSize")

    let settings = CaptionSettings(defaults: defaults)
    settings.fontSize = 20
    #expect(defaults.double(forKey: "fontSize") == 20)
}

@Test @MainActor func captionSettingsPersistsModelId() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "selectedModelId")

    let settings = CaptionSettings(defaults: defaults)
    settings.selectedModelId = ASRModel.defaultModel.id
    #expect(defaults.string(forKey: "selectedModelId") == ASRModel.defaultModel.id)
}

@Test @MainActor func captionSettingsLoadsPersistedAccuracyModel() {
    let defaults = makeTestDefaults()
    let accuracyModelId = "openai_whisper-large-v3-v20240930_626MB"
    defaults.set(accuracyModelId, forKey: "selectedModelId")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.selectedModelId == accuracyModelId)
    #expect(settings.selectedModel.priorityName == "准确度优先")

    defaults.removeObject(forKey: "selectedModelId")
}

@Test @MainActor func captionSettingsInvalidModelIdFallsBackToDefault() {
    let defaults = makeTestDefaults()
    defaults.set("nonexistent-model", forKey: "selectedModelId")

    let settings = CaptionSettings(defaults: defaults)
    // Should fall back to default because "nonexistent-model" is not in available list
    #expect(settings.selectedModelId == ASRModel.defaultModel.id)
}

@Test @MainActor func captionSettingsSelectedModelFallbackForInvalidId() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "selectedModelId")

    let settings = CaptionSettings(defaults: defaults)
    // Manually set an invalid id after init
    settings.selectedModelId = "invalid-model"
    // selectedModel should fall back to default
    #expect(settings.selectedModel.id == ASRModel.defaultModel.id)
}

@Test @MainActor func captionSettingsLoadsPersistedPanelWidth() {
    let defaults = makeTestDefaults()
    defaults.set(750.0, forKey: "panelWidth")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.panelWidth == 750)

    // Cleanup
    defaults.removeObject(forKey: "panelWidth")
}

@Test @MainActor func captionSettingsLoadsPersistedPanelHeight() {
    let defaults = makeTestDefaults()
    defaults.set(340.0, forKey: "panelHeight")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.panelHeight == 340)

    defaults.removeObject(forKey: "panelHeight")
}

@Test @MainActor func captionSettingsLoadsPersistedFontSize() {
    let defaults = makeTestDefaults()
    defaults.set(18.0, forKey: "fontSize")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.fontSize == 18)

    // Cleanup
    defaults.removeObject(forKey: "fontSize")
}

// MARK: - TranslationTarget

@Test func translationTargetRawValuesAreBCP47() {
    #expect(TranslationTarget.simplifiedChinese.rawValue == "zh-Hans")
    #expect(TranslationTarget.traditionalChineseTaiwan.rawValue == "zh-Hant-TW")
}

@Test func translationTargetAllCasesContainsBoth() {
    let ids = TranslationTarget.allCases.map(\.rawValue)
    #expect(ids.contains("zh-Hans"))
    #expect(ids.contains("zh-Hant-TW"))
}

@Test func translationTargetHasDisplayNames() {
    // Display names are for human readers; verify non-empty and distinct so
    // the Settings picker never shows two identical rows.
    let names = TranslationTarget.allCases.map(\.displayName)
    #expect(names.allSatisfy { !$0.isEmpty })
    #expect(Set(names).count == names.count)
}

@Test @MainActor func captionSettingsDefaultTranslationTargetIsSimplified() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "translationTarget")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.translationTarget == .simplifiedChinese)
}

@Test @MainActor func captionSettingsPersistsTranslationTarget() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "translationTarget")

    let settings = CaptionSettings(defaults: defaults)
    settings.translationTarget = .traditionalChineseTaiwan
    #expect(defaults.string(forKey: "translationTarget") == "zh-Hant-TW")

    // Cleanup
    defaults.removeObject(forKey: "translationTarget")
}

@Test @MainActor func captionSettingsLoadsPersistedTranslationTarget() {
    let defaults = makeTestDefaults()
    defaults.set("zh-Hant-TW", forKey: "translationTarget")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.translationTarget == .traditionalChineseTaiwan)

    // Cleanup
    defaults.removeObject(forKey: "translationTarget")
}

@Test @MainActor func captionSettingsInvalidTranslationTargetFallsBackToDefault() {
    let defaults = makeTestDefaults()
    defaults.set("ja-JP", forKey: "translationTarget")

    let settings = CaptionSettings(defaults: defaults)
    #expect(settings.translationTarget == .simplifiedChinese)

    // Cleanup
    defaults.removeObject(forKey: "translationTarget")
}
