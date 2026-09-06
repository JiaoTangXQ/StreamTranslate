import Translation
import Foundation

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
    private let sessionLock = NSLock()

    func configuration(
        direction: TranslationDirection,
        chineseTarget: TranslationTarget
    ) -> TranslationSession.Configuration {
        let source: Locale.Language
        let target: Locale.Language
        switch direction {
        case .englishToChinese:
            source = .init(identifier: "en")
            target = .init(identifier: chineseTarget.rawValue)
        case .chineseToEnglish:
            source = .init(identifier: chineseTarget.rawValue)
            target = .init(identifier: "en")
        }
        if #available(macOS 26.4, *) {
            return .init(source: source, target: target, preferredStrategy: .lowLatency)
        }
        return .init(source: source, target: target)
    }

    func setSession(_ session: TranslationSession, for direction: TranslationDirection) {
        sessionLock.withLock { sessions[direction] = session }
    }

    /// macOS 26 can own sessions directly once language assets are installed.
    /// No SwiftUI view or visible NSWindow is part of this lifetime.
    func installIndependentSession(direction: TranslationDirection, chineseTarget: TranslationTarget) async -> Bool {
        let config = configuration(direction: direction, chineseTarget: chineseTarget)
        guard let source = config.source, let target = config.target else { return false }
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else { availability = LanguageAvailability() }
        guard await availability.status(from: source, to: target) == .installed else { return false }
        guard !Task.isCancelled else { return false }
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else { session = TranslationSession(installedSource: source, target: target) }
        let previous = sessionLock.withLock { sessions.updateValue(session, forKey: direction) }
        previous?.cancel()
        return true
    }

    func cancelSessions() {
        let previous = sessionLock.withLock {
            let values = Array(sessions.values)
            sessions.removeAll()
            return values
        }
        for session in previous { session.cancel() }
    }

    func prepare(_ direction: TranslationDirection) async throws {
        guard let session = sessionLock.withLock({ sessions[direction] }) else {
            throw TranslationServiceError.sessionNotReady
        }
        try await session.prepareTranslation()
    }

    func translate(_ text: String, direction: TranslationDirection) async throws -> String {
        guard let session = sessionLock.withLock({ sessions[direction] }) else {
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
        guard let session = sessionLock.withLock({ sessions[direction] }) else {
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
