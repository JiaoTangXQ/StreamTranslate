import Foundation

/// Shared cooldown survives the summary drawer's idle release; no retry storm
/// when a provider is offline, rate-limited or the credentials are rejected.
@MainActor final class SummaryCloudCooldown {
    static let shared = SummaryCloudCooldown()
    private var retryAt = Date.distantPast
    var allowsCloud: Bool { Date() >= retryAt }
    func failed() { retryAt = Date().addingTimeInterval(60) }
    func succeeded() { retryAt = .distantPast }
}

@MainActor final class AutomaticSummaryService: ConversationSummaryProviding {
    private let makeCloud: (() -> any ConversationSummaryProviding)?
    private let makeLocal: () -> any ConversationSummaryProviding
    private let cooldown: SummaryCloudCooldown
    private var cloud: (any ConversationSummaryProviding)?
    private var local: (any ConversationSummaryProviding)?
    private var cancelled = false
    private(set) var backendDescription: String
    var usesLocalModel: Bool { local != nil || makeCloud == nil }

    convenience init(configuration: SummaryCloudConfiguration? = .load()) {
        self.init(makeCloud: configuration.map { config in { CloudSummaryService(configuration: config) } },
                  makeLocal: { LocalSummaryService() }, cooldown: .shared)
    }

    init(makeCloud: (() -> any ConversationSummaryProviding)?,
         makeLocal: @escaping () -> any ConversationSummaryProviding,
         cooldown: SummaryCloudCooldown = SummaryCloudCooldown()) {
        self.makeCloud = makeCloud; self.makeLocal = makeLocal; self.cooldown = cooldown
        backendDescription = makeCloud == nil ? "AI 脑图 · 仅在本机处理" : "AI 脑图 · 云端优先"
    }

    func prepare() async throws {
        try checkCancellation()
        if makeCloud == nil || !cooldown.allowsCloud { _ = try await prepareLocal() }
    }

    func summarize(_ text: String, previous: String,
                   onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        try await summarize(text, previous: previous, validating: { _ in }, onUpdate: onUpdate)
    }

    func summarize(_ text: String, previous: String,
                   validating validate: @escaping @MainActor (String) throws -> Void,
                   onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        try checkCancellation()
        if let makeCloud, cooldown.allowsCloud {
            // Cloud retries release any previous local worker before starting.
            local?.cancel(); local = nil
            let engine = cloud ?? makeCloud(); cloud = engine
            backendDescription = "AI 脑图 · 云端总结"
            do {
                try await engine.prepare()
                let output = try await engine.summarize(text, previous: previous, onUpdate: onUpdate)
                try checkCancellation()
                try validate(output)
                cooldown.succeeded()
                return output
            } catch SummaryError.mapCapacityReached {
                throw SummaryError.mapCapacityReached
            } catch {
                engine.cancel(); cloud = nil
                try checkCancellation()
                cooldown.failed()
                // Do not log NSError descriptions, URL requests, keys or text.
                AppLogger.log("Summary cloud unavailable; switching to local")
                backendDescription = "AI 脑图 · 云端不可用，使用本地"
                onUpdate("")
            }
        }
        let engine = try await prepareLocal()
        let output = try await engine.summarize(text, previous: previous, onUpdate: onUpdate)
        try checkCancellation()
        try validate(output)
        return output
    }

    private func prepareLocal() async throws -> any ConversationSummaryProviding {
        try checkCancellation()
        backendDescription = makeCloud == nil ? "AI 脑图 · 仅在本机处理" : "AI 脑图 · 云端不可用，使用本地"
        if let local { return local }
        let engine = makeLocal(); local = engine
        do { try await engine.prepare(); try checkCancellation(); return engine }
        catch { engine.cancel(); local = nil; throw error }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    func cancel() {
        cancelled = true
        cloud?.cancel(); cloud = nil
        local?.cancel(); local = nil
    }
}
