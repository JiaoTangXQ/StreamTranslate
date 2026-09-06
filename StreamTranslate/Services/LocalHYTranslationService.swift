import Foundation
import Darwin

@MainActor protocol TranslationRefinementProviding: AnyObject {
    var isReady: Bool { get }
    func translate(_ text: String, sourceLanguage: SpokenLanguage, target: TranslationTarget, context: String) async throws -> String
    func cancel()
}

/// Native llama.cpp over a private Unix socket, not a network listening port.
/// Apple Translation remains the fast path and the fallback.
@MainActor final class LocalHYTranslationService: TranslationRefinementProviding {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StreamTranslate/HyMT")
    static var assets: LocalModelAssets? { .resolve(name: "HyMT", executableName: "llama-server") }
    static var isInstalled: Bool { assets != nil }
    private(set) var isReady = false
    private var cancelled = false
    private var process: Process?
    private let modelURL: URL
    private let executableURL: URL
    private let folder = URL(fileURLWithPath: "/tmp/streamtranslate-hy-" + UUID().uuidString.prefix(12))
    private var socket: String { folder.appendingPathComponent("translate.sock").path }

    init(modelURL: URL? = nil) {
        let assets = Self.assets
        self.modelURL = modelURL ?? assets?.model ?? Self.root.appendingPathComponent("model.gguf")
        self.executableURL = assets?.executable ?? Self.root.appendingPathComponent("runtime/llama-server")
    }

    func prepare() async throws {
        guard !cancelled, FileManager.default.isExecutableFile(atPath: executableURL.path),
              FileManager.default.isReadableFile(atPath: modelURL.path) else { throw LocalReviewError.unavailable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["-m", modelURL.path,
            "--host", socket, "-ngl", "99", "-c", "2048", "-t", "4", "-np", "1",
            "--jinja", "--no-webui", "--log-disable"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline, !cancelled, child.isRunning {
            if let data = try? await request("/health", body: nil, timeout: 1),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               json["status"] == "ok" {
                isReady = !cancelled
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        cancel()
        throw LocalReviewError.unavailable
    }

    static func prompt(_ text: String, sourceLanguage: SpokenLanguage = .english,
                       target: TranslationTarget, context: String = "") -> String {
        let source = TranslationIntegrityPolicy.resolvedEllipsis(text, context: context, language: sourceLanguage) ?? text
        let language = sourceLanguage == .chinese ? "English"
            : (target == .simplifiedChinese ? "Chinese" : "Traditional Chinese (Taiwan)")
        let terms: [(String, String)] = [
            ("model weights", "模型权重"), ("key-value cache", "键值缓存"),
            ("key value cache", "键值缓存"), ("cache eviction", "缓存淘汰"),
            ("readiness probe", "就绪探针"), ("feature flag", "功能开关"),
            ("eventual consistency", "最终一致性"), ("memory leak", "内存泄漏")
        ]
        // The English glossary was evaluated against the same prompt. Do not
        // silently reverse it for Chinese: that changes generation behavior.
        let directionalTerms = sourceLanguage == .english
            ? terms + contextualTerminology(for: source, context: context) : []
        let matched = directionalTerms.filter { source.localizedCaseInsensitiveContains($0.0) }.map { source, translation in
            let translated = target == .simplifiedChinese ? translation
                : (translation.applyingTransform(.init("Hans-Hant"), reverse: false) ?? translation)
            return "\(source) -> \(translated)"
        }
        let terminology = matched.isEmpty ? "" : "Use the following terminology:\n" + matched.joined(separator: "\n") + "\n\n"
        let precision = TranslationIntegrityPolicy.precisionInstruction(for: source, language: sourceLanguage)
        return terminology + precision + "Translate the following text into \(language). Note that you should only output the translated result without any additional explanation:\n" + source
    }

    /// Pass a constrained term mapping, not free-form background, for a few
    /// ASR homophones in a clearly established software context. Cash/rent
    /// contexts veto the mapping. This refines translation, not the source ASR.
    static func contextualTerminology(for source: String, context: String) -> [(String, String)] {
        let domain = String(context.suffix(600)).lowercased().replacingOccurrences(of: "-", with: " ")
        guard ["memory leak", "model weights", "key value cache"].contains(where: { domain.contains($0) }),
              (domain + " " + source.lowercased()).range(
                of: #"\b(rent|rental|landlords?|tenants?|mortgages?|cash payments?)\b"#,
                options: .regularExpression) == nil else { return [] }
        return [("cash eviction", "缓存淘汰"), ("key value cash", "键值缓存"), ("key-value cash", "键值缓存")]
            .filter { source.localizedCaseInsensitiveContains($0.0) }
    }

    static func requestBody(_ text: String, sourceLanguage: SpokenLanguage,
                            target: TranslationTarget, context: String) -> [String: Any] {
        [
            "messages": [["role": "user", "content": Self.prompt(text, sourceLanguage: sourceLanguage, target: target, context: context)]],
            "temperature": 0.7, "top_p": 0.6, "top_k": 20, "repeat_penalty": 1.05,
            // Reuse only exact token prefixes. This is not conversation history:
            // each request still contains one self-contained translation prompt.
            // Two reverse-order 48-case comparisons preserved every output.
            "seed": 42, "max_tokens": 384, "stream": false, "cache_prompt": true
        ]
    }

    func translate(_ text: String, sourceLanguage: SpokenLanguage, target: TranslationTarget, context: String) async throws -> String {
        guard isReady, !cancelled, text.count <= 1600 else { throw LocalReviewError.unavailable }
        let body = Self.requestBody(text, sourceLanguage: sourceLanguage, target: target, context: context)
        let data = try await request("/v1/chat/completions", body: JSONSerialization.data(withJSONObject: body), timeout: 4)
        guard !cancelled,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = result["choices"] as? [[String: Any]], let choice = choices.first,
              choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any],
              let raw = message["content"] as? String else { throw LocalReviewError.invalidResponse }
        let translated = TranslationIntegrityPolicy.normalizedPercentUnits(
            raw.trimmingCharacters(in: .whitespacesAndNewlines), source: text)
        guard translated.count <= 1600,
              TranslationIntegrityPolicy.accepts(translated, for: text) else {
            throw LocalReviewError.invalidResponse
        }
        return translated
    }

    private func request(_ endpoint: String, body: Data?, timeout: Int) async throws -> Data {
        var arguments = ["--silent", "--show-error", "--fail", "--noproxy", "*",
            "--unix-socket", socket, "--max-time", String(timeout), "--max-filesize", "65536",
            "http://localhost" + endpoint]
        if body != nil { arguments += ["-H", "Content-Type: application/json", "--data-binary", "@-"] }
        return try await LocalCommand.run(arguments: arguments, input: body ?? Data(), timeout: Double(timeout + 1))
    }

    func cancel() {
        cancelled = true
        isReady = false
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Small bounded command adapter for macOS' bundled curl. Audio/text is passed
/// through private pipes, never through shell interpolation or command arguments.
private final class LocalCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    private func stop() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    static func run(arguments: [String], input: Data, timeout: Double) async throws -> Data {
        let control = LocalCommand()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try control.execute(arguments: arguments, input: input, timeout: timeout)) }
                    catch { control.stop(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.stop() }
    }

    private func execute(arguments: [String], input: Data, timeout: Double) throws -> Data {
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        child.arguments = arguments
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try child.run(); process = child
        }
        defer { if child.isRunning { child.terminate() } }
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        var data = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            var descriptor = pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 { if errno == EINTR { continue }; throw LocalReviewError.invalidResponse }
            if result > 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                if count == 0 {
                    child.waitUntilExit()
                    guard child.terminationStatus == 0 else { throw LocalReviewError.invalidResponse }
                    return data
                }
                guard count > 0 else { throw LocalReviewError.invalidResponse }
                data.append(contentsOf: bytes.prefix(count))
                guard data.count <= 65_536 else { throw LocalReviewError.invalidResponse }
            }
        }
        throw LocalReviewError.timeout
    }
}
