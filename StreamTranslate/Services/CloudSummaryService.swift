import Foundation

/// Summary text only. Uses an ephemeral HTTPS session; no transcript, key or
/// provider response body is written to logs or URL caches.
@MainActor final class CloudSummaryService: ConversationSummaryProviding {
    /// A few minutes of speech per request keeps catch-up to a few rounds.
    nonisolated static let inputBudget = 6_000
    private let configuration: SummaryCloudConfiguration
    private let session: URLSession
    private var cancelled = false
    private var nextRequestAt = ContinuousClock.now

    init(configuration: SummaryCloudConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            // Rewritten topics can take longer than the old single additions.
            settings.timeoutIntervalForRequest = 30
            settings.timeoutIntervalForResource = 120
            settings.urlCache = nil
            self.session = URLSession(configuration: settings, delegate: SummaryRedirectGuard(), delegateQueue: nil)
        }
    }

    var backendDescription: String { configuration.backendDescription }
    var usesLocalModel: Bool { false }
    var inputBudget: Int { Self.inputBudget }
    func prepare() async throws { try Task.checkCancellation(); if cancelled { throw CancellationError() } }

    func summarize(_ request: MindMapRequest,
                   onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        let output = try await complete(messages: Self.messages(request), onUpdate: onUpdate)
        onUpdate(output)
        return output
    }

    private func complete(messages: [[String: String]],
                          onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        try await ContinuousClock().sleep(until: nextRequestAt)
        try Task.checkCancellation()
        nextRequestAt = .now.advanced(by: .seconds(1 / configuration.requestsPerSecond))
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + configuration.apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.requestBody(configuration: configuration, messages: messages)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CloudSummaryError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var decoder = SummaryEventDecoder(), size = 0
        var lastPublish = ContinuousClock.now - .seconds(1)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            let data = Data((line + "\n").utf8); size += data.count
            guard size <= 4_194_304 else { throw SummaryError.invalidResult }
            if try decoder.append(data), ContinuousClock.now - lastPublish >= .milliseconds(250) {
                onUpdate(decoder.text); lastPublish = .now
            }
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        return try Self.normalizedEnvelope(decoder.finish())
    }

    static func requestBody(configuration: SummaryCloudConfiguration,
                            messages: [[String: String]], maxTokens: Int? = nil) throws -> Data {
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "response_format": ["type": "json_object"],
            "max_tokens": maxTokens ?? configuration.maxTokens, "temperature": 0.2, "stream": true
        ]
        if configuration.usesDeepSeekThinkingFlag {
            body["thinking"] = ["type": "disabled"]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func messages(_ request: MindMapRequest) -> [[String: String]] {
        MindMapPrompt.messages(request)
    }

    /// Some compatible gateways echo response_format.type in the content.
    /// Remove only that known format marker; the map validates the rest.
    static func normalizedEnvelope(_ text: String) throws -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = String(value.drop(while: { $0 != "\n" }))
            if value.hasSuffix("```") { value = String(value.dropLast(3)) }
        }
        guard var root = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw SummaryError.invalidResult
        }
        if root["type"] as? String == "json_object" { root.removeValue(forKey: "type") }
        if root["remove"] == nil { root["remove"] = [String]() }
        guard root.count == 2, root["topics"] is [[String: Any]], root["remove"] is [Any] else {
            throw SummaryError.invalidResult
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }

    func cancel() { cancelled = true; session.invalidateAndCancel() }
}

private final class SummaryRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward a credential-bearing request to another endpoint.
        completionHandler(nil)
    }
}

enum CloudSummaryError: Error { case http(Int) }
