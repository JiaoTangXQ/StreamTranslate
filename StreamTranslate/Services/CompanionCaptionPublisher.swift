import Foundation
import CompanionKit

@MainActor
final class CompanionCaptionPublisher {
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private let streamingID = UUID()

    func start(viewModel: CaptionViewModel, server: CompanionServer, webServer: WebCaptionServer, remote: RemoteCaptionRelay) {
        guard task == nil else { return }
        task = Task { [weak self, weak viewModel, weak server, weak webServer, weak remote] in
            while !Task.isCancelled {
                guard let self, let viewModel, let server, let webServer, let remote else { return }
                if server.isRunning || webServer.isRunning || remote.isRunning {
                    let snapshot = Self.snapshot(viewModel, streamingID: self.streamingID)
                    if server.isRunning { server.publish(snapshot) }
                    if webServer.isRunning { webServer.publish(snapshot) }
                    if remote.isRunning { remote.publish(snapshot) }
                }
                if (server.isRunning || webServer.isRunning || remote.isRunning) && viewModel.isRecording {
                    if self.activity == nil {
                        self.activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                            reason: "用户正在通过手机阅读实时字幕")
                    }
                } else if let activity = self.activity {
                    ProcessInfo.processInfo.endActivity(activity)
                    self.activity = nil
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    static func snapshot(_ viewModel: CaptionViewModel, streamingID: UUID) -> CompanionSnapshot {
        let status: CompanionEngineStatus
        if viewModel.isFinalizingCapture { status = .finishing }
        else if viewModel.isPreparingTranslation || viewModel.isStartingCapture || viewModel.isLoading || viewModel.isChangingCaptureConfiguration { status = .preparing }
        else if viewModel.isRecording { status = .listening }
        else if !viewModel.isTranslationReady || !viewModel.isModelReady { status = .unavailable }
        else { status = .stopped }
        let captions = viewModel.captionHistory.suffix(CompanionLimits.maximumHistory)
            .filter { $0.timestamp >= viewModel.companionSessionStartedAt }.map {
            CompanionCaption(id: $0.id, timestamp: $0.timestamp, original: $0.originalText,
                             translation: $0.translatedText, language: $0.sourceLanguage.rawValue)
        }
        let streaming: CompanionCaption? = viewModel.hasStreamingText ? .init(id: streamingID,
            timestamp: Date(timeIntervalSince1970: 0), original: viewModel.streamingOriginalText,
            translation: viewModel.streamingTranslatedText, language: viewModel.streamingSourceLanguage.rawValue) : nil
        return .init(sessionID: viewModel.companionSessionID, captions: captions, streaming: streaming, status: status)
    }
}
