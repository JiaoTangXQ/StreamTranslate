@preconcurrency import AVFoundation
import ScreenCaptureKit

enum SystemAudioCaptureRecoveryReason: String, Equatable, Sendable {
    case callbackStall = "ScreenCaptureKit callback stall"
    case streamStopped = "ScreenCaptureKit stream stopped"
}

enum SystemAudioCaptureActivity: Sendable {
    case audio
    case screen
}

enum MicrophoneCaptureRecoveryReason: String, Equatable, Sendable {
    case callbackStall = "microphone callback stall"
}

struct MicrophoneCaptureHealth: Sendable {
    private static let callbackStallDelay: TimeInterval = 3

    private var lastCallbackAt: TimeInterval?
    private var recoveryRequested = false

    mutating func reset(at time: TimeInterval) {
        lastCallbackAt = time
        recoveryRequested = false
    }

    mutating func observeCallback(at time: TimeInterval) {
        lastCallbackAt = time
    }

    mutating func checkForCallbackStall(
        at time: TimeInterval
    ) -> MicrophoneCaptureRecoveryReason? {
        guard !recoveryRequested,
              let lastCallbackAt,
              time - lastCallbackAt >= Self.callbackStallDelay else { return nil }
        recoveryRequested = true
        return .callbackStall
    }

    mutating func allowRecoveryRetry(at time: TimeInterval) {
        lastCallbackAt = time
        recoveryRequested = false
    }
}

/// Treats the ScreenCaptureKit stream as alive while either its screen or
/// audio output is producing callbacks. Audio silence alone is not evidence
/// that capture has failed.
struct SystemAudioCaptureHealth: Sendable {
    private static let callbackStallDelay: TimeInterval = 3

    private var lastAudioActivityAt: TimeInterval?
    private var lastScreenActivityAt: TimeInterval?
    private var recoveryRequested = false

    mutating func resetForNewStream(at time: TimeInterval) {
        lastAudioActivityAt = time
        lastScreenActivityAt = time
        recoveryRequested = false
    }

    mutating func observe(
        _ activity: SystemAudioCaptureActivity,
        at time: TimeInterval
    ) {
        switch activity {
        case .audio:
            lastAudioActivityAt = time
        case .screen:
            lastScreenActivityAt = time
        }
    }

    mutating func checkForCallbackStall(
        at time: TimeInterval
    ) -> SystemAudioCaptureRecoveryReason? {
        guard !recoveryRequested,
              let lastAudioActivityAt,
              let lastScreenActivityAt,
              time - lastAudioActivityAt >= Self.callbackStallDelay,
              time - lastScreenActivityAt >= Self.callbackStallDelay else { return nil }
        recoveryRequested = true
        return .callbackStall
    }

    mutating func allowRecoveryRetry(at time: TimeInterval) {
        recoveryRequested = false
        lastAudioActivityAt = time
        lastScreenActivityAt = time
    }
}

final class AudioCaptureService: NSObject, @unchecked Sendable {
    private static let targetSampleRate = 16_000.0

    private let source: AudioInputSource
    private let sessionLogger: MeetingSessionLogger?
    private let sequenceLock = NSLock()
    private let systemAudioLock = NSLock()
    private let microphoneLock = NSLock()
    private var screenStream: SCStream?
    private var systemAudioHealth = SystemAudioCaptureHealth()
    private var systemAudioWatchdog: Task<Void, Never>?
    private var isStoppingSystemAudio = false
    private var isRestartingSystemAudio = false
    private var displaySleepActivity: NSObjectProtocol?
    private var audioEngine: AVAudioEngine?
    private var microphoneHealth = MicrophoneCaptureHealth()
    private var microphoneWatchdog: Task<Void, Never>?
    private var isStoppingMicrophone = false
    private var isRestartingMicrophone = false
    private var continuation: AsyncStream<CapturedAudioChunk>.Continuation?
    private var _audioStream: AsyncStream<CapturedAudioChunk>?
    private var nextSequence: Int64 = 0

    init(
        source: AudioInputSource = .microphone,
        sessionLogger: MeetingSessionLogger? = nil
    ) {
        self.source = source
        self.sessionLogger = sessionLogger
    }

    /// Must be accessed BEFORE calling start() to set up the continuation
    func makeAudioStream() -> AsyncStream<CapturedAudioChunk> {
        let stream = AsyncStream<CapturedAudioChunk> { continuation in
            self.continuation = continuation
        }
        _audioStream = stream
        return stream
    }

    func start() async throws {
        switch source {
        case .microphone:
            try await startMicrophoneCapture()
        case .systemAudio:
            try await startSystemAudioCapture()
        }
    }

    private func startSystemAudioCapture() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "StreamTranslate is capturing system audio"
        )
        systemAudioLock.withLock {
            displaySleepActivity = activity
            isStoppingSystemAudio = false
            isRestartingSystemAudio = false
        }

        do {
            let stream = try await makeSystemAudioStream()
            systemAudioLock.withLock {
                screenStream = stream
                systemAudioHealth.resetForNewStream(at: Self.uptime)
            }
            startSystemAudioWatchdog()
        } catch {
            systemAudioLock.withLock {
                displaySleepActivity = nil
            }
            ProcessInfo.processInfo.endActivity(activity)
            throw error
        }
    }

    private func makeSystemAudioStream() async throws -> SCStream {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 16000
        config.width = 2
        config.height = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
        try await stream.startCapture()
        return stream
    }

    private func startSystemAudioWatchdog() {
        systemAudioWatchdog?.cancel()
        systemAudioWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.checkSystemAudioStreamActivity()
            }
        }
    }

    private func checkSystemAudioStreamActivity() {
        systemAudioLock.lock()
        let reason: SystemAudioCaptureRecoveryReason?
        if isStoppingSystemAudio || screenStream == nil {
            reason = nil
        } else {
            reason = systemAudioHealth.checkForCallbackStall(at: Self.uptime)
        }
        systemAudioLock.unlock()

        if let reason {
            requestSystemAudioRecovery(reason)
        }
    }

    private func requestSystemAudioRecovery(
        _ reason: SystemAudioCaptureRecoveryReason
    ) {
        systemAudioLock.lock()
        guard !isStoppingSystemAudio,
              screenStream != nil,
              !isRestartingSystemAudio else {
            systemAudioLock.unlock()
            return
        }
        isRestartingSystemAudio = true
        systemAudioLock.unlock()

        AppLogger.log("System audio capture recovery requested: \(reason.rawValue)")
        sessionLogger?.recordCaptureStatus(
            "capture_recovery_requested",
            detail: reason.rawValue
        )
        Task { [weak self] in
            await self?.recoverSystemAudio(reason: reason)
        }
    }

    private func recoverSystemAudio(
        reason: SystemAudioCaptureRecoveryReason
    ) async {
        do {
            let replacement = try await makeSystemAudioStream()

            let swap = systemAudioLock.withLock { () -> (Bool, SCStream?) in
                if isStoppingSystemAudio {
                    isRestartingSystemAudio = false
                    return (false, nil)
                }
                let previous = screenStream
                screenStream = replacement
                systemAudioHealth.resetForNewStream(at: Self.uptime)
                isRestartingSystemAudio = false
                return (true, previous)
            }
            guard swap.0 else {
                try? await replacement.stopCapture()
                return
            }

            try? await swap.1?.stopCapture()
            AppLogger.log("System audio capture recovered: \(reason.rawValue)")
            sessionLogger?.recordCaptureStatus(
                "capture_recovered",
                detail: reason.rawValue
            )
        } catch {
            let isStopping = systemAudioLock.withLock {
                isRestartingSystemAudio = false
                systemAudioHealth.allowRecoveryRetry(at: Self.uptime)
                return isStoppingSystemAudio
            }

            guard !isStopping else { return }
            let detail = "\(reason.rawValue): \(error.localizedDescription)"
            AppLogger.log("System audio capture recovery failed: \(detail)")
            sessionLogger?.recordCaptureStatus(
                "capture_recovery_failed",
                detail: detail
            )
        }
    }

    private func startMicrophoneCapture() async throws {
        guard await requestMicrophoneAccess() else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        microphoneLock.withLock {
            isStoppingMicrophone = false
            isRestartingMicrophone = false
        }
        try installMicrophoneCapture()
        startMicrophoneWatchdog()
    }

    private func installMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.audioConversionUnavailable
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat
        ) { [weak self] buffer, time in
            self?.recordMicrophoneCallback()
            let sourceTimestamp = time.isSampleTimeValid
                ? Double(time.sampleTime) / inputFormat.sampleRate
                : nil
            self?.convertAndYield(
                buffer,
                using: converter,
                outputFormat: outputFormat,
                sourceTimestamp: sourceTimestamp
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }

        let accepted = microphoneLock.withLock { () -> Bool in
            guard !isStoppingMicrophone else { return false }
            audioEngine = engine
            microphoneHealth.reset(at: Self.uptime)
            return true
        }
        if !accepted {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            throw CancellationError()
        }
    }

    private func startMicrophoneWatchdog() {
        microphoneWatchdog?.cancel()
        microphoneWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.checkMicrophoneActivity()
            }
        }
    }

    private func recordMicrophoneCallback() {
        microphoneLock.withLock {
            guard !isStoppingMicrophone, audioEngine != nil else { return }
            microphoneHealth.observeCallback(at: Self.uptime)
        }
    }

    private func checkMicrophoneActivity() {
        let reason = microphoneLock.withLock { () -> MicrophoneCaptureRecoveryReason? in
            guard !isStoppingMicrophone,
                  !isRestartingMicrophone,
                  audioEngine != nil else { return nil }
            return microphoneHealth.checkForCallbackStall(at: Self.uptime)
        }
        if let reason {
            requestMicrophoneRecovery(reason)
        }
    }

    private func requestMicrophoneRecovery(
        _ reason: MicrophoneCaptureRecoveryReason
    ) {
        let shouldStart = microphoneLock.withLock { () -> Bool in
            guard !isStoppingMicrophone,
                  audioEngine != nil,
                  !isRestartingMicrophone else { return false }
            isRestartingMicrophone = true
            return true
        }
        guard shouldStart else { return }

        AppLogger.log("Microphone capture recovery requested: \(reason.rawValue)")
        sessionLogger?.recordCaptureStatus(
            "capture_recovery_requested",
            detail: reason.rawValue
        )
        Task { [weak self] in
            self?.recoverMicrophone(reason: reason)
        }
    }

    private func recoverMicrophone(
        reason: MicrophoneCaptureRecoveryReason
    ) {
        let previous = microphoneLock.withLock { () -> AVAudioEngine? in
            let engine = audioEngine
            audioEngine = nil
            return engine
        }
        previous?.inputNode.removeTap(onBus: 0)
        previous?.stop()

        do {
            try installMicrophoneCapture()
            microphoneLock.withLock {
                isRestartingMicrophone = false
            }
            AppLogger.log("Microphone capture recovered: \(reason.rawValue)")
            sessionLogger?.recordCaptureStatus(
                "capture_recovered",
                detail: reason.rawValue
            )
        } catch {
            let shouldReport = microphoneLock.withLock { () -> Bool in
                isRestartingMicrophone = false
                microphoneHealth.allowRecoveryRetry(at: Self.uptime)
                return !isStoppingMicrophone
            }
            guard shouldReport else { return }
            let detail = "\(reason.rawValue): \(error.localizedDescription)"
            AppLogger.log("Microphone capture recovery failed: \(detail)")
            sessionLogger?.recordCaptureStatus(
                "capture_recovery_failed",
                detail: detail
            )
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func convertAndYield(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        sourceTimestamp: Double?
    ) {
        let ratio = Self.targetSampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * ratio)
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else { return }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) {
            _, inputStatus in
            guard inputState.takeInput() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error,
              conversionError == nil,
              outputBuffer.frameLength > 0,
              let channel = outputBuffer.floatChannelData?[0] else { return }

        emit(
            Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))),
            sourceTimestamp: sourceTimestamp
        )
    }

    private func emit(_ samples: [Float], sourceTimestamp: Double?) {
        guard !samples.isEmpty else { return }
        sequenceLock.lock()
        let sequence = nextSequence
        nextSequence += 1
        sequenceLock.unlock()

        let chunk = CapturedAudioChunk(
            samples: samples,
            sequence: sequence,
            capturedAt: Date(),
            sourceTimestamp: sourceTimestamp
        )
        sessionLogger?.recordAudioChunk(chunk)
        continuation?.yield(chunk)
    }

    func stop() async {
        microphoneWatchdog?.cancel()
        microphoneWatchdog = nil
        let microphoneEngine = microphoneLock.withLock { () -> AVAudioEngine? in
            isStoppingMicrophone = true
            isRestartingMicrophone = false
            let engine = audioEngine
            audioEngine = nil
            return engine
        }
        microphoneEngine?.inputNode.removeTap(onBus: 0)
        microphoneEngine?.stop()

        systemAudioWatchdog?.cancel()
        systemAudioWatchdog = nil

        let resources = systemAudioLock.withLock { () -> (SCStream?, NSObjectProtocol?) in
            isStoppingSystemAudio = true
            isRestartingSystemAudio = false
            let stream = screenStream
            screenStream = nil
            let activity = displaySleepActivity
            displaySleepActivity = nil
            return (stream, activity)
        }

        try? await resources.0?.stopCapture()
        if let activity = resources.1 {
            ProcessInfo.processInfo.endActivity(activity)
        }
        continuation?.finish()
        continuation = nil
    }

    private static var uptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func floatSamples(
        from sampleBuffer: CMSampleBuffer
    ) -> [Float]? {
        var result: [Float]?
        try? sampleBuffer.withAudioBufferList { audioBufferList, blockBuffer in
            guard let formatDescription = sampleBuffer.formatDescription else { return }
            let format = AVAudioFormat(
                cmAudioFormatDescription: formatDescription
            )
            guard format.commonFormat == .pcmFormatFloat32,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: format,
                      bufferListNoCopy: audioBufferList.unsafePointer
                  ),
                  buffer.frameLength > 0 else { return }

            result = withExtendedLifetime(blockBuffer) {
                let frameCount = Int(buffer.frameLength)
                let channelCount = Int(format.channelCount)
                if format.isInterleaved {
                    let audioBuffer = audioBufferList[0]
                    guard let data = audioBuffer.mData else { return nil }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    var mono = [Float](repeating: 0, count: frameCount)
                    for frame in 0..<frameCount {
                        let start = frame * channelCount
                        var sum: Float = 0
                        for channel in 0..<channelCount {
                            sum += samples[start + channel]
                        }
                        mono[frame] = sum / Float(channelCount)
                    }
                    return mono
                }

                guard let channels = buffer.floatChannelData else { return nil }
                if channelCount == 1 {
                    return Array(
                        UnsafeBufferPointer(
                            start: channels[0],
                            count: frameCount
                        )
                    )
                }

                var mono = [Float](repeating: 0, count: frameCount)
                for channelIndex in 0..<channelCount {
                    let source = channels[channelIndex]
                    for frame in 0..<frameCount {
                        mono[frame] += source[frame]
                    }
                }
                let scale = 1 / Float(channelCount)
                for frame in mono.indices {
                    mono[frame] *= scale
                }
                return mono
            }
        }
        return result
    }
}

private final class ConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var isSupplied = false

    func takeInput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSupplied else { return false }
        isSupplied = true
        return true
    }
}

extension AudioCaptureService: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        systemAudioLock.lock()
        let isCurrentStream = screenStream === stream && !isStoppingSystemAudio
        if isCurrentStream {
            let activity: SystemAudioCaptureActivity = type == .audio ? .audio : .screen
            systemAudioHealth.observe(activity, at: Self.uptime)
        }
        systemAudioLock.unlock()
        guard isCurrentStream else { return }
        guard type == .audio else { return }

        guard let floats = Self.floatSamples(from: sampleBuffer),
              !floats.isEmpty else { return }

        let presentationTime = sampleBuffer.presentationTimeStamp
        let sourceTimestamp = presentationTime.isValid
            ? CMTimeGetSeconds(presentationTime)
            : nil

        emit(floats, sourceTimestamp: sourceTimestamp)
    }
}

extension AudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        systemAudioLock.lock()
        let shouldRecover = screenStream === stream && !isStoppingSystemAudio
        systemAudioLock.unlock()

        guard shouldRecover else { return }
        let nsError = error as NSError
        AppLogger.log(
            "System audio stream stopped: \(nsError.domain) \(nsError.code)"
        )
        requestSystemAudioRecovery(.streamStopped)
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case noDisplayFound
    case microphonePermissionDenied
    case microphoneUnavailable
    case audioConversionUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for audio capture"
        case .microphonePermissionDenied:
            return "Microphone access is denied. Enable StreamTranslate in System Settings > Privacy & Security > Microphone."
        case .microphoneUnavailable:
            return "No usable microphone input is available"
        case .audioConversionUnavailable:
            return "The microphone audio format cannot be converted to 16 kHz mono"
        }
    }
}
