import Foundation
import Testing
@testable import StreamTranslate

private func cloudValues() -> [String: String] {
    ["MODEL_PROVIDER": "zhizengzeng", "ZHIZENGZENG_OPENAI_API_KEY": "test-summary-key",
     "OPENAI_BASE_URL": "https://summary.example/v1", "OPENAI_MODEL": "deepseek-v4.1-flash",
     "CHAT_COMPLETIONS_MAX_TOKENS": "32768", "CHAT_COMPLETIONS_REQUESTS_PER_SECOND": "20"]
}

@Test func summaryEnvironmentIsParsedWithoutExecutingShellAndRequiresHTTPS() {
    let values = SummaryCloudConfiguration.parse("""
    # comments
    export MODEL_PROVIDER='zhizengzeng'
    ZHIZENGZENG_OPENAI_API_KEY="test-summary-key"
    OPENAI_BASE_URL=https://summary.example/v1 # endpoint
    OPENAI_MODEL=deepseek-v4.1-flash
    CHAT_COMPLETIONS_MAX_TOKENS=32768
    """)
    let config = SummaryCloudConfiguration(values: values)
    #expect(config?.baseURL.absoluteString == "https://summary.example/v1")
    #expect(config?.maxTokens == 4096)
    var invalid = values; invalid["OPENAI_BASE_URL"] = "http://summary.example/v1"
    #expect(SummaryCloudConfiguration(values: invalid) == nil)
    invalid["CHAT_COMPLETIONS_INSECURE_TLS"] = "true"
    #expect(SummaryCloudConfiguration(values: invalid) == nil)
    invalid = values; invalid["OPENAI_BASE_URL"] = "https://summary.example/v1?key=secret"
    #expect(SummaryCloudConfiguration(values: invalid) == nil)
    #expect(SummaryCloudConfiguration.load(environment: [:], files: []) == nil)
}

@Test func summarySupportsDeepSeekOpenAIAndLegacyZhizengzengConfigurations() {
    var deepseek = cloudValues()
    deepseek["MODEL_PROVIDER"] = "deepseek"
    deepseek.removeValue(forKey: "ZHIZENGZENG_OPENAI_API_KEY")
    deepseek["DEEPSEEK_API_KEY"] = "deepseek-summary-key"
    deepseek["OPENAI_BASE_URL"] = "https://api.deepseek.com"
    deepseek["OPENAI_MODEL"] = "deepseek-flash"
    let deepseekConfig = SummaryCloudConfiguration(values: deepseek)
    #expect(deepseekConfig?.provider == "deepseek")
    #expect(deepseekConfig?.apiKey == "deepseek-summary-key")
    #expect(deepseekConfig?.backendDescription.contains("DeepSeek") == true)
    #expect(deepseekConfig?.usesDeepSeekThinkingFlag == true)

    var openAI = deepseek
    openAI["MODEL_PROVIDER"] = "openai"
    openAI.removeValue(forKey: "DEEPSEEK_API_KEY")
    openAI["OPENAI_API_KEY"] = "openai-summary-key"
    openAI["OPENAI_BASE_URL"] = "https://api.openai.com/v1"
    openAI["OPENAI_MODEL"] = "gpt-4o-mini"
    let openAIConfig = SummaryCloudConfiguration(values: openAI)
    #expect(openAIConfig?.provider == "openai")
    #expect(openAIConfig?.apiKey == "openai-summary-key")
    #expect(openAIConfig?.backendDescription.contains("OpenAI") == true)
    #expect(openAIConfig?.usesDeepSeekThinkingFlag == false)

    let legacy = SummaryCloudConfiguration(values: cloudValues())
    #expect(legacy?.provider == "zhizengzeng")
    #expect(legacy?.apiKey == "test-summary-key")
}

private let sampleRequest = MindMapRequest(map: "[]", previousTail: "", newText: "new source",
    limits: MindMapLimits.forSession(minutes: 1, local: false), sessionMinutes: 1)

@MainActor private final class FailoverSummaryStub: ConversationSummaryProviding {
    var prepared = 0, requests: [MindMapRequest] = []
    var cancelled = false, fails = false, delay: Duration = .zero
    var output = "local-output"
    func prepare() async throws { prepared += 1 }
    func summarize(_ request: MindMapRequest, onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        requests.append(request); onUpdate(output)
        if delay > .zero { try? await Task.sleep(for: delay) }
        if fails { throw CloudSummaryError.http(429) }
        return output
    }
    func cancel() { cancelled = true }
}

@Test @MainActor func successfulCloudSummaryNeverPreparesLocalModel() async throws {
    let remote = FailoverSummaryStub(), local = FailoverSummaryStub()
    remote.output = "cloud-output"
    let service = AutomaticSummaryService(makeCloud: { remote }, makeLocal: { local })
    try await service.prepare()
    #expect(local.prepared == 0)
    #expect(try await service.summarize(sampleRequest) == "cloud-output")
    #expect(local.prepared == 0 && local.requests.isEmpty)
    #expect(!service.usesLocalModel)
    #expect(service.inputBudget == CloudSummaryService.inputBudget)
    service.cancel()
    #expect(remote.cancelled)
}

@Test @MainActor func cloudFailureFallsBackWithSameInputAndCooldownReusesOneLocalWorker() async throws {
    let remote = FailoverSummaryStub(), local = FailoverSummaryStub()
    remote.fails = true
    let service = AutomaticSummaryService(makeCloud: { remote }, makeLocal: { local })
    var updates: [String] = []
    let output = try await service.summarize(sampleRequest, onUpdate: { updates.append($0) })
    #expect(output == "local-output")
    #expect(local.requests.first == remote.requests.first)
    #expect(updates.contains(""))
    #expect(service.backendDescription.contains("云端不可用"))
    #expect(service.usesLocalModel)
    #expect(service.inputBudget == LocalSummaryService.inputBudget)
    #expect(try await service.summarize(sampleRequest) == "local-output")
    #expect(remote.requests.count == 1 && local.prepared == 1 && local.requests.count == 2)
    service.cancel()
    #expect(local.cancelled && remote.cancelled)
}

@Test @MainActor func cloudFailureWithACloudSizedBatchAsksForALocalSizedRetry() async throws {
    let remote = FailoverSummaryStub(), local = FailoverSummaryStub()
    remote.fails = true
    let service = AutomaticSummaryService(makeCloud: { remote }, makeLocal: { local })
    let large = MindMapRequest(map: "[]", previousTail: "", newText: String(repeating: "x", count: 3_000),
        limits: MindMapLimits.forSession(minutes: 1, local: false), sessionMinutes: 1)
    do { _ = try await service.summarize(large); Issue.record("Oversized local fallback was attempted") }
    catch SummaryError.retryWithLocalBudget { }
    #expect(local.requests.isEmpty)
    #expect(service.inputBudget == LocalSummaryService.inputBudget)
}

@Test @MainActor func malformedCloudRevisionFallsBackBeforeCommittingAnyResult() async throws {
    let remote = FailoverSummaryStub(), local = FailoverSummaryStub()
    remote.output = "bad-patch"
    let service = AutomaticSummaryService(makeCloud: { remote }, makeLocal: { local })
    let output = try await service.summarize(sampleRequest, validating: { value in
        if value == "bad-patch" { throw SummaryError.invalidResult }
    }, onUpdate: { _ in })
    #expect(output == "local-output")
    #expect(local.prepared == 1)
}

@Test @MainActor func cancellingCloudRequestCannotStartLocalFallbackEvenIfBackendReturnsLate() async throws {
    let remote = FailoverSummaryStub(), local = FailoverSummaryStub()
    remote.delay = .milliseconds(60)
    let service = AutomaticSummaryService(makeCloud: { remote }, makeLocal: { local })
    let request = Task { try await service.summarize(sampleRequest) }
    for _ in 0..<100 {
        if !remote.requests.isEmpty { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    service.cancel(); request.cancel()
    do { _ = try await request.value; Issue.record("Cancelled summary returned a result") }
    catch is CancellationError { }
    #expect(local.prepared == 0)
}

@Test @MainActor func unavailableCloudConfigurationUsesExistingLocalProvider() async throws {
    let local = FailoverSummaryStub()
    let service = AutomaticSummaryService(makeCloud: nil, makeLocal: { local })
    try await service.prepare()
    #expect(try await service.summarize(sampleRequest) == "local-output")
    #expect(local.prepared == 1)
    #expect(service.backendDescription.contains("仅在本机"))
    service.cancel()
}

private final class SummaryWireRequests: @unchecked Sendable {
    static let shared = SummaryWireRequests()
    private let lock = NSLock()
    private var requests: [String: URLRequest] = [:]
    private var counts: [String: Int] = [:]
    @discardableResult func put(_ request: URLRequest) -> Int {
        lock.withLock {
            let host = request.url!.host!
            requests[host] = request; counts[host, default: 0] += 1
            return counts[host]!
        }
    }
    func get(_ host: String) -> URLRequest? { lock.withLock { requests[host] } }
    func count(_ host: String) -> Int { lock.withLock { counts[host, default: 0] } }
}

private final class SummaryWireURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let number = SummaryWireRequests.shared.put(request)
        let status = request.url!.host!.hasPrefix("unauthorized") ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 {
            let patch = #"{"topics":[{"id":"","kind":"discussion","title":"测试","summary":"","branches":[{"title":"内容","points":[{"text":"中文事实。","detail":""}]}]}],"remove":[]}"#
            let frames: [[String: Any]] = [
                ["choices": [["delta": ["content": patch], "finish_reason": NSNull()]]],
                ["choices": [["delta": [:], "finish_reason": "stop"]]]
            ]
            let data = frames.reduce(into: Data()) { result, frame in
                result.append(Data("data: ".utf8))
                result.append(try! JSONSerialization.data(withJSONObject: frame))
                result.append(Data("\n\n".utf8))
            }
            for offset in stride(from: 0, to: data.count, by: 3) {
                client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 3, data.count)))
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test @MainActor func openAICompatibleRequestsDoNotSendDeepSeekOnlyFields() async throws {
    var values = cloudValues()
    values["MODEL_PROVIDER"] = "openai"
    values.removeValue(forKey: "ZHIZENGZENG_OPENAI_API_KEY")
    values["OPENAI_API_KEY"] = "openai-summary-key"
    let host = "openai-" + UUID().uuidString.lowercased() + ".example"
    values["OPENAI_BASE_URL"] = "https://" + host + "/v1"
    values["OPENAI_MODEL"] = "gpt-4o-mini"
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [SummaryWireURLProtocol.self]
    let service = CloudSummaryService(configuration: SummaryCloudConfiguration(values: values)!, session: URLSession(configuration: settings))
    defer { service.cancel() }
    _ = try await service.summarize(sampleRequest)
    let sent = try #require(SummaryWireRequests.shared.get(host))
    let config = try #require(SummaryCloudConfiguration(values: values))
    let body = try CloudSummaryService.requestBody(configuration: config, messages: [], maxTokens: nil)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == "gpt-4o-mini")
    #expect(object["thinking"] == nil)
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer openai-summary-key")
}

@Test @MainActor func cloudSummaryHTTPUsesConfiguredEndpointAndDecodesSplitUnicodeSSE() async throws {
    var values = cloudValues()
    let host = "roundtrip-" + UUID().uuidString.lowercased() + ".example"
    values["OPENAI_BASE_URL"] = "https://" + host + "/v1"
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [SummaryWireURLProtocol.self]
    let service = CloudSummaryService(configuration: SummaryCloudConfiguration(values: values)!, session: URLSession(configuration: settings))
    defer { service.cancel() }
    let output = try await service.summarize(sampleRequest)
    #expect(output.contains("中文事实。"))
    #expect(!output.contains("�"))
    let sent = try #require(SummaryWireRequests.shared.get(host))
    #expect(sent.url?.path == "/v1/chat/completions")
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-summary-key")
    #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream")
}

@Test @MainActor func cloudHTTPErrorIsReportedWithoutProviderBodyOrCredentials() async throws {
    var values = cloudValues()
    values["OPENAI_BASE_URL"] = "https://unauthorized-" + UUID().uuidString.lowercased() + ".example/v1"
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [SummaryWireURLProtocol.self]
    let service = CloudSummaryService(configuration: SummaryCloudConfiguration(values: values)!, session: URLSession(configuration: settings))
    defer { service.cancel() }
    do { _ = try await service.summarize(sampleRequest); Issue.record("Accepted HTTP 401") }
    catch CloudSummaryError.http(let status) { #expect(status == 401) }
}

@Test func cloudUsageOnlyFramesDoNotRejectCompletedContentOrHideTruncation() throws {
    for suffix in [#"{"usage":{"completion_tokens":1},"choices":[]}"#,
                   #"{"usage":{"completion_tokens":1}}"#] {
        var decoder = SummaryEventDecoder()
        _ = try decoder.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"事实\"}}]}\n\n".utf8))
        _ = try decoder.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8))
        _ = try decoder.append(Data(("data: " + suffix + "\n\n").utf8))
        #expect(try decoder.finish() == "事实")
        var incomplete = SummaryEventDecoder()
        _ = try incomplete.append(Data(("data: " + suffix + "\n\n").utf8))
        #expect(throws: SummaryError.self) { try incomplete.finish() }
    }
}

@Test func privateSummaryFileOverridesUnrelatedProcessOpenAISettings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(".env")
    try cloudValues().map { "\($0.key)=\($0.value)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    let configuration = SummaryCloudConfiguration.load(environment: [
        "OPENAI_BASE_URL": "https://unrelated.example/v1", "OPENAI_MODEL": "unrelated-model"
    ], files: [file])
    #expect(configuration?.baseURL.host == "summary.example")
    #expect(configuration?.model == "deepseek-v4.1-flash")
}

@Test @MainActor func harmlessCloudFormatMarkerIsRemovedWithoutDiscardingTheRevision() throws {
    let response = #"{"type":"json_object","topics":[{"id":"","kind":"discussion","title":"记忆","summary":"","branches":[{"title":"机制","points":[{"text":"海马体参与记忆。","detail":""}]}]}]}"#
    let normalized = try CloudSummaryService.normalizedEnvelope(response)
    let map = try ConversationMindMap().applying(normalized, limits: MindMapLimits.forSession(minutes: 1, local: false)).map
    #expect(map.topics[0].branches[0].points[0].text == "海马体参与记忆。")
    #expect(try CloudSummaryService.normalizedEnvelope("```json\n" + response + "\n```").contains("海马体"))
    #expect(throws: SummaryError.self) { try CloudSummaryService.normalizedEnvelope(#"{"type":"other","topics":[]}"#) }
    #expect(throws: SummaryError.self) { try CloudSummaryService.normalizedEnvelope(#"{"topics":[],"remove":[],"other":[]}"#) }
    #expect(throws: (any Error).self) { try CloudSummaryService.normalizedEnvelope("not json") }
}
