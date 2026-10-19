import Foundation
import Testing
import Observation
import Synchronization
@testable import StreamTranslate

@Test @MainActor func readingControlsKeepALegibleMinimumWindowHeight() {
    let name = "StreamTranslate.quick-height.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(100.0, forKey: "panelHeight")
    #expect(CaptionSettings(defaults: defaults).panelHeight == 144)
}

@Test func captionControlsHideOnlyAfterIdleAndStayDuringInteraction() {
    let start = Date(timeIntervalSince1970: 100)
    let state = CaptionControlsVisibility()
    state.reveal(at: start)
    state.update(at: start.addingTimeInterval(2.9), keepVisible: false)
    #expect(state.isVisible)
    state.update(at: start.addingTimeInterval(3), keepVisible: false)
    #expect(!state.isVisible)
    state.reveal(at: start.addingTimeInterval(4))
    #expect(state.isVisible)
    state.update(at: start.addingTimeInterval(20), keepVisible: true)
    #expect(state.isVisible)
    state.update(at: start.addingTimeInterval(22), keepVisible: false)
    #expect(state.isVisible)
    state.update(at: start.addingTimeInterval(24), keepVisible: false)
    #expect(!state.isVisible)
}

@Test func captionHoverAndIdleTicksDoNotInvalidateVisibleContent() {
    let state = CaptionControlsVisibility()
    let changes = Mutex(0)
    let start = Date(timeIntervalSince1970: 100)
    withObservationTracking {
        _ = state.isVisible
    } onChange: {
        changes.withLock { $0 += 1 }
    }
    for index in 0..<1_000 {
        state.reveal(at: start.addingTimeInterval(Double(index) / 100))
        state.update(at: start.addingTimeInterval(Double(index) / 100), keepVisible: true)
    }
    #expect(changes.withLock { $0 } == 0)
    state.update(at: start.addingTimeInterval(20), keepVisible: false)
    #expect(changes.withLock { $0 } == 1)
    #expect(!state.isVisible)

    let hiddenChanges = Mutex(0)
    withObservationTracking {
        _ = state.isVisible
    } onChange: {
        hiddenChanges.withLock { $0 += 1 }
    }
    for index in 0..<100 {
        state.update(at: start.addingTimeInterval(21 + Double(index)), keepVisible: false)
    }
    #expect(hiddenChanges.withLock { $0 } == 0)
    state.reveal(at: start.addingTimeInterval(200))
    #expect(hiddenChanges.withLock { $0 } == 1)
    #expect(state.isVisible)
}

@Test @MainActor func quickSourceSelectionWhileIdleDoesNotStartCaptureOrLoseHistory() async {
    let name = "StreamTranslate.quick-idle.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = CaptionSettings(defaults: defaults)
    let vm = CaptionViewModel()
    vm.isModelReady = true // Use the default model identity; no model/audio service.
    vm.addCaption(english: "Kept", chinese: "保留")
    vm.changeCaptureConfiguration(settings: settings, source: .systemAudio)
    for _ in 0..<100 { if !vm.isChangingCaptureConfiguration { break }; await Task.yield() }
    #expect(settings.audioInputSource == .systemAudio)
    #expect(!vm.isRecording)
    #expect(!vm.isStartingCapture)
    #expect(!vm.isChangingCaptureConfiguration)
    #expect(vm.captionHistory.count == 1)
}

@Test @MainActor func quickChangeIgnoresDuplicateAndBusyRequests() {
    let name = "StreamTranslate.quick-busy.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = CaptionSettings(defaults: defaults)
    let vm = CaptionViewModel()
    vm.changeCaptureConfiguration(settings: settings, source: settings.audioInputSource)
    #expect(!vm.isChangingCaptureConfiguration)
    vm.isFinalizingCapture = true
    vm.changeCaptureConfiguration(settings: settings, source: .systemAudio)
    #expect(!vm.isChangingCaptureConfiguration)
    #expect(settings.audioInputSource == .microphone)
}

@Test @MainActor func stoppingDuringQuickSwitchCancelsAutomaticResume() async {
    let name = "StreamTranslate.quick-cancel.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = CaptionSettings(defaults: defaults)
    let vm = CaptionViewModel()
    vm.isModelReady = true
    vm.isRecording = true // Synthetic state; no actual audio/model resources.
    vm.changeCaptureConfiguration(settings: settings, source: .systemAudio)
    vm.toggleCapture()
    for _ in 0..<200 { if !vm.isChangingCaptureConfiguration { break }; try? await Task.sleep(for: .milliseconds(5)) }
    #expect(!vm.isChangingCaptureConfiguration)
    #expect(!vm.isRecording)
    #expect(!vm.isStartingCapture)
    #expect(settings.audioInputSource == .systemAudio)
    #expect(vm.quickControlMessage.isEmpty)
}
