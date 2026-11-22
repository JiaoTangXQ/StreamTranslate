import Foundation
import CompanionKit

@MainActor
final class CompanionCaptionPublisher {
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private let streamingID = UUID()
    private var publishedMap: ConversationMindMap?
    private var mapRevision = 0

    func start(viewModel: CaptionViewModel, server: CompanionServer, webServer: WebCaptionServer,
               remote: RemoteCaptionRelay, phone: PhoneMicrophoneCoordinator? = nil) {
        guard task == nil else { return }
        task = Task { [weak self, weak viewModel, weak server, weak webServer, weak remote, weak phone] in
            while !Task.isCancelled {
                guard let self, let viewModel, let server, let webServer, let remote else { return }
                if server.isRunning || webServer.isRunning || remote.isRunning {
                    var snapshot = Self.snapshot(viewModel, streamingID: self.streamingID)
                    snapshot.mindMap = self.mindMap(viewModel.conversationSummary.map)
                    if let phone {
                        let (state, notice) = phone.snapshotState
                        snapshot.phoneMicrophone = state
                        snapshot.notice = notice
                    }
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

    /// The phone gets the same map as the Mac pane; the revision changes only
    /// when the map does, so deltas carry it only after an update.
    private func mindMap(_ map: ConversationMindMap) -> CompanionMindMap? {
        guard map.hasContent else { publishedMap = nil; return nil }
        if publishedMap != map { publishedMap = map; mapRevision &+= 1 }
        return Self.companionMap(map, revision: mapRevision)
    }

    static func companionMap(_ map: ConversationMindMap, revision: Int) -> CompanionMindMap {
        CompanionMindMap(revision: revision, topics: map.topics.filter { $0.pointCount > 0 }.map { topic in
            CompanionMindMap.Topic(title: topic.title, summary: topic.summary,
                advertisement: topic.kind == .advertisement,
                branches: topic.branches.map { .init(title: $0.title, points: $0.points.map(\.text)) })
        })
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
