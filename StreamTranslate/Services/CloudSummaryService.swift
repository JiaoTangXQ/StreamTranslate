import Foundation

/// Summary text only. Uses an ephemeral HTTPS session; no transcript, key or
/// provider response body is written to logs or URL caches.
@MainActor final class CloudSummaryService: ConversationSummaryProviding {
    private let configuration: SummaryCloudConfiguration
    private let session: URLSession
    private var cancelled = false
    private var nextRequestAt = ContinuousClock.now

    init(configuration: SummaryCloudConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 15
            settings.timeoutIntervalForResource = 45
            settings.urlCache = nil
            self.session = URLSession(configuration: settings, delegate: SummaryRedirectGuard(), delegateQueue: nil)
        }
    }

    var backendDescription: String { "AI 脑图 · 云端总结" }
    var usesLocalModel: Bool { false }
    func prepare() async throws { try Task.checkCancellation(); if cancelled { throw CancellationError() } }

    func summarize(_ text: String, previous: String,
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
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "messages": try Self.messages(text, previous: previous),
            "response_format": ["type": "json_object"],
            "thinking": ["type": "disabled"],
            "max_tokens": configuration.maxTokens, "temperature": 0.2, "stream": true
        ])
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
            guard size <= 1_048_576 else { throw SummaryError.invalidResult }
            if try decoder.append(data), ContinuousClock.now - lastPublish >= .milliseconds(150) {
                onUpdate(decoder.text); lastPublish = .now
            }
        }
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let output = try Self.normalizedEnvelope(decoder.finish())
        onUpdate(output)
        return output
    }

    static func messages(_ text: String, previous: String) throws -> [[String: String]] {
        var messages = try LocalSummaryService.messages(text, previous: previous)
        let format = LocalSummaryService.responseFormat(previous: previous,
            recordCount: text.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count)
        let specification = format["json_schema"] as! [String: Any]
        let schema = try JSONSerialization.data(withJSONObject: specification["schema"]!, options: [.sortedKeys])
        messages[0]["content", default: ""] += "\n输出须满足以下JSON Schema。根对象只含additions；所有节点字段（尤其sources）都必须提供。不得将格式元数据或无关示例当作原文事实：\n" + String(decoding: schema, as: UTF8.self)
        return messages
    }

    /// Some compatible gateways echo response_format.type in the content.
    /// Remove only that known format marker, then validate every addition.
    static func normalizedEnvelope(_ text: String) throws -> String {
        guard var root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw SummaryError.invalidResult
        }
        if root["type"] as? String == "json_object" { root.removeValue(forKey: "type") }
        guard root.count == 1, root["additions"] is [[String: Any]] else { throw SummaryError.invalidResult }
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
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
