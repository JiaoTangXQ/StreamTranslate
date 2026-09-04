@preconcurrency import AVFoundation
import Foundation

@main
enum NemotronBenchmarkMain {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let audioPath = arguments.first else {
            print(
                "usage: StreamTranslateNemotronBench <audio-file> "
                    + "[--reference <text>] [--realtime] [--sessions <count>]"
            )
            Foundation.exit(2)
        }
        let realtime = arguments.contains("--realtime")
        let reference = value(after: "--reference", in: arguments)
        let sessionCount = max(
            1,
            Int(value(after: "--sessions", in: arguments) ?? "1") ?? 1
        )
        let samples = try load16kMonoSamples(
            from: URL(fileURLWithPath: audioPath)
        )
        let duration = Double(samples.count) / 16_000

        let clock = ContinuousClock()
        let loadStarted = clock.now
        let service = try await NemotronStreamingTranscriptionService.load()
        let loadDuration = seconds(loadStarted.duration(to: clock.now))
        print(String(format: "nemotron load=%.3fs sessions=%d", loadDuration, sessionCount))

        for sessionIndex in 1...sessionCount {
            try await runSession(
                sessionIndex,
                service: service,
                samples: samples,
                duration: duration,
                realtime: realtime,
                reference: reference
            )
        }
    }

    private static func runSession(
        _ sessionIndex: Int,
        service: NemotronStreamingTranscriptionService,
        samples: [Float],
        duration: TimeInterval,
        realtime: Bool,
        reference: String?
    ) async throws {
        let clock = ContinuousClock()
        let recognitionStarted = clock.now
        let stream = AsyncStream<CapturedAudioChunk> { continuation in
            Task {
                let chunkSize = 1_600
                let pacingClock = ContinuousClock()
                let pacingStarted = pacingClock.now
                var offset = 0
                var sequence: Int64 = 0
                while offset < samples.count {
                    let end = min(offset + chunkSize, samples.count)
                    continuation.yield(
                        CapturedAudioChunk(
                            samples: Array(samples[offset..<end]),
                            sequence: sequence,
                            capturedAt: .now,
                            sourceTimestamp: Double(offset) / 16_000
                        )
                    )
                    if realtime {
                        try? await pacingClock.sleep(
                            until: pacingStarted.advanced(
                                by: .seconds(Double(end) / 16_000)
                            )
                        )
                    }
                    offset = end
                    sequence += 1
                }
                continuation.finish()
            }
        }

        var firstResult: Double?
        var firstTranslationReady: Double?
        var firstText = ""
        var partialCount = 0
        var finals: [String] = []
        for try await update in service.updates(from: stream, vocabulary: "") {
            let elapsed = seconds(recognitionStarted.duration(to: clock.now))
            if firstResult == nil {
                firstResult = elapsed
                firstText = update.output.text
            }
            if firstTranslationReady == nil,
               normalizedWords(update.output.text).count >= 3 {
                firstTranslationReady = elapsed
            }
            if update.isFinal {
                finals.append(update.output.text)
            } else {
                partialCount += 1
            }
        }

        let wall = seconds(recognitionStarted.duration(to: clock.now))
        let text = finals.joined(separator: " ")
        print(
            String(
                format: "nemotron session=%d audio=%.3fs first=%.3fs "
                    + "translationReady=%.3fs wall=%.3fs endLag=%.3fs "
                    + "partials=%d finals=%d firstText=%@ text=%@",
                sessionIndex,
                duration,
                firstResult ?? -1,
                firstTranslationReady ?? -1,
                wall,
                realtime ? wall - duration : wall,
                partialCount,
                finals.count,
                firstText,
                text
            )
        )
        if let reference {
            print(
                String(
                    format: "nemotron session=%d WER=%.4f",
                    sessionIndex,
                    wordErrorRate(reference, text)
                )
            )
        }
    }

    private static func load16kMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
           let source = AVAudioPCMBuffer(
               pcmFormat: sourceFormat,
               frameCapacity: AVAudioFrameCount(file.length)
           ) else {
            throw NemotronBenchmarkError.audioConversionUnavailable
        }
        try file.read(into: source)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(
                ceil(Double(source.frameLength)
                    * targetFormat.sampleRate / sourceFormat.sampleRate)
            ) + 64
        ) else {
            throw NemotronBenchmarkError.audioConversionUnavailable
        }
        let inputState = NemotronBenchmarkInputState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, inputStatus in
            guard inputState.take() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error || conversionError != nil {
            throw conversionError ?? NemotronBenchmarkError.audioConversionUnavailable
        }
        guard let channel = output.floatChannelData?[0] else {
            throw NemotronBenchmarkError.audioConversionUnavailable
        }
        return Array(
            UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        )
    }

    private static func wordErrorRate(_ reference: String, _ hypothesis: String) -> Double {
        let expected = normalizedWords(reference)
        let actual = normalizedWords(hypothesis)
        guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
        var previous = Array(0...actual.count)
        for (expectedIndex, expectedWord) in expected.enumerated() {
            var current = [expectedIndex + 1]
            for (actualIndex, actualWord) in actual.enumerated() {
                current.append(min(
                    previous[actualIndex] + (expectedWord == actualWord ? 0 : 1),
                    previous[actualIndex + 1] + 1,
                    current[actualIndex] + 1
                ))
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(expected.count)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
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
}

private enum NemotronBenchmarkError: Error {
    case audioConversionUnavailable
}

private final class NemotronBenchmarkInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var supplied = false

    func take() -> Bool {
        lock.withLock {
            guard !supplied else { return false }
            supplied = true
            return true
        }
    }
}
