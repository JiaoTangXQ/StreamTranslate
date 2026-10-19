import Foundation
import Observation

struct SummarySourceKey: Equatable, Sendable {
    let id: UUID
    let textHash: Int
}

struct SummaryBatch: Sendable {
    struct Record: Sendable {
        let sourceID: UUID
        let text: String
    }
    let records: [Record]
    var input: String {
        records.enumerated().map { "[\($0.offset + 1)] " + $0.element.text }.joined()
    }
}

enum SummaryTranscript {
    static func batches(_ entries: [CaptionEntry], limit: Int = 900) -> [SummaryBatch] {
        let limit = max(1, limit)
        var result: [SummaryBatch] = [], records: [SummaryBatch.Record] = [], count = 0
        for entry in entries {
            var fragment = ""
            for character in entry.originalText + "\n" {
                if count == limit {
                    if !fragment.isEmpty { records.append(.init(sourceID: entry.id, text: fragment)); fragment = "" }
                    result.append(SummaryBatch(records: records)); records = []; count = 0
                }
                fragment.append(character)
                count += 1
            }
            if !fragment.isEmpty { records.append(.init(sourceID: entry.id, text: fragment)) }
            if records.count >= 12 { result.append(SummaryBatch(records: records)); records = []; count = 0 }
        }
        if !records.isEmpty { result.append(SummaryBatch(records: records)) }
        return result
    }
}

@MainActor @Observable final class ConversationSummaryModel {
    var isExpanded = false
    private(set) var isAutoUpdating = true
    private(set) var map = ConversationMindMap()
    private(set) var draftMap: ConversationMindMap?
    var text: String { map.outline }
    // Publish a coherent completed update; streaming patches remain internal.
    var displayedMap: ConversationMindMap { map }
    private(set) var draftText = ""
    private(set) var isGenerating = false
    private(set) var isUpdateScheduled = false
    private(set) var backendDescription = "AI 脑图 · 自动选择"
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

    init(updateDelay: Duration = .seconds(30), idleTimeout: Duration = .seconds(45),
         makeService: @escaping () -> any ConversationSummaryProviding = { AutomaticSummaryService() }) {
        self.updateDelay = updateDelay; self.idleTimeout = idleTimeout
        self.makeService = makeService
    }

    func reset() {
        cancel()
        map = ConversationMindMap(); sourceKeys = []; coveredCount = 0; isAutoUpdating = true
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
        isGenerating = false; progress = ""; draftText = ""; draftMap = nil
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
        isGenerating = true; errorMessage = nil; draftText = ""; draftMap = nil; progress = "正在读取本次完整记录…"
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestedGeneration, self.service?.usesLocalModel == true else { return }
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
                    self.task = nil; self.isGenerating = false; self.progress = ""; self.draftText = ""; self.draftMap = nil
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
                let previousKeys = self.sourceKeys, previousMap = self.map
                let (keys, batches, affected, captionCount) = await Task.detached(priority: .utility) {
                    let entries = entries.filter { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    let keys = entries.map { SummarySourceKey(id: $0.id, textHash: $0.originalText.hashValue) }
                    let old = Dictionary(uniqueKeysWithValues: previousKeys.map { ($0.id, $0.textHash) })
                    let current = Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0.textHash) })
                    let changed = Set(previousKeys.filter { current[$0.id] != $0.textHash }.map(\.id))
                    let affected = previousMap.dependentSources(of: changed)
                    let changedEntries = entries.filter { old[$0.id] != $0.originalText.hashValue || affected.contains($0.id) }
                    return (keys, SummaryTranscript.batches(changedEntries), affected, entries.count)
                }.value
                try Task.checkCancellation()
                guard self.generation == requestedGeneration else { return }
                var result = previousMap
                result.invalidate(sources: affected)
                if !batches.isEmpty {
                    if activeService == nil {
                        let engine = self.makeService()
                        activeService = engine; self.service = engine
                        self.backendDescription = engine.backendDescription
                        self.progress = "正在准备脑图服务…"
                        let started = ContinuousClock.now
                        let ticker = Task { [weak self] in
                            while !Task.isCancelled {
                                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                                guard !Task.isCancelled, let self, self.generation == requestedGeneration else { return }
                                self.backendDescription = engine.backendDescription
                                self.progress = "正在准备脑图服务 · \(started.duration(to: .now).components.seconds) 秒"
                            }
                        }
                        do { try await engine.prepare() }
                        catch { ticker.cancel(); throw error }
                        ticker.cancel()
                    }
                    guard let engine = activeService else { throw SummaryError.modelUnavailable }
                    for (index, batch) in batches.enumerated() {
                        try Task.checkCancellation()
                        guard self.generation == requestedGeneration else { return }
                        self.progress = "正在补充话题 \(index + 1)/\(batches.count)…"
                        let baseline = result
                        let correctedSources = Set(batch.records.map(\.sourceID)).intersection(affected)
                        let linked = previousMap.topicIDs(for: correctedSources)
                        let additions = try await engine.summarize(batch.input, previous: baseline.context(for: batch.input, including: linked), validating: { output in
                            _ = try baseline.adding(output, batch: batch)
                        }) { [weak self] partial in
                            guard let self, self.generation == requestedGeneration, !Task.isCancelled else { return }
                            self.backendDescription = engine.backendDescription
                            if partial.isEmpty { self.draftMap = baseline; self.draftText = baseline.outline; return }
                            if let preview = try? baseline.adding(partial, batch: batch, isDraft: true) {
                                let outline = preview.outline
                                if outline != self.draftText {
                                    self.draftMap = preview; self.draftText = outline
                                }
                            }
                        }
                        try Task.checkCancellation()
                        guard self.generation == requestedGeneration else { return }
                        self.backendDescription = engine.backendDescription
                        result = try baseline.adding(additions, batch: batch)
                        self.draftMap = result; self.draftText = result.outline
                    }
                }
                try Task.checkCancellation()
                guard self.generation == requestedGeneration else { return }
                result.pruneEmptyTopics()
                self.map = result; self.sourceKeys = keys
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
