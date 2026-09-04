import Testing
import Foundation
@testable import StreamTranslate

// MARK: - Integration Tests

/// End-to-end flow: add captions, verify history and recent, clear, verify empty
@Test @MainActor func fullCaptionFlowEndToEnd() {
    let vm = CaptionViewModel()

    // Add captions simulating a transcription session
    vm.addCaption(english: "Good morning everyone", chinese: "大家早上好")
    vm.addCaption(english: "Today we will discuss AI", chinese: "今天我们讨论人工智能")
    vm.addCaption(english: "Let's begin", chinese: "让我们开始吧")

    // History should have all 3
    #expect(vm.captionHistory.count == 3)
    // Recent keeps 2 most recent
    #expect(vm.recentCaptions.count == 2)
    #expect(vm.recentCaptions[0].englishText == "Today we will discuss AI")
    #expect(vm.recentCaptions[1].englishText == "Let's begin")

    // Add a 4th, recent drops oldest to stay at 2
    vm.addCaption(english: "First topic", chinese: "第一个话题")
    #expect(vm.captionHistory.count == 4)
    #expect(vm.recentCaptions.count == 2)
    #expect(vm.recentCaptions[0].englishText == "Let's begin")
    #expect(vm.recentCaptions[1].englishText == "First topic")

    // Clear resets everything
    vm.clearHistory()
    #expect(vm.captionHistory.isEmpty)
    #expect(vm.recentCaptions.isEmpty)
    #expect(vm.streamingEnglish.isEmpty)
    #expect(vm.streamingChinese.isEmpty)
}

/// Simulate streaming state transitions
@Test @MainActor func streamingStateTransitions() {
    let vm = CaptionViewModel()

    // Simulate streaming text arriving
    vm.streamingEnglish = "Hello"
    vm.streamingChinese = ""
    #expect(vm.streamingEnglish == "Hello")
    #expect(vm.streamingChinese.isEmpty)

    // Simulate translation arriving
    vm.streamingChinese = "你好"
    #expect(vm.streamingChinese == "你好")

    // Simulate moving to history
    vm.addCaption(english: vm.streamingEnglish, chinese: vm.streamingChinese)
    vm.streamingEnglish = ""
    vm.streamingChinese = ""
    #expect(vm.streamingEnglish.isEmpty)
    #expect(vm.captionHistory.count == 1)
    #expect(vm.captionHistory[0].englishText == "Hello")
    #expect(vm.captionHistory[0].chineseText == "你好")
}

/// Settings and ViewModel work together
@Test @MainActor func settingsIntegration() {
    let defaults = makeTestDefaults()
    defaults.removeObject(forKey: "panelWidth")
    defaults.removeObject(forKey: "fontSize")
    defaults.removeObject(forKey: "selectedModelId")

    let settings = CaptionSettings(defaults: defaults)
    let vm = CaptionViewModel()

    // Default model should match settings
    #expect(settings.selectedModel.id == ASRModel.defaultModel.id)

    // ViewModel and settings are independent but consistent
    #expect(vm.isModelReady == false)
    #expect(settings.panelWidth == 620)
    #expect(settings.fontSize == 15)
}

/// Word timestamp storage in streaming
@Test @MainActor func wordTimestampStorage() {
    let vm = CaptionViewModel()

    let words = [
        WordTimestamp(word: "Hello", start: 0.0, end: 0.5, confidence: 0.95),
        WordTimestamp(word: "world", start: 0.5, end: 1.0, confidence: 0.88),
    ]
    vm.streamingWords = words
    #expect(vm.streamingWords.count == 2)
    #expect(vm.streamingWords[0].word == "Hello")
    #expect(vm.streamingWords[0].confidence == 0.95)
    #expect(vm.streamingWords[1].word == "world")

    // Clear should reset words
    vm.clearHistory()
    #expect(vm.streamingWords.isEmpty)
}

/// TranslationService refuses to translate without session
@Test func translationServiceRejectsWithoutSession() async {
    let service = TranslationService()
    do {
        _ = try await service.translate("test", direction: .englishToChinese)
        Issue.record("Should have thrown")
    } catch let error as TranslationServiceError {
        #expect(error == .sessionNotReady)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

// MARK: - System Audio Capture Health

@Test func initialDigitalSilenceDoesNotRestartSystemAudioCapture() {
    var health = SystemAudioCaptureHealth()
    health.resetForNewStream(at: 0)

    for index in 1...1_000 {
        let time = Double(index) * 0.02
        health.observe(.audio, at: time)
        #expect(health.checkForCallbackStall(at: time) == nil)
    }
}

@Test func naturalSilenceAfterSpeechDoesNotRestartSystemAudioCapture() {
    var health = SystemAudioCaptureHealth()
    health.resetForNewStream(at: 0)

    for index in 1...250 {
        health.observe(.audio, at: Double(index) * 0.02)
    }
    for index in 251...1_000 {
        let time = Double(index) * 0.02
        health.observe(.screen, at: time)
        #expect(health.checkForCallbackStall(at: time) == nil)
    }
}

@Test func stalledSystemAudioCallbacksRequestRecovery() {
    var health = SystemAudioCaptureHealth()

    health.resetForNewStream(at: 10)
    #expect(health.checkForCallbackStall(at: 12.9) == nil)
    #expect(health.checkForCallbackStall(at: 13) == .callbackStall)
    #expect(health.checkForCallbackStall(at: 20) == nil)
}

@Test func activeMicrophoneCallbacksDoNotRequestRecovery() {
    var health = MicrophoneCaptureHealth()
    health.reset(at: 0)

    for index in 1...1_000 {
        let time = Double(index) * 0.02
        health.observeCallback(at: time)
        #expect(health.checkForCallbackStall(at: time) == nil)
    }
}

@Test func stalledMicrophoneCallbacksRequestOneRecoveryUntilReset() {
    var health = MicrophoneCaptureHealth()
    health.reset(at: 10)

    #expect(health.checkForCallbackStall(at: 12.9) == nil)
    #expect(health.checkForCallbackStall(at: 13) == .callbackStall)
    #expect(health.checkForCallbackStall(at: 20) == nil)

    health.allowRecoveryRetry(at: 20)
    #expect(health.checkForCallbackStall(at: 23) == .callbackStall)
}
