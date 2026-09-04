import Testing
import Foundation
@testable import StreamTranslate

@Test @MainActor func translationServiceThrowsWithoutSession() async {
    let service = TranslationService()
    do {
        _ = try await service.translate("Hello", direction: .englishToChinese)
        Issue.record("Expected TranslationServiceError.sessionNotReady")
    } catch {
        #expect(error is TranslationServiceError)
        #expect(error.localizedDescription == "Translation session is not initialized")
    }
}

@Test @MainActor func translationBatchThrowsWithoutSession() async {
    let service = TranslationService()
    do {
        try await service.translateBatch(
            [IdentifiedTranslationRequest(id: UUID(), text: "Hello")],
            direction: .englishToChinese,
            onResponse: { _ in }
        )
        Issue.record("Expected TranslationServiceError.sessionNotReady")
    } catch let error as TranslationServiceError {
        #expect(error == .sessionNotReady)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test @MainActor func translationServiceConfigurationSimplifiedChinese() {
    let service = TranslationService()
    let config = service.configuration(
        direction: .englishToChinese,
        chineseTarget: .simplifiedChinese
    )
    #expect(config.source?.languageCode?.identifier == "en")
    #expect(config.target?.languageCode?.identifier == "zh")
    #expect(config.target?.script?.identifier == "Hans")
}

@Test @MainActor func translationServiceConfigurationTraditionalChineseTaiwan() {
    let service = TranslationService()
    let config = service.configuration(
        direction: .englishToChinese,
        chineseTarget: .traditionalChineseTaiwan
    )
    #expect(config.source?.languageCode?.identifier == "en")
    #expect(config.target?.languageCode?.identifier == "zh")
    #expect(config.target?.script?.identifier == "Hant")
    #expect(config.target?.region?.identifier == "TW")
}

@Test @MainActor func translationServiceConfigurationChineseToEnglish() {
    let service = TranslationService()
    let config = service.configuration(
        direction: .chineseToEnglish,
        chineseTarget: .simplifiedChinese
    )
    #expect(config.source?.languageCode?.identifier == "zh")
    #expect(config.source?.script?.identifier == "Hans")
    #expect(config.target?.languageCode?.identifier == "en")
}
