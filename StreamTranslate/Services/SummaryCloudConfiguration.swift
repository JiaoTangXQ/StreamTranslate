import Foundation

/// Read only by the conversation-summary feature. Never changes translation settings.
struct SummaryCloudConfiguration: Sendable {
    /// The provider label selects small request-format differences while all
    /// providers use the OpenAI-compatible Chat Completions transport.
    let provider: String
    let baseURL: URL
    let apiKey: String
    let model: String
    let maxTokens: Int
    let requestsPerSecond: Double

    var providerDisplayName: String {
        switch provider {
        case "deepseek": return "DeepSeek"
        case "openai": return "OpenAI"
        case "zhizengzeng": return "智增增"
        default: return provider
        }
    }

    var backendDescription: String { "AI 脑图 · \(providerDisplayName) 云端" }

    /// DeepSeek-compatible gateways use this extra-body flag to select the
    /// short non-thinking JSON response. OpenAI does not accept this field.
    var usesDeepSeekThinkingFlag: Bool {
        provider == "deepseek" || provider == "zhizengzeng"
    }

    static var installedEnvironmentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StreamTranslate/Configuration/.env")
    }

    init?(values: [String: String]) {
        guard let rawProvider = values["MODEL_PROVIDER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawProvider.isEmpty,
              rawProvider.count <= 40,
              rawProvider.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              let key = Self.apiKey(values: values, provider: rawProvider.lowercased()),
              let rawURL = values["OPENAI_BASE_URL"], let url = URL(string: rawURL),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let model = values["OPENAI_MODEL"], !model.isEmpty else { return nil }
        provider = rawProvider.lowercased()
        baseURL = url; apiKey = key; self.model = model
        // A revision rewrites only the topics it touches, but merging several
        // halves of a long session can exceed 2K tokens.
        maxTokens = min(4_096, max(512, Int(values["CHAT_COMPLETIONS_MAX_TOKENS"] ?? "") ?? 4_096))
        requestsPerSecond = min(20, max(0.1, Double(values["CHAT_COMPLETIONS_REQUESTS_PER_SECOND"] ?? "") ?? 1))
    }

    private static func apiKey(values: [String: String], provider: String) -> String? {
        let names: [String]
        switch provider {
        case "deepseek": names = ["DEEPSEEK_API_KEY", "OPENAI_API_KEY"]
        case "zhizengzeng": names = ["ZHIZENGZENG_OPENAI_API_KEY", "OPENAI_API_KEY"]
        default: names = ["OPENAI_API_KEY"]
        }
        for name in names {
            if let value = values[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     files: [URL]? = nil) -> Self? {
        let explicit = environment["STREAMTRANSLATE_SUMMARY_ENV"].map { URL(fileURLWithPath: $0) }
        let locations = files ?? (explicit.map { [$0] } ?? [installedEnvironmentURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")])
        var values = environment
        for file in locations {
            guard let data = try? Data(contentsOf: file), data.count <= 65_536,
                  let text = String(data: data, encoding: .utf8) else { continue }
            values.merge(parse(text)) { _, fileValue in fileValue }; break
        }
        return Self(values: values)
    }

    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if let first = value.first, (first == "\"" || first == "'"), value.last == first, value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
            values[name] = value
        }
        return values
    }
}
