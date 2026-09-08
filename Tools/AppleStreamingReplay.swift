@preconcurrency import AVFoundation
import Foundation

// Standalone benchmark: reuse the production recognizer without writing app logs.
enum AppLogger {
    static func log(_ message: String) {}
}

@main
enum AppleStreamingReplay {
    static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            throw NSError(domain: "Usage: AppleStreamingReplay <16k-mono.wav> <en|zh> <id>", code: 2)
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "Expected 16 kHz mono WAV", code: 2)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "Float PCM unavailable", code: 2)
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let duration = Double(samples.count) / 16_000
        let language: SpokenLanguage = args[2] == "zh" ? .chinese : .english
        let service = AppleStreamingTranscriptionService(language: language)
        let clock = ContinuousClock()
        let loadStart = clock.now
        try await service.prepare()
        let loadSeconds = seconds(loadStart.duration(to: clock.now))
        try emit(["event": "loaded", "id": args[3], "model": "apple", "load_seconds": loadSeconds])
        let started = clock.now
        let (stream, continuation) = AsyncStream<CapturedAudioChunk>.makeStream()
        let feeder = Task {
            for offset in stride(from: 0, to: samples.count, by: 1600) {
                let end = min(samples.count, offset + 1600)
                // Audio becomes available only AFTER its actual arrival deadline.
                try await clock.sleep(until: started.advanced(by: .seconds(Double(end) / 16_000)))
                guard !Task.isCancelled else { break }
                continuation.yield(CapturedAudioChunk(samples: Array(samples[offset..<end]),
                    sequence: Int64(offset / 1600), capturedAt: .now,
                    sourceTimestamp: Double(offset) / 16_000))
            }
            continuation.finish()
        }
        defer { feeder.cancel(); continuation.finish(); service.cancel() }
        var first: Double?
        var prefixReady: Double?
        var finals: [String] = []
        var partialCount = 0
        for try await update in service.updates(from: stream, vocabulary: "") {
            let elapsed = seconds(started.duration(to: clock.now))
            let text = update.output.text
            if !text.isEmpty, first == nil { first = elapsed }
            let units = language == .chinese ? text.filter { $0.isLetter }.count
                : text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
            if prefixReady == nil, units >= (language == .chinese ? 4 : 3) { prefixReady = elapsed }
            if update.isFinal { finals.append(text) } else { partialCount += 1 }
            try emit(["event": update.isFinal ? "final" : "partial", "id": args[3],
                      "wall_seconds": elapsed, "audio_start": Double(update.startSample) / 16_000,
                      "audio_end": Double(update.endSample) / 16_000, "text": text])
        }
        try await feeder.value
        let wall = seconds(started.duration(to: clock.now))
        try emit(["event": "summary", "id": args[3], "model": "apple",
                  "language": args[2], "audio_seconds": duration, "load_seconds": loadSeconds,
                  "first_seconds": first ?? -1, "prefix_ready_seconds": prefixReady ?? -1,
                  "wall_seconds": wall, "end_lag_seconds": wall - duration,
                  "partials": partialCount, "finals": finals.count, "text": finals.joined(separator: " ")])
    }
}
