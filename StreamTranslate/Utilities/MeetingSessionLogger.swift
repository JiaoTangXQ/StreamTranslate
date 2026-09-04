import Foundation
import Darwin

/// Keeps the evidence needed to distinguish capture gaps from segmentation,
/// recognition, and translation failures. Each recording session gets a
/// continuous WAV plus two JSONL event streams.
final class MeetingSessionLogger: @unchecked Sendable {
    private static let sampleRate = 16_000.0
    private static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumStoredBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    let directoryURL: URL
    let audioURL: URL
    let captureLogURL: URL
    let pipelineLogURL: URL

    private let queue = DispatchQueue(label: "com.jiaotangxq.StreamTranslate.session-log")
    private var audioFile: FileHandle?
    private var captureLog: FileHandle?
    private var pipelineLog: FileHandle?
    private var totalSamples: Int64 = 0
    private var audioDataBytes: UInt32 = 0
    private var lastSequence: Int64?
    private var lastSourceEndTime: Double?
    private var lastRuntimeSampleAt: TimeInterval?
    private var isFinished = false

    init(source: AudioInputSource, rootDirectory: URL? = nil) throws {
        let fileManager = FileManager.default
        let sessionsRoot = rootDirectory ?? Self.defaultSessionsRoot()
        try fileManager.createDirectory(
            at: sessionsRoot,
            withIntermediateDirectories: true
        )
        Self.pruneOldSessions(in: sessionsRoot, fileManager: fileManager)

        let sessionName = Self.sessionName()
        directoryURL = sessionsRoot.appendingPathComponent(
            sessionName,
            isDirectory: true
        )
        audioURL = directoryURL.appendingPathComponent("source-audio.wav")
        captureLogURL = directoryURL.appendingPathComponent("capture.jsonl")
        pipelineLogURL = directoryURL.appendingPathComponent("pipeline.jsonl")

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        fileManager.createFile(atPath: captureLogURL.path, contents: nil)
        fileManager.createFile(atPath: pipelineLogURL.path, contents: nil)
        captureLog = try FileHandle(forWritingTo: captureLogURL)
        pipelineLog = try FileHandle(forWritingTo: pipelineLogURL)

        fileManager.createFile(atPath: audioURL.path, contents: nil)
        audioFile = try FileHandle(forWritingTo: audioURL)
        audioFile?.write(Self.wavHeader(dataByteCount: 0))

        let started = SessionEvent(
            timestamp: Date().timeIntervalSince1970,
            event: "session_started",
            inputSource: source.rawValue,
            audioFile: audioURL.lastPathComponent
        )
        write(started, to: captureLog)
        write(started, to: pipelineLog)
    }

    func recordAudioChunk(_ chunk: CapturedAudioChunk) {
        queue.async { [self] in
            guard !isFinished else { return }

            let duration = Double(chunk.samples.count) / Self.sampleRate
            let sequenceGap = lastSequence.map {
                max(0, chunk.sequence - $0 - 1)
            } ?? 0
            let sourceGap: Double?
            if let sourceTimestamp = chunk.sourceTimestamp,
               let previousEnd = lastSourceEndTime {
                sourceGap = sourceTimestamp - previousEnd
            } else {
                sourceGap = nil
            }

            let event = CaptureEvent(
                timestamp: chunk.capturedAt.timeIntervalSince1970,
                event: "audio_chunk",
                sequence: chunk.sequence,
                sampleCount: chunk.samples.count,
                firstSample: totalSamples,
                endSample: totalSamples + Int64(chunk.samples.count),
                sourceTimestamp: chunk.sourceTimestamp,
                sourceGapSeconds: sourceGap,
                sequenceGap: sequenceGap
            )
            write(event, to: captureLog)
            writeAudio(chunk.samples)

            if lastRuntimeSampleAt == nil
                || chunk.capturedAt.timeIntervalSince1970
                    - (lastRuntimeSampleAt ?? 0) >= 5 {
                lastRuntimeSampleAt = chunk.capturedAt.timeIntervalSince1970
                write(
                    RuntimeMetricEvent(
                        timestamp: chunk.capturedAt.timeIntervalSince1970,
                        event: "runtime_sample",
                        physicalFootprintBytes: Self.physicalFootprintBytes()
                    ),
                    to: pipelineLog
                )
            }

            totalSamples += Int64(chunk.samples.count)
            lastSequence = chunk.sequence
            if let sourceTimestamp = chunk.sourceTimestamp {
                lastSourceEndTime = sourceTimestamp + duration
            }
        }
    }

    func recordCaptureStatus(_ event: String, detail: String) {
        queue.async { [self] in
            guard !isFinished else { return }
            write(
                CaptureStatusEvent(
                    timestamp: Date().timeIntervalSince1970,
                    event: event,
                    detail: detail
                ),
                to: captureLog
            )
        }
    }

    func recordSegment(_ stage: String, segment: SpeechSegment) {
        recordPipeline(
            PipelineEvent(
                timestamp: Date().timeIntervalSince1970,
                event: stage,
                segmentID: segment.startSample,
                startSample: segment.startSample,
                endSample: segment.endSample,
                sampleCount: segment.sampleCount,
                durationMilliseconds: nil,
                language: nil,
                reportedLanguage: nil,
                sourceText: nil,
                translatedText: nil,
                direction: nil,
                error: nil
            )
        )
    }

    func recordRecognition(
        _ stage: String,
        segment: SpeechSegment,
        output: TranscriptionOutput?,
        duration: TimeInterval
    ) {
        recordPipeline(
            PipelineEvent(
                timestamp: Date().timeIntervalSince1970,
                event: output == nil ? "\(stage)_empty" : stage,
                segmentID: segment.startSample,
                startSample: segment.startSample,
                endSample: segment.endSample,
                sampleCount: segment.sampleCount,
                durationMilliseconds: Int(duration * 1_000),
                language: output?.language.rawValue,
                reportedLanguage: output?.reportedLanguageCode,
                sourceText: output?.text,
                translatedText: nil,
                direction: nil,
                error: nil,
                averageLogProbability: output?.averageLogProbability,
                noSpeechProbability: output?.noSpeechProbability
            )
        )
    }

    func recordTranslation(
        _ stage: String,
        segment: SpeechSegment,
        sourceText: String,
        translatedText: String,
        direction: TranslationDirection,
        duration: TimeInterval
    ) {
        recordPipeline(
            PipelineEvent(
                timestamp: Date().timeIntervalSince1970,
                event: stage,
                segmentID: segment.startSample,
                startSample: segment.startSample,
                endSample: segment.endSample,
                sampleCount: segment.sampleCount,
                durationMilliseconds: Int(duration * 1_000),
                language: nil,
                reportedLanguage: nil,
                sourceText: sourceText,
                translatedText: translatedText,
                direction: String(describing: direction),
                error: nil
            )
        )
    }

    func recordPipelineError(
        _ stage: String,
        segment: SpeechSegment,
        error: String
    ) {
        recordPipeline(
            PipelineEvent(
                timestamp: Date().timeIntervalSince1970,
                event: stage,
                segmentID: segment.startSample,
                startSample: segment.startSample,
                endSample: segment.endSample,
                sampleCount: segment.sampleCount,
                durationMilliseconds: nil,
                language: nil,
                reportedLanguage: nil,
                sourceText: nil,
                translatedText: nil,
                direction: nil,
                error: error
            )
        )
    }

    func recordPipelineStatus(_ event: String, detail: String) {
        recordPipeline(
            PipelineStatusEvent(
                timestamp: Date().timeIntervalSince1970,
                event: event,
                detail: detail
            )
        )
    }

    func finish() {
        queue.async { [self] in
            guard !isFinished else { return }
            isFinished = true
            let finished = SessionEvent(
                timestamp: Date().timeIntervalSince1970,
                event: "session_finished",
                inputSource: nil,
                audioFile: nil
            )
            write(finished, to: captureLog)
            write(finished, to: pipelineLog)
            try? captureLog?.synchronize()
            try? pipelineLog?.synchronize()
            finalizeAudioFile()
            try? captureLog?.close()
            try? pipelineLog?.close()
            captureLog = nil
            pipelineLog = nil
        }
    }

    /// Used by tests and controlled shutdown paths that need all queued writes.
    func flush() {
        queue.sync {
            try? audioFile?.synchronize()
            try? captureLog?.synchronize()
            try? pipelineLog?.synchronize()
        }
    }

    private func recordPipeline<T: Encodable & Sendable>(_ event: T) {
        queue.async { [self] in
            guard !isFinished else { return }
            write(event, to: pipelineLog)
        }
    }

    private static func physicalFootprintBytes() -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    private func writeAudio(_ samples: [Float]) {
        guard !samples.isEmpty, let audioFile else { return }

        let pcm = samples.map { sample -> Int16 in
            let clamped = min(1, max(-1, sample))
            return Int16(clamped * Float(Int16.max)).littleEndian
        }
        do {
            let data = pcm.withUnsafeBytes { Data($0) }
            try audioFile.write(contentsOf: data)
            audioDataBytes &+= UInt32(pcm.count * MemoryLayout<Int16>.size)
        } catch {
            let event = CaptureFailureEvent(
                timestamp: Date().timeIntervalSince1970,
                event: "audio_write_failed",
                error: error.localizedDescription
            )
            write(event, to: captureLog)
        }
    }

    private func finalizeAudioFile() {
        guard let audioFile else { return }
        do {
            try audioFile.seek(toOffset: 0)
            try audioFile.write(contentsOf: Self.wavHeader(
                dataByteCount: audioDataBytes
            ))
            try audioFile.synchronize()
            try audioFile.close()
        } catch {
            let event = CaptureFailureEvent(
                timestamp: Date().timeIntervalSince1970,
                event: "audio_finalize_failed",
                error: error.localizedDescription
            )
            write(event, to: captureLog)
        }
        self.audioFile = nil
    }

    private static func wavHeader(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.reserveCapacity(44)
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(36 &+ dataByteCount, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * 2), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(dataByteCount, to: &data)
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    private func write<T: Encodable>(_ value: T, to handle: FileHandle?) {
        guard let handle,
              let data = try? JSONEncoder().encode(value) else { return }
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private static func defaultSessionsRoot() -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/StreamTranslate/Sessions", isDirectory: true)
    }

    private static func sessionName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8))"
    }

    private static func pruneOldSessions(
        in root: URL,
        fileManager: FileManager
    ) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey]
        guard var sessions = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-retentionInterval)
        for session in sessions {
            let values = try? session.resourceValues(forKeys: keys)
            if values?.isDirectory == true,
               let created = values?.creationDate,
               created < cutoff {
                try? fileManager.removeItem(at: session)
            }
        }

        sessions = sessions.filter { fileManager.fileExists(atPath: $0.path) }
        sessions.sort {
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left < right
        }

        var sizes = sessions.map { ($0, directorySize($0, fileManager: fileManager)) }
        var totalBytes = sizes.reduce(Int64.zero) { $0 + $1.1 }
        while totalBytes > maximumStoredBytes, !sizes.isEmpty {
            let oldest = sizes.removeFirst()
            if (try? fileManager.removeItem(at: oldest.0)) != nil {
                totalBytes -= oldest.1
            }
        }
    }

    private static func directorySize(
        _ directory: URL,
        fileManager: FileManager
    ) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var result: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey])
            result += Int64(values?.fileAllocatedSize ?? 0)
        }
        return result
    }
}

private struct SessionEvent: Encodable {
    let timestamp: TimeInterval
    let event: String
    let inputSource: String?
    let audioFile: String?
}

private struct CaptureEvent: Encodable {
    let timestamp: TimeInterval
    let event: String
    let sequence: Int64
    let sampleCount: Int
    let firstSample: Int64
    let endSample: Int64
    let sourceTimestamp: Double?
    let sourceGapSeconds: Double?
    let sequenceGap: Int64
}

private struct CaptureFailureEvent: Encodable {
    let timestamp: TimeInterval
    let event: String
    let error: String
}

private struct CaptureStatusEvent: Encodable {
    let timestamp: TimeInterval
    let event: String
    let detail: String
}

private struct PipelineStatusEvent: Encodable, Sendable {
    let timestamp: TimeInterval
    let event: String
    let detail: String
}

private struct RuntimeMetricEvent: Encodable, Sendable {
    let timestamp: TimeInterval
    let event: String
    let physicalFootprintBytes: UInt64?
}

private struct PipelineEvent: Encodable, Sendable {
    let timestamp: TimeInterval
    let event: String
    let segmentID: Int64
    let startSample: Int64
    let endSample: Int64
    let sampleCount: Int
    let durationMilliseconds: Int?
    let language: String?
    let reportedLanguage: String?
    let sourceText: String?
    let translatedText: String?
    let direction: String?
    let error: String?
    var averageLogProbability: Float? = nil
    var noSpeechProbability: Float? = nil
}
