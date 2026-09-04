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
    private var screenStream: SCStream?
    private var systemAudioHealth = SystemAudioCaptureHealth()
    private var systemAudioWatchdog: Task<Void, Never>?
    private var isStoppingSystemAudio = false
    private var isRestartingSystemAudio = false
    private var displaySleepActivity: NSObjectProtocol?
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
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

        audioEngine = engine
        audioConverter = converter

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat
        ) { [weak self] buffer, time in
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
            audioEngine = nil
            audioConverter = nil
            throw error
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
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        audioConverter = nil

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

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { rawBuffer in
            CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length,
                destination: rawBuffer.baseAddress!
            )
        }

        let floatCount = length / MemoryLayout<Float>.size
        let floats = data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self).prefix(floatCount))
        }

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
