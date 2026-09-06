import Foundation
@preconcurrency import Translation

/// Holds recognition outputs and their delivery times fixed while comparing
/// production caption/translation implementations. Translation is real and warm.
@main enum CaptionTraceReplayMain {
    static func emit(_ fields: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
    }
    @MainActor static func main() async throws {
        guard #available(macOS 26.4, *) else { exit(2) }
        let args = CommandLine.arguments
        guard args.count == 3 else { print("usage: CaptionTraceReplay <asr-jsonl> <en|zh>"); exit(2) }
        let language: SpokenLanguage = args[2] == "zh" ? .chinese : .english
        let direction = TranslationDirection.forSource(language)!
        let rows = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["event"] as? String == "asr" }
        guard !rows.isEmpty else { exit(3) }
        let vm = CaptionViewModel()
        let session = TranslationSession(installedSource: .init(identifier: language.rawValue),
            target: .init(identifier: language == .english ? "zh-Hans" : "en"), preferredStrategy: .lowLatency)
        guard await session.isReady else { exit(4) }
        _ = try await session.translate(language == .english ? "Ready." : "准备好了。")
        vm.translationService.setSession(session, for: direction)
        let logger = try MeetingSessionLogger(source: .systemAudio,
            rootDirectory: URL(fileURLWithPath: "build/refinement/trace-evidence", isDirectory: true))
        let queue = PartialTranslationQueue()
        vm.startPartialTranslationWorker(queue, logger: logger)
        let start = ContinuousClock.now
        func elapsed() -> Double {
            let d = start.duration(to: .now)
            return Double(d.components.seconds) + Double(d.components.attoseconds)/1e18
        }
        var last = ""
        var firstTranslation: Double?
        var visibleTranslationChanges = 0
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                let value = vm.captionHistory.map {
                    language == .english ? $0.chineseText : $0.englishText
                }.joined(separator:"\n") + "\n" + vm.streamingTranslatedText
                if value != last {
                    last = value
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        firstTranslation = firstTranslation ?? elapsed()
                        visibleTranslationChanges += 1
                        emit(["event":"translation_visible", "elapsed":elapsed(), "text":value,
                              "original":vm.streamingOriginalText])
                    }
                }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
        }
        for row in rows {
            try await ContinuousClock().sleep(until: start.advanced(by: .seconds(row["elapsed"] as! Double)))
            await vm.processStreamingUpdate(.init(output: .init(text: row["text"] as! String,
                language: language, reportedLanguageCode: language.rawValue, words: []),
                startSample: (row["start_sample"] as! NSNumber).int64Value,
                endSample: (row["end_sample"] as! NSNumber).int64Value,
                isFinal: row["final"] as! Bool, processingLatency: 0), logger: logger, partialTranslations: queue)
        }
        await queue.finish()
        await vm.waitForFinalTranslations()
        try await Task.sleep(for: .milliseconds(40))
        observer.cancel(); await observer.value
        logger.finish(); logger.flush()
        emit(["event":"summary", "first_translation":firstTranslation ?? -1,
              "visible_translation_changes":visibleTranslationChanges, "elapsed":elapsed(),
              "evidence":logger.directoryURL.path, "status":vm.statusMessage,
              "captions":vm.captionHistory.map { ["english":$0.englishText,"chinese":$0.chineseText] }])
        vm.clearHistory()
    }
}
