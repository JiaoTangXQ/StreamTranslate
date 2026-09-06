@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Translation
import Darwin

/// Replays local PCM through the actual recognizer, caption model and translator.
/// The legacy comparison records old scheduling decisions on the SAME ASR trace;
/// it is not a claim that an old app was run concurrently.
@main enum EnhancementReplayMain {
    static func emit(_ fields: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    static func legacyShouldRequest(previous: String, prefix: String, language: SpokenLanguage) -> Bool {
        let text = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != previous else { return false }
        let growth = CaptionTextStabilizer.semanticUnitCount(in: text) - CaptionTextStabilizer.semanticUnitCount(in: previous)
        return previous.isEmpty || !text.hasPrefix(previous)
            || growth >= (language == .chinese ? 10 : 5)
            || text.last.map { ".!?。！？;；:：".contains($0) } == true
    }

    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: EnhancementReplay <16k-mono.wav> <en|zh> [repeat-count] [--accurate]")
            exit(2)
        }
        let language: SpokenLanguage = args[2] == "zh" ? .chinese : .english
        let direction = TranslationDirection.forSource(language)!
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else {
            fatalError("Expected 16kHz mono audio")
        }
        try file.read(into: buffer)
        let original = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let repeats = args.count > 3 ? max(1, Int(args[3]) ?? 1) : 1
        var samples: [Float] = []
        for index in 0..<repeats {
            if index > 0 { samples += Array(repeating: 0, count: 19_200) }
            samples += original
        }
        let audioSeconds = Double(samples.count) / 16_000
        let loadStart = Date()
        let service: any StreamingTranscriptionProviding
        if args.contains("--nemotron") {
            guard language == .english else { fatalError("Nemotron comparison supports English only") }
            service = try await NemotronStreamingTranscriptionService.load()
        } else {
            let apple = AppleStreamingTranscriptionService(language: language, fastResults: !args.contains("--accurate"),
                boundedFinalization: !args.contains("--no-bounded-finalization"))
            try await apple.prepare()
            service = apple
        }
        let vm = CaptionViewModel()
        vm.startMemoryPressureMonitor()
        let modelOption = args.firstIndex(of: "--review-model")
        let modelURL = modelOption.flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let reviewer = args.contains("--review")
            ? LocalQwenService(modelURL: modelURL ?? LocalQwenService.root.appendingPathComponent("model.gguf")) : nil
        let reviewAudio = reviewer == nil ? nil : ReviewAudioBuffer()
        if let reviewer, let reviewAudio {
            try await reviewer.prepare()
            vm.configureRecognitionReview(reviewer, audio: reviewAudio)
        }
        let refinementOption = args.firstIndex(of: "--refine-model")
        let refinementURL = refinementOption.flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let refiner = args.contains("--refine")
            ? LocalHYTranslationService(modelURL: refinementURL ?? LocalHYTranslationService.root.appendingPathComponent("model.gguf")) : nil
        if let refiner {
            try await refiner.prepare()
            vm.configureTranslationRefinement(refiner)
        }
        let target = language == .english ? "zh-Hans" : "en"
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: .init(identifier: language.rawValue),
                                         target: .init(identifier: target), preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: .init(identifier: language.rawValue),
                                         target: .init(identifier: target))
        }
        guard await session.isReady else { fatalError("Translation assets not installed") }
        vm.translationService.setSession(session, for: direction)
        let logger = try MeetingSessionLogger(source: .systemAudio,
            rootDirectory: URL(fileURLWithPath: "build/enhancement-replay/evidence", isDirectory: true))
        let queue = PartialTranslationQueue()
        vm.startPartialTranslationWorker(queue, logger: logger)
        emit(["event":"prepared","language":language.rawValue,"backend":args.contains("--nemotron") ? "nemotron" : "apple",
              "seconds":Date().timeIntervalSince(loadStart),
              "audio_seconds":audioSeconds,"evidence":logger.directoryURL.path])
        let start = Date()
        let monotonicStart = ContinuousClock.now
        var firstOriginal: Double?
        var firstTranslation: Double?
        var lastPresentation = ""
        var lastChangedAt = 0.0
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                let history = vm.captionHistory.map { $0.englishText + " | " + $0.chineseText }.joined(separator: "\n")
                let current = history + "\n" + vm.streamingOriginalText + " | " + vm.streamingTranslatedText
                if current != lastPresentation {
                    lastPresentation = current
                    lastChangedAt = Date().timeIntervalSince(start)
                    if firstTranslation == nil,
                       !vm.streamingTranslatedText.isEmpty || vm.captionHistory.contains(where: {
                           language == .english ? !$0.chineseText.isEmpty : !$0.englishText.isEmpty
                       }) {
                        firstTranslation = lastChangedAt
                    }
                    emit(["event":"visible","elapsed":lastChangedAt,"text":current])
                }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
        }
        let audio = AsyncStream<CapturedAudioChunk> { continuation in
            Task {
                for offset in stride(from: 0, to: samples.count, by: 1600) {
                    let end = min(offset + 1600, samples.count)
                    try? await ContinuousClock().sleep(until: monotonicStart.advanced(by: .seconds(Double(end)/16_000)))
                    let chunk = CapturedAudioChunk(samples: Array(samples[offset..<end]),
                        sequence: Int64(offset/1600), capturedAt: .now,
                        sourceTimestamp: Double(offset)/16_000)
                    logger.recordAudioChunk(chunk)
                    reviewAudio?.append(chunk.samples)
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
        var legacy = CaptionTextStabilizer()
        var legacySegment: Int64?
        var legacyRequested = ""
        var legacyCount = 0
        for try await update in service.updates(from: audio, vocabulary: "") {
            let elapsed = Date().timeIntervalSince(start)
            if firstOriginal == nil { firstOriginal = elapsed }
            emit(["event":"asr","elapsed":elapsed,"text":update.output.text,
                  "final":update.isFinal,"start_sample":update.startSample,"end_sample":update.endSample])
            if legacySegment != update.startSample {
                legacy.reset(); legacyRequested = ""; legacySegment = update.startSample
            }
            if !update.isFinal {
                let shown = legacy.update(text: update.output.text, segmentStartSample: update.startSample,
                    language: language, evidenceEndSample: update.endSample)
                let conservative = legacy.conservativeTranslationPrefix(in: update.output.text, language: language)
                let prefix = CaptionTextStabilizer.semanticUnitCount(in: conservative) > CaptionTextStabilizer.semanticUnitCount(in: shown.stable) ? conservative : shown.stable
                emit(["event":"eligible_prefix","elapsed":elapsed,"text":prefix,"start_sample":update.startSample])
                if legacyShouldRequest(previous: legacyRequested, prefix: prefix, language: language) {
                    legacyCount += 1; legacyRequested = prefix
                    emit(["event":"legacy_request","elapsed":elapsed,"text":prefix,"start_sample":update.startSample])
                }
            } else {
                legacyRequested = ""; legacy.reset(); legacySegment = nil
            }
            await vm.processStreamingUpdate(update, logger: logger, partialTranslations: queue)
        }
        await queue.finish()
        await vm.waitForFinalTranslations()
        try await Task.sleep(for: .milliseconds(30))
        observer.cancel()
        await observer.value
        logger.finish(); logger.flush()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        emit(["event":"summary","language":language.rawValue,"audio_seconds":audioSeconds,
              "first_original":firstOriginal ?? -1,"first_translation":firstTranslation ?? -1,
              "last_visible_lag":lastChangedAt-audioSeconds,"wall_seconds":Date().timeIntervalSince(start),
              "legacy_partial_requests":legacyCount,"captions":vm.captionHistory.map {
                  ["english":$0.englishText,"chinese":$0.chineseText]
              },"process_peak_rss_bytes":usage.ru_maxrss,"status":vm.statusMessage])
        vm.clearHistory()
        service.cancel()
        reviewer?.cancel()
        refiner?.cancel()
    }
}
