import Foundation
import AVFoundation
import Testing
@testable import StreamTranslate

@Test func meetingSessionKeepsSourceAudioAndPipelineEvidenceSeparate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "StreamTranslate-session-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let logger = try MeetingSessionLogger(
        source: .microphone,
        rootDirectory: root
    )
    let samples = Array(repeating: Float(0.1), count: 1_600)
    logger.recordAudioChunk(
        CapturedAudioChunk(
            samples: samples,
            sequence: 0,
            capturedAt: Date(),
            sourceTimestamp: 10
        )
    )
    let segment = SpeechSegment(
        samples: samples,
        startSample: 0,
        endSample: 1_600
    )
    logger.recordSegment("final_segment", segment: segment)
    logger.recordPipelineStatus(
        "recognition_backend",
        detail: "apple-speech-transcriber-en"
    )
    logger.recordRecognition(
        "final_recognized",
        segment: segment,
        output: TranscriptionOutput(
            text: "Can you hear me?",
            language: .english,
            reportedLanguageCode: "en",
            words: []
        ),
        duration: 0.25
    )
    logger.recordTranslation(
        "final_translated",
        segment: segment,
        sourceText: "Can you hear me?",
        translatedText: "你能听见我吗？",
        direction: .englishToChinese,
        duration: 0.1
    )
    logger.finish()
    logger.flush()

    let audioSize = try logger.audioURL.resourceValues(
        forKeys: [.fileSizeKey]
    ).fileSize ?? 0
    let recordedAudio = try AVAudioFile(forReading: logger.audioURL)
    let capture = try String(contentsOf: logger.captureLogURL, encoding: .utf8)
    let pipeline = try String(contentsOf: logger.pipelineLogURL, encoding: .utf8)

    #expect(audioSize > 44)
    #expect(recordedAudio.length == 1_600)
    #expect(capture.contains("audio_chunk"))
    #expect(capture.contains("\"sequence\":0"))
    #expect(!capture.contains("Can you hear me?"))
    #expect(pipeline.contains("final_recognized"))
    #expect(pipeline.contains("runtime_sample"))
    #expect(pipeline.contains("apple-speech-transcriber-en"))
    #expect(pipeline.contains("Can you hear me?"))
    #expect(pipeline.contains("你能听见我吗？"))
}
