@preconcurrency import AVFoundation
import Foundation

@main
enum ASRBenchmarkMain {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let audioPath = arguments.first else {
            print(
                "usage: StreamTranslateASRBench <audio-file> "
                    + "[--reference <text>] [--realtime] [--repeat <count>] "
                    + "[--gap-seconds <seconds>] [--apple-only|--whisper-only]"
            )
            Foundation.exit(2)
        }
        let realtime = arguments.contains("--realtime")
        let repeatCount = max(1, Int(value(after: "--repeat", in: arguments) ?? "1") ?? 1)
        let gapSeconds = max(
            0,
            Double(value(after: "--gap-seconds", in: arguments) ?? "0") ?? 0
        )
        let baseReference = value(after: "--reference", in: arguments)
        let baseSamples = try load16kMonoSamples(
            from: URL(fileURLWithPath: audioPath)
        )
        let samples = repeatedSamples(
            baseSamples,
            count: repeatCount,
            gapSeconds: gapSeconds
        )
        let reference = baseReference.map {
            Array(repeating: $0, count: repeatCount).joined(separator: " ")
        }
        let duration = Double(samples.count) / 16_000
        print(
            String(
                format: "audio duration=%.3fs samples=%d repeat=%d gap=%.3fs",
                duration,
                samples.count,
                repeatCount,
                gapSeconds
            )
        )

        if !arguments.contains("--whisper-only") {
            try await benchmarkApple(
                samples: samples,
                duration: duration,
                realtime: realtime,
                reference: reference
            )
        }
        if !arguments.contains("--apple-only") {
            try await benchmarkWhisper(samples: samples, reference: reference)
        }
    }

    private static func benchmarkApple(
        samples: [Float],
        duration: TimeInterval,
        realtime: Bool,
        reference: String?
    ) async throws {
        let service = AppleStreamingTranscriptionService()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let stream = AsyncStream<CapturedAudioChunk> { continuation in
            Task {
                let chunkSize = 1_600
                let pacingClock = ContinuousClock()
                let pacingStartedAt = pacingClock.now
                var sequence: Int64 = 0
                var offset = 0
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
                        let sourceEnd = Double(end) / 16_000
                        try? await pacingClock.sleep(
                            until: pacingStartedAt.advanced(
                                by: .seconds(sourceEnd)
                            )
                        )
                    }
                    offset = end
                    sequence += 1
                }
                continuation.finish()
            }
        }

        var firstResultSeconds: Double?
        var firstResultText: String?
        var firstTranslationReadySeconds: Double?
        var partialCount = 0
        var finals: [String] = []
        for try await update in service.updates(from: stream, vocabulary: "") {
            let elapsed = seconds(startedAt.duration(to: clock.now))
            if firstResultSeconds == nil {
                firstResultSeconds = elapsed
                firstResultText = update.output.text
            }
            if firstTranslationReadySeconds == nil,
               normalizedWords(update.output.text).count >= 3 {
                firstTranslationReadySeconds = elapsed
            }
            if update.isFinal {
                finals.append(update.output.text)
            } else {
                partialCount += 1
            }
        }
        let wall = seconds(startedAt.duration(to: clock.now))
        let text = finals.joined(separator: " ")
        let lag = realtime ? wall - duration : wall
        print(
            String(
                format: "apple first=%.3fs translationReady=%.3fs wall=%.3fs "
                    + "endLag=%.3fs partials=%d finals=%d firstText=%@ text=%@",
                firstResultSeconds ?? -1,
                firstTranslationReadySeconds ?? -1,
                wall,
                lag,
                partialCount,
                finals.count,
                firstResultText ?? "",
                text
            )
        )
        if let reference {
            print(String(format: "apple WER=%.4f", wordErrorRate(reference, text)))
        }
    }

    private static func benchmarkWhisper(
        samples: [Float],
        reference: String?
    ) async throws {
        let clock = ContinuousClock()
        let loadStarted = clock.now
        let service = try await WhisperTranscriptionService.load(
            modelId: ASRModelID.whisperSmall
        )
        let load = seconds(loadStarted.duration(to: clock.now))
        let inferenceStarted = clock.now
        let output = try await service.transcribe(
            samples,
            languageHint: .english
        )
        let inference = seconds(inferenceStarted.duration(to: clock.now))
        let text = output?.text ?? ""
        print(
            String(
                format: "whisper-small load=%.3fs inference=%.3fs text=%@",
                load,
                inference,
                text
            )
        )
        if let reference {
            print(String(format: "whisper-small WER=%.4f", wordErrorRate(reference, text)))
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
        ), let converter = AVAudioConverter(
            from: sourceFormat,
            to: targetFormat
        ) else {
            throw BenchmarkError.audioConversionUnavailable
        }

        guard let source = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw BenchmarkError.audioBufferAllocationFailed
        }
        try file.read(into: source)
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(source.frameLength) * ratio)
        ) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw BenchmarkError.audioBufferAllocationFailed
        }

        let inputState = BenchmarkConverterInputState()
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
            throw conversionError ?? BenchmarkError.audioConversionUnavailable
        }
        guard let channel = output.floatChannelData?[0] else {
            throw BenchmarkError.audioBufferAllocationFailed
        }
        return Array(
            UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        )
    }

    private static func repeatedSamples(
        _ samples: [Float],
        count: Int,
        gapSeconds: Double
    ) -> [Float] {
        guard count > 1 else { return samples }
        let gap = [Float](
            repeating: 0,
            count: Int((gapSeconds * 16_000).rounded())
        )
        var result: [Float] = []
        result.reserveCapacity(samples.count * count + gap.count * (count - 1))
        for index in 0..<count {
            if index > 0 {
                result.append(contentsOf: gap)
            }
            result.append(contentsOf: samples)
        }
        return result
    }

    private static func wordErrorRate(_ reference: String, _ hypothesis: String) -> Double {
        let expected = normalizedWords(reference)
        let actual = normalizedWords(hypothesis)
        guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }

        var previous = Array(0...actual.count)
        for (expectedIndex, expectedWord) in expected.enumerated() {
            var current = [expectedIndex + 1]
            for (actualIndex, actualWord) in actual.enumerated() {
                let substitution = previous[actualIndex]
                    + (expectedWord == actualWord ? 0 : 1)
                let deletion = previous[actualIndex + 1] + 1
                let insertion = current[actualIndex] + 1
                current.append(min(substitution, deletion, insertion))
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

private enum ASRModelID {
    static let whisperSmall = "openai_whisper-small"
}

private enum BenchmarkError: Error {
    case audioConversionUnavailable
    case audioBufferAllocationFailed
}

private final class BenchmarkConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var supplied = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else { return false }
        supplied = true
        return true
    }
}
