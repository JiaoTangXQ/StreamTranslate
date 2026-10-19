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
    #expect(config?.maxTokens == 2048)
    var invalid = values; invalid["OPENAI_BASE_URL"] = "http://summary.example/v1"
    #expect(SummaryCloudConfiguration(values: invalid) == nil)
    invalid["CHAT_COMPLETIONS_INSECURE_TLS"] = "true"
    #expect(SummaryCloudConfiguration(values: invalid) == nil)
    invalid = values; invalid["OPENAI_BASE_URL"] = "https://summary.example/v1?key=secret"
    #expect(SummaryCloudConfiguration(values: invalid) == nil)
    #expect(SummaryCloudConfiguration.load(environment: [:], files: []) == nil)
}

@MainActor private final class FailoverSummaryStub: ConversationSummaryProviding {
    var prepared = 0, requests: [(String, String)] = []
    var cancelled = false, fails = false, delay: Duration = .zero
    var output = "local-output"
    func prepare() async throws { prepared += 1 }
    func summarize(_ text: String, previous: String, onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        requests.append((text, previous)); onUpdate(output)
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
    #expect(try await service.summarize("new text", previous: "index") == "cloud-output")
    #expect(local.prepared == 0 && local.requests.isEmpty)
    #expect(!service.usesLocalModel)
    service.cancel()
    #expect(remote.cancelled)
}

@Test @MainActor func cloudFailureFallsBackWithSameInputAndCooldownReusesOneLocalWorker() async throws {
    let remote = FailoverSummaryStub(), local = FailoverSummaryStub()
    remote.fails = true
    let service = AutomaticSummaryService(makeCloud: { remote }, makeLocal: { local })
    var updates: [String] = []
    let output = try await service.summarize("[1] new source\n", previous: "T1|discussion|topic", onUpdate: { updates.append($0) })
    #expect(output == "local-output")
    #expect(local.requests.first?.0 == remote.requests.first?.0)
    #expect(local.requests.first?.1 == remote.requests.first?.1)
    #expect(updates.contains(""))
    #expect(service.backendDescription.contains("云端不可用"))
    #expect(try await service.summarize("second source", previous: "index") == "local-output")
    #expect(remote.requests.count == 1 && local.prepared == 1 && local.requests.count == 2)
    service.cancel()
    #expect(local.cancelled && remote.cancelled)
}

@Test @MainActor func malformedCloudPatchFallsBackBeforeCommittingAnyResult() async throws {
    let remote = FailoverSummaryStub(), local = FailoverSummaryStub()
    remote.output = "bad-patch"
    let service = AutomaticSummaryService(makeCloud: { remote }, makeLocal: { local })
    let output = try await service.summarize("new source", previous: "index", validating: { value in
        if value == "bad-patch" { throw SummaryError.invalidResult }
    }, onUpdate: { _ in })
    #expect(output == "local-output")
    #expect(local.prepared == 1)
}

@Test @MainActor func cancellingCloudRequestCannotStartLocalFallbackEvenIfBackendReturnsLate() async throws {
    let remote = FailoverSummaryStub(), local = FailoverSummaryStub()
    remote.delay = .milliseconds(60)
    let service = AutomaticSummaryService(makeCloud: { remote }, makeLocal: { local })
    let request = Task { try await service.summarize("source", previous: "") }
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
    #expect(try await service.summarize("source", previous: "") == "local-output")
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
            let patch: String
            if request.url!.host!.hasPrefix("dedup-") {
                patch = number == 1 ? #"{"additions":[{"topic":"T1","kind":"discussion","title":"编程AI","branch":"B1","text":"缺少代码数据就无法训练","detail":"","match":"","sources":[1]}]}"# : #"{"duplicates":[{"index":1,"match":"P1"}]}"#
            } else {
                patch = #"{"additions":[{"topic":"new:1","kind":"discussion","title":"测试","branch":"要点","text":"中文事实。","sources":[1]}]}"#
            }
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

@Test @MainActor func cloudReviewsParaphrasesWithoutRewritingContentOrStartingLocalModel() async throws {
    var values = cloudValues()
    let host = "dedup-" + UUID().uuidString.lowercased() + ".example"
    values["OPENAI_BASE_URL"] = "https://" + host + "/v1"
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [SummaryWireURLProtocol.self]
    let service = CloudSummaryService(configuration: SummaryCloudConfiguration(values: values)!, session: URLSession(configuration: settings))
    defer { service.cancel() }
    let batch = SummaryBatch(records: [.init(sourceID: UUID(), text: "Coding AI needs code data.\n")])
    let map = try ConversationMindMap().adding(#"{"topic":"new:1","kind":"discussion","title":"编程AI","branch":"训练数据","text":"足量代码数据是训练前提","sources":[1]}"#, batch: batch)
    let repeated = SummaryBatch(records: [.init(sourceID: UUID(), text: "Without code data, coding AI cannot be trained.\n")])
    let output = try await service.summarize(repeated.input, previous: map.context())
    let next = try map.adding(output, batch: repeated)
    #expect(SummaryWireRequests.shared.count(host) == 2)
    #expect(next.topics[0].branches[0].points.count == 1)
    #expect(next.topics[0].branches[0].points[0].id == map.topics[0].branches[0].points[0].id)
    #expect(next.topics[0].branches[0].points[0].sources.count == 2)
    #expect(!service.usesLocalModel)
}

@Test @MainActor func duplicateReviewCannotRewriteOrReferenceOtherBranches() throws {
    let output = #"{"additions":[{"topic":"T1","kind":"discussion","branch":"B1","text":"尚未确认的数据量","detail":"","match":"","sources":[1]}]}"#
    let context = "T1|discussion|编程AI\n B1|训练数据\n  P1|{}\n B2|能力\n  P2|{}"
    for review in [#"{"duplicates":[{"index":1,"match":"P2"}]}"#, #"{"duplicates":[{"index":2,"match":"P1"}]}"#, #"{"duplicates":[{"index":1,"match":"P1","text":"擅自改写"}]}"#, #"{"duplicates":[{"index":1,"match":"P1"},{"index":1,"match":"P1"}]}"#] {
        #expect(throws: SummaryError.self) { try CloudSummaryService.applyingDuplicateReview(review, to: output, previous: context) }
    }
    let retained = try CloudSummaryService.applyingDuplicateReview(#"{"duplicates":[]}"#, to: output, previous: context)
    #expect(retained.contains("尚未确认的数据量"))
    #expect(try CloudSummaryService.duplicateReviewMessages(output, source: "new", previous: "T1|discussion|编程AI") == nil)
}

@Test @MainActor func cloudSummaryHTTPUsesConfiguredEndpointAndDecodesSplitUnicodeSSE() async throws {
    var values = cloudValues()
    let host = "roundtrip-" + UUID().uuidString.lowercased() + ".example"
    values["OPENAI_BASE_URL"] = "https://" + host + "/v1"
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [SummaryWireURLProtocol.self]
    let service = CloudSummaryService(configuration: SummaryCloudConfiguration(values: values)!, session: URLSession(configuration: settings))
    defer { service.cancel() }
    let output = try await service.summarize("[1] Source fact\n", previous: "")
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
    do { _ = try await service.summarize("[1] Source\n", previous: ""); Issue.record("Accepted HTTP 401") }
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

@Test @MainActor func harmlessCloudFormatMarkerIsRemovedWithoutDiscardingInvalidNodes() throws {
    let response = #"{"type":"json_object","additions":[{"topic":"new:1","kind":"discussion","title":"记忆","branch":"要点","text":"海马体参与记忆。","sources":[1]}]}"#
    let normalized = try CloudSummaryService.normalizedEnvelope(response)
    let batch = SummaryBatch(records: [.init(sourceID: UUID(), text: "海马体参与记忆。\n")])
    let map = try ConversationMindMap().adding(normalized, batch: batch)
    #expect(map.topics[0].branches[0].points[0].text == "海马体参与记忆。")
    let invalid = try CloudSummaryService.normalizedEnvelope(response.replacingOccurrences(of: "[1]", with: "[2]"))
    #expect(throws: SummaryError.self) { try ConversationMindMap().adding(invalid, batch: batch) }
    #expect(throws: SummaryError.self) { try CloudSummaryService.normalizedEnvelope(#"{"type":"other","additions":[]}"#) }
    #expect(throws: SummaryError.self) { try CloudSummaryService.normalizedEnvelope(#"{"additions":[],"other":[]}"#) }
}
