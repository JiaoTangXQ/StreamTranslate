import Foundation
import Observation

struct SummarySourceKey: Equatable, Sendable {
    let id: UUID
    let textHash: Int
}

enum SummaryTranscript {
    /// Bounded requests cover every sentence, including a single very long one.
    /// A fresh model request folds the preceding summary into each next chunk.
    static func chunks(_ entries: ArraySlice<CaptionEntry>, limit: Int = 1_200) -> [String] {
        let limit = max(1, limit)
        var result: [String] = [], current = "", count = 0
        for entry in entries {
            for character in entry.originalText + "\n" {
                if count == limit { result.append(current); current = ""; count = 0 }
                current.append(character)
                count += 1
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

@MainActor @Observable final class ConversationSummaryModel {
    var isExpanded = false
    private(set) var isAutoUpdating = true
    private(set) var text = ""
    private(set) var draftText = ""
    private(set) var isGenerating = false
    private(set) var isUpdateScheduled = false
    private(set) var progress = ""
    private(set) var errorMessage: String?
    private(set) var coveredCount = 0
    private(set) var completedAt: Date?
    private(set) var completedSourceRevision: Int?
    @ObservationIgnored private var sourceKeys: [SummarySourceKey] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var service: (any ConversationSummaryProviding)?
    @ObservationIgnored private var memoryMonitor: DispatchSourceMemoryPressure?
    @ObservationIgnored private let makeService: () -> any ConversationSummaryProviding
    @ObservationIgnored private let updateDelay: Duration
    @ObservationIgnored private let idleTimeout: Duration
    private struct Request {
        let revision: Int
        let load: @MainActor () async throws -> [CaptionEntry]
    }
    @ObservationIgnored private var pending: Request?

    init(updateDelay: Duration = .seconds(2), idleTimeout: Duration = .seconds(15),
         makeService: @escaping () -> any ConversationSummaryProviding = { LocalSummaryService() }) {
        self.updateDelay = updateDelay; self.idleTimeout = idleTimeout
        self.makeService = makeService
    }

    func reset() {
        cancel()
        text = ""; sourceKeys = []; coveredCount = 0; isAutoUpdating = true
        completedAt = nil; completedSourceRevision = nil; errorMessage = nil
    }

    func collapse() { isExpanded = false; cancel() }
    func pauseAutomaticUpdates() { isAutoUpdating = false; cancel() }
    func resumeAutomaticUpdates() { isAutoUpdating = true; errorMessage = nil }

    func cancel() {
        generation &+= 1
        task?.cancel(); task = nil
        scheduledTask?.cancel(); scheduledTask = nil
        idleTask?.cancel(); idleTask = nil
        pending = nil; isUpdateScheduled = false
        service?.cancel(); service = nil
        memoryMonitor?.cancel(); memoryMonitor = nil
        isGenerating = false; progress = ""; draftText = ""
    }

    /// Anchor the delay to the first change so continuous speech cannot keep
    /// postponing work. Busy updates overwrite one pending slot, never overlap.
    func scheduleAutomaticUpdate(sourceRevision: Int, immediately: Bool = false,
                                 load: @escaping @MainActor () async throws -> [CaptionEntry]) {
        guard isExpanded, isAutoUpdating, errorMessage == nil,
              sourceRevision != completedSourceRevision else { return }
        pending = Request(revision: sourceRevision, load: load)
        guard !isGenerating else { return }
        if immediately { scheduledTask?.cancel(); scheduledTask = nil }
        guard scheduledTask == nil else { return }
        isUpdateScheduled = true
        let scheduledGeneration = generation, delay = immediately ? .zero : updateDelay
        scheduledTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == scheduledGeneration,
                  self.isExpanded, self.isAutoUpdating, let request = self.pending else { return }
            self.scheduledTask = nil; self.pending = nil; self.isUpdateScheduled = false
            self.generate(sourceRevision: request.revision, load: request.load)
        }
    }

    func generate(sourceRevision: Int, load: @escaping @MainActor () async throws -> [CaptionEntry]) {
        guard !isGenerating else { return }
        pending = nil
        scheduledTask?.cancel(); scheduledTask = nil; isUpdateScheduled = false
        idleTask?.cancel(); idleTask = nil
        memoryMonitor?.cancel()
        generation &+= 1
        let requestedGeneration = generation
        isGenerating = true; errorMessage = nil; draftText = ""; progress = "正在读取本次完整记录…"
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestedGeneration else { return }
                self.pauseAutomaticUpdates()
                self.errorMessage = "系统内存紧张，已暂停总结以减少占用。可稍后重试。"
            }
        }
        memoryMonitor = monitor; monitor.resume()
        task = Task { [weak self] in
            guard let self else { return }
            var activeService = self.service
            defer {
                if self.generation == requestedGeneration {
                    self.task = nil; self.isGenerating = false; self.progress = ""; self.draftText = ""
                    if self.isExpanded, self.isAutoUpdating, self.errorMessage == nil, activeService != nil {
                        self.service = activeService
                        self.releaseAfterIdle(generation: requestedGeneration)
                    } else {
                        activeService?.cancel(); self.service = nil
                        self.memoryMonitor?.cancel(); self.memoryMonitor = nil
                    }
                    if let next = self.pending {
                        self.pending = nil
                        self.scheduleAutomaticUpdate(sourceRevision: next.revision, load: next.load)
                    }
                } else { activeService?.cancel() }
            }
            do {
                let entries = try await load()
                try Task.checkCancellation()
                guard self.generation == requestedGeneration else { return }
                let previousKeys = self.sourceKeys, previousText = self.text
                let (keys, chunks, canContinue, captionCount) = await Task.detached(priority: .utility) {
                    let entries = entries.filter { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    let keys = entries.map { SummarySourceKey(id: $0.id, textHash: $0.originalText.hashValue) }
                    let canContinue = !previousText.isEmpty && keys.starts(with: previousKeys)
                    return (keys, SummaryTranscript.chunks(entries.dropFirst(canContinue ? previousKeys.count : 0)),
                            canContinue, entries.count)
                }.value
                try Task.checkCancellation()
                guard self.generation == requestedGeneration, captionCount > 0 else { return }
                var result = canContinue ? previousText : ""
                if !chunks.isEmpty {
                    if activeService == nil {
                        let engine = self.makeService()
                        activeService = engine; self.service = engine
                        self.progress = "正在准备本地 AI…"
                        try await engine.prepare()
                    }
                    guard let engine = activeService else { throw SummaryError.modelUnavailable }
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        guard self.generation == requestedGeneration else { return }
                        self.progress = "正在梳理对话 \(index + 1)/\(chunks.count)…"
                        self.draftText = ""
                        result = try await engine.summarize(chunk, previous: result) { [weak self] partial in
                            guard let self, self.generation == requestedGeneration, !Task.isCancelled else { return }
                            self.draftText = partial
                        }
                    }
                }
                try Task.checkCancellation()
                guard self.generation == requestedGeneration else { return }
                self.text = result; self.sourceKeys = keys
                self.coveredCount = captionCount; self.completedAt = .now
                self.completedSourceRevision = sourceRevision
            } catch is CancellationError { return }
            catch {
                guard self.generation == requestedGeneration, !Task.isCancelled else { return }
                self.isAutoUpdating = false; self.pending = nil
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "总结暂时未能完成，点击重试。"
            }
        }
    }

    private func releaseAfterIdle(generation: Int) {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == generation, !self.isGenerating else { return }
            self.service?.cancel(); self.service = nil
            self.memoryMonitor?.cancel(); self.memoryMonitor = nil
            self.idleTask = nil
        }
    }
}
