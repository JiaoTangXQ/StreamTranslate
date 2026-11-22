import Foundation
import CompanionKit

/// Starts and stops Mac recognition for audio that a paired phone page
/// uploads through the encrypted relay. Only the phone's own microphone can
/// be started this way; the Mac's microphone and system audio stay local
/// choices. A phone stream that stops arriving (screen locked, network lost)
/// ends the capture after a short timeout.
@MainActor
final class PhoneMicrophoneCoordinator {
    static let silenceTimeout: Duration = .seconds(8)

    private(set) var state: CompanionPhoneMicrophone = .unavailable
    private(set) var notice: String?
    private let relay: RemoteCaptionRelay
    private let viewModel: CaptionViewModel
    private let settings: CaptionSettings
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var capture: PhoneAudioCaptureService?
    private var refusedStream: String?
    private var lastAudio = ContinuousClock.now
    private var awake: NSObjectProtocol?

    init(relay: RemoteCaptionRelay, viewModel: CaptionViewModel, settings: CaptionSettings) {
        self.relay = relay; self.viewModel = viewModel; self.settings = settings
    }

    /// Re-evaluated whenever the relay or the setting changes.
    func update() {
        let enabled = settings.phoneMicrophoneEnabled && relay.isRunning
        relay.acceptsPhoneAudio = enabled
        if enabled, task == nil {
            task = Task { [weak self] in
                guard let self else { return }
                for await batch in self.relay.phoneAudio {
                    self.receive(batch)
                }
            }
        }
        // The phone can only reach a Mac that is awake.
        if enabled, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                reason: "允许手机远程收音")
        } else if !enabled, let activity = awake {
            ProcessInfo.processInfo.endActivity(activity); awake = nil
        }
        if !enabled { endCapture(); refusedStream = nil }
        refreshState()
    }

    private func refreshState() {
        if !(settings.phoneMicrophoneEnabled && relay.isRunning) { state = .unavailable; return }
        if capture != nil, viewModel.activeCaptureSource == .phoneMicrophone || viewModel.isStartingCapture {
            state = .listening
        } else if refusedStream != nil {
            state = .refused
        } else {
            state = .ready
        }
    }

    /// The snapshot fields the phone page reads.
    var snapshotState: (CompanionPhoneMicrophone, String?) {
        refreshState()
        // A capture the user stopped on the Mac is not restarted by the
        // same phone stream; the phone shows why.
        if let capture, viewModel.activeCaptureSource != .phoneMicrophone,
           !viewModel.isStartingCapture, !viewModel.isFinalizingCapture {
            refusedStream = capture.stream; self.capture = nil
            viewModel.phoneAudioProvider = nil
            notice = "电脑上已停止收音，可在手机上重新开始"
            state = .refused
        }
        return (state, state == .refused ? notice : nil)
    }

    func receive(_ batch: PhoneAudioBatch) {
        guard settings.phoneMicrophoneEnabled, relay.isRunning else { return }
        if batch.stream == refusedStream { return }
        if let capture, capture.stream == batch.stream {
            lastAudio = .now
            capture.append(batch)
            if batch.isEnd { finishCapture() }
            return
        }
        guard !batch.isEnd else { return }
        // A new phone stream. Never interrupt a capture the user started on
        // the Mac with its own microphone or system audio.
        if viewModel.isRecording || viewModel.isStartingCapture || viewModel.isFinalizingCapture
            || viewModel.isChangingCaptureConfiguration {
            if viewModel.activeCaptureSource == .phoneMicrophone, capture != nil {
                // The same phone restarted: hand over to the new stream.
                finishCapture()
            }
            refusedStream = batch.stream
            notice = viewModel.activeCaptureSource == .phoneMicrophone || viewModel.isFinalizingCapture
                ? "电脑正在收尾上一段手机录音，请稍后再开始"
                : "电脑正在用自己的音源收音，未启动手机收音"
            refreshState()
            return
        }
        guard viewModel.isModelReady, viewModel.isTranslationReady else {
            refusedStream = batch.stream
            notice = "电脑的识别或翻译还在准备，请稍后再试"
            refreshState()
            return
        }
        refusedStream = nil; notice = nil
        let service = PhoneAudioCaptureService(stream: batch.stream)
        capture = service
        viewModel.phoneAudioProvider = service
        lastAudio = .now
        service.append(batch)
        AppLogger.log("Phone microphone stream started")
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.startCapture(source: .phoneMicrophone,
                sensitivity: self.settings.speechDetectionSensitivity,
                recognitionMode: self.settings.recognitionLanguageMode,
                recognitionVocabulary: self.settings.recognitionVocabulary,
                captureDiagnosticsEnabled: self.settings.captureDiagnosticsEnabled)
            if self.viewModel.activeCaptureSource != .phoneMicrophone, self.capture === service {
                self.refusedStream = service.stream
                self.notice = "电脑未能开始识别：\(self.viewModel.statusMessage)"
                self.capture = nil; self.viewModel.phoneAudioProvider = nil
                service.finish()
            }
            self.refreshState()
        }
        startWatchdog()
        refreshState()
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.capture != nil else { return }
                if ContinuousClock.now - self.lastAudio > Self.silenceTimeout {
                    AppLogger.log("Phone microphone stream timed out")
                    self.finishCapture()
                    return
                }
            }
        }
    }

    /// Normal end of a phone stream: the last words are still finalized.
    private func finishCapture() {
        watchdog?.cancel(); watchdog = nil
        guard let service = capture else { return }
        capture = nil
        service.finish()
        if viewModel.activeCaptureSource == .phoneMicrophone { viewModel.stopCapture() }
        viewModel.phoneAudioProvider = nil
        AppLogger.log("Phone microphone stream ended")
        refreshState()
    }

    private func endCapture() {
        if capture != nil { finishCapture() }
    }

    func stop() {
        // The relay's audio stream has a single consumer for the app's
        // lifetime; it is disabled, not cancelled.
        relay.acceptsPhoneAudio = false
        endCapture()
        if let activity = awake { ProcessInfo.processInfo.endActivity(activity); awake = nil }
        state = .unavailable
    }
}
