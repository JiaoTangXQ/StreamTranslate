import Translation

struct IdentifiedTranslationRequest: Sendable {
    let id: UUID
    let text: String
}

struct IdentifiedTranslationResponse: Sendable {
    let id: UUID
    let sourceText: String
    let translatedText: String
}

final class TranslationService: @unchecked Sendable {
    private var sessions: [TranslationDirection: TranslationSession] = [:]

    func configuration(
        direction: TranslationDirection,
        chineseTarget: TranslationTarget
    ) -> TranslationSession.Configuration {
        switch direction {
        case .englishToChinese:
            return TranslationSession.Configuration(
                source: .init(identifier: "en"),
                target: .init(identifier: chineseTarget.rawValue)
            )
        case .chineseToEnglish:
            return TranslationSession.Configuration(
                source: .init(identifier: chineseTarget.rawValue),
                target: .init(identifier: "en")
            )
        }
    }

    func setSession(_ session: TranslationSession, for direction: TranslationDirection) {
        sessions[direction] = session
    }

    func prepare(_ direction: TranslationDirection) async throws {
        guard let session = sessions[direction] else {
            throw TranslationServiceError.sessionNotReady
        }
        try await session.prepareTranslation()
    }

    func translate(_ text: String, direction: TranslationDirection) async throws -> String {
        guard let session = sessions[direction] else {
            throw TranslationServiceError.sessionNotReady
        }
        let response = try await session.translate(text)
        return response.targetText
    }

    func translateBatch(
        _ requests: [IdentifiedTranslationRequest],
        direction: TranslationDirection,
        onResponse: @escaping @Sendable (IdentifiedTranslationResponse) async -> Void
    ) async throws {
        guard let session = sessions[direction] else {
            throw TranslationServiceError.sessionNotReady
        }
        let identifiers = Dictionary(
            uniqueKeysWithValues: requests.map { ($0.id.uuidString, $0.id) }
        )
        let batch = requests.map {
            TranslationSession.Request(
                sourceText: $0.text,
                clientIdentifier: $0.id.uuidString
            )
        }
        for try await response in session.translate(batch: batch) {
            guard let rawID = response.clientIdentifier,
                  let id = identifiers[rawID] else { continue }
            await onResponse(
                IdentifiedTranslationResponse(
                    id: id,
                    sourceText: response.sourceText,
                    translatedText: response.targetText
                )
            )
        }
    }
}

enum TranslationServiceError: Error, LocalizedError {
    case sessionNotReady

    var errorDescription: String? {
        switch self {
        case .sessionNotReady:
            return "Translation session is not initialized"
        }
    }
}
