import Foundation
@preconcurrency import Translation

@main
enum TranslationBenchmarkMain {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let targetIdentifier = value(after: "--target", in: arguments) ?? "zh-Hans"
        let texts = try inputTexts(arguments: arguments)
        guard !texts.isEmpty else {
            FileHandle.standardError.write(Data("No input text\n".utf8))
            Foundation.exit(2)
        }

        let session = TranslationSession(
            installedSource: .init(identifier: "en"),
            target: .init(identifier: targetIdentifier)
        )
        guard await session.isReady else {
            FileHandle.standardError.write(
                Data("Apple English → \(targetIdentifier) translation assets are not installed\n".utf8)
            )
            Foundation.exit(3)
        }

        if arguments.contains("--batch") {
            try await runBatch(texts, session: session)
        } else {
            try await runSequential(texts, session: session)
        }
    }

    private static func runSequential(
        _ texts: [String],
        session: TranslationSession
    ) async throws {
        let clock = ContinuousClock()
        var durations: [Double] = []
        for (index, source) in texts.enumerated() {
            let startedAt = clock.now
            let response = try await session.translate(source)
            let duration = seconds(startedAt.duration(to: clock.now))
            durations.append(duration)
            print(
                String(
                    format: "[%02d] %.3fs\nEN: %@\nZH: %@",
                    index + 1,
                    duration,
                    source,
                    response.targetText
                )
            )
        }
        printSummary(durations, label: "sequential")
    }

    private static func runBatch(
        _ texts: [String],
        session: TranslationSession
    ) async throws {
        let requests = texts.enumerated().map { index, text in
            TranslationSession.Request(
                sourceText: text,
                clientIdentifier: String(index)
            )
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        var completionTimes: [Double] = []
        for try await response in session.translate(batch: requests) {
            let duration = seconds(startedAt.duration(to: clock.now))
            completionTimes.append(duration)
            print(
                String(
                    format: "[%@] %.3fs\nEN: %@\nZH: %@",
                    response.clientIdentifier ?? "?",
                    duration,
                    response.sourceText,
                    response.targetText
                )
            )
        }
        printSummary(completionTimes, label: "batch cumulative")
    }

    private static func inputTexts(arguments: [String]) throws -> [String] {
        guard let path = value(after: "--input", in: arguments) else {
            return defaultTexts
        }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        return contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func printSummary(_ values: [Double], label: String) {
        guard !values.isEmpty else { return }
        let ordered = values.sorted()
        let p50 = ordered[(ordered.count - 1) / 2]
        let p95Index = min(
            ordered.count - 1,
            Int(ceil(Double(ordered.count) * 0.95)) - 1
        )
        print(
            String(
                format: "%@ count=%d first=%.3fs p50=%.3fs p95=%.3fs max=%.3fs",
                label,
                values.count,
                values[0],
                p50,
                ordered[p95Index],
                ordered.last ?? 0
            )
        )
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    private static let defaultTexts = [
        "The deployment failed because the Kubernetes readiness probe timed out after the database migration.",
        "Please roll back the release, drain the queue, and keep the feature flag disabled until the incident review.",
        "The speaker clarified that Apple silicon uses unified memory, so the browser and the model compete for the same capacity.",
        "The decoder rejected the audio buffer because its frame boundaries were not aligned.",
        "Freeze the confirmed prefix, but allow the last two words to change when new audio arrives.",
        "A stale translation response must never overwrite a newer subtitle.",
        "The capture watchdog should rebuild the audio stream within five seconds after a device switch.",
        "End-to-end latency matters more than the model's advertised chunk size."
    ]
}
