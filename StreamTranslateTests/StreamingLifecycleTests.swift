import Foundation
import Testing
@testable import StreamTranslate

@Test @MainActor func gracefulStopDrainsTheFinalRecognizerUpdate() async {
    let vm = CaptionViewModel()
    vm.isRecording = true
    let (updates, continuation) = AsyncThrowingStream<StreamingTranscriptionUpdate, Error>.makeStream()
    vm.startNativeStreamingUpdates(updates, logger: nil, partialTranslations: PartialTranslationQueue())
    vm.stopCapture()
    #expect(vm.isFinalizingCapture)
    continuation.yield(.init(output: .init(text: "The final words are preserved.", language: .english,
        reportedLanguageCode: "en", words: []), startSample: 0, endSample: 16_000,
        isFinal: true, processingLatency: 0))
    continuation.finish()
    for _ in 0..<200 {
        if !vm.isFinalizingCapture { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(!vm.isFinalizingCapture)
    #expect(vm.captionHistory.last?.englishText == "The final words are preserved.")
}

@Test @MainActor func failedRecognizerDoesNotLeaveRecordingIndicatorRunning() async {
    let vm = CaptionViewModel()
    vm.isRecording = true
    let updates = AsyncThrowingStream<StreamingTranscriptionUpdate, Error> { continuation in
        continuation.finish(throwing: NSError(domain: "RecognizerFixture", code: 42))
    }
    await vm.consumeNativeStreamingUpdates(updates, logger: nil,
        partialTranslations: PartialTranslationQueue(), captureGeneration: 0)
    #expect(!vm.isRecording)
    #expect(vm.statusMessage.contains("RecognizerFixture"))
}

@Test @MainActor func unexpectedlyFinishedRecognizerStopsCapture() async {
    let vm = CaptionViewModel()
    vm.isRecording = true
    let updates = AsyncThrowingStream<StreamingTranscriptionUpdate, Error> { $0.finish() }
    await vm.consumeNativeStreamingUpdates(updates, logger: nil,
        partialTranslations: PartialTranslationQueue(), captureGeneration: 0)
    #expect(!vm.isRecording)
    #expect(vm.statusMessage.contains("意外结束"))
}

@Test @MainActor func oldRecognizerTerminationCannotStopNewCapture() async {
    let vm = CaptionViewModel()
    vm.stopCapture(gracefully: false) // Retires capture generation zero.
    vm.isRecording = true
    let updates = AsyncThrowingStream<StreamingTranscriptionUpdate, Error> { $0.finish() }
    await vm.consumeNativeStreamingUpdates(updates, logger: nil,
        partialTranslations: PartialTranslationQueue(), captureGeneration: 0)
    #expect(vm.isRecording)
    #expect(vm.statusMessage.isEmpty)
    vm.stopCapture(gracefully: false)
}
