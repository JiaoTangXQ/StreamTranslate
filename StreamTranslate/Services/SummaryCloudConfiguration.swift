import Foundation

/// Read only by the conversation-summary feature. Never changes translation settings.
struct SummaryCloudConfiguration: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
    let maxTokens: Int
    let requestsPerSecond: Double

    static var installedEnvironmentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StreamTranslate/Configuration/.env")
    }

    init?(values: [String: String]) {
        guard values["MODEL_PROVIDER"]?.lowercased() == "zhizengzeng",
              let key = values["ZHIZENGZENG_OPENAI_API_KEY"], !key.isEmpty,
              let rawURL = values["OPENAI_BASE_URL"], let url = URL(string: rawURL),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let model = values["OPENAI_MODEL"], !model.isEmpty else { return nil }
        baseURL = url; apiKey = key; self.model = model
        // Eight compact additions do not need a 32K response budget.
        maxTokens = min(2_048, max(256, Int(values["CHAT_COMPLETIONS_MAX_TOKENS"] ?? "") ?? 2_048))
        requestsPerSecond = min(20, max(0.1, Double(values["CHAT_COMPLETIONS_REQUESTS_PER_SECOND"] ?? "") ?? 1))
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
