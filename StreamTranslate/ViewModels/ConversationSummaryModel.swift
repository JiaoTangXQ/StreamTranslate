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
    private(set) var text = ""
    private(set) var isGenerating = false
    private(set) var progress = ""
    private(set) var errorMessage: String?
    private(set) var coveredCount = 0
    private(set) var completedAt: Date?
    private(set) var completedSourceRevision: Int?
    @ObservationIgnored private var sourceKeys: [SummarySourceKey] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var service: (any ConversationSummaryProviding)?
    @ObservationIgnored private var memoryMonitor: DispatchSourceMemoryPressure?
    @ObservationIgnored private let makeService: () -> any ConversationSummaryProviding

    init(makeService: @escaping () -> any ConversationSummaryProviding = { LocalSummaryService() }) {
        self.makeService = makeService
    }

    func reset() {
        cancel()
        text = ""; sourceKeys = []; coveredCount = 0
        completedAt = nil; completedSourceRevision = nil; errorMessage = nil
    }

    func collapse() { isExpanded = false; cancel() }

    func cancel() {
        generation &+= 1
        task?.cancel(); task = nil
        service?.cancel(); service = nil
        memoryMonitor?.cancel(); memoryMonitor = nil
        isGenerating = false; progress = ""
    }

    func generate(sourceRevision: Int, load: @escaping @MainActor () async throws -> [CaptionEntry]) {
        guard !isGenerating else { return }
        generation &+= 1
        let requestedGeneration = generation
        isGenerating = true; errorMessage = nil; progress = "正在读取本次完整记录…"
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestedGeneration else { return }
                self.cancel()
                self.errorMessage = "系统内存紧张，已暂停总结以减少占用。可稍后重试。"
            }
        }
        memoryMonitor = monitor; monitor.resume()
        task = Task { [weak self] in
            guard let self else { return }
            var activeService: (any ConversationSummaryProviding)?
            defer {
                activeService?.cancel()
                if self.generation == requestedGeneration {
                    self.service = nil; self.task = nil
                    self.memoryMonitor?.cancel(); self.memoryMonitor = nil
                    self.isGenerating = false; self.progress = ""
                }
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
                    let engine = self.makeService()
                    activeService = engine; self.service = engine
                    self.progress = "正在准备本地 AI…"
                    try await engine.prepare()
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        guard self.generation == requestedGeneration else { return }
                        self.progress = "正在梳理对话 \(index + 1)/\(chunks.count)…"
                        result = try await engine.summarize(chunk, previous: result)
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
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "总结暂时未能完成，点击重试。"
            }
        }
    }
}
