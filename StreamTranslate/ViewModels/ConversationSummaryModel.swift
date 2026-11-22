import Foundation
import Observation

/// When to refresh the mind map automatically. A fixed interval fits neither a
/// 10-minute talk nor a 5-hour session, so the interval grows with the session
/// and the first map appears as soon as there is something to map.
enum MindMapCadence {
    /// Never start two automatic updates closer together than this.
    static let minimumGap: TimeInterval = 12
    static let firstMapCharacters = 80
    static let minimumNewCharacters = 40
    static let burstCharacters = 2_500

    /// About 20 s early in a session, 50 s at 10 minutes, 4 minutes after
    /// the first 48 minutes, when one update changes the overview little.
    static func interval(sessionElapsed: TimeInterval) -> TimeInterval {
        min(240, max(20, sessionElapsed / 12))
    }

    /// Seconds to wait before the next automatic update, or nil while there
    /// is not yet enough new text. Anchored to the last update, so continuous
    /// speech cannot keep postponing it.
    static func delay(newCharacters: Int, hasMap: Bool, paneOpen: Bool, justOpened: Bool,
                      sinceLastUpdate: TimeInterval?, sessionElapsed: TimeInterval) -> TimeInterval? {
        guard newCharacters > 0 else { return nil }
        let earliest = max(0, minimumGap - (sinceLastUpdate ?? .infinity))
        if justOpened { return earliest }
        if !hasMap { return newCharacters >= firstMapCharacters || paneOpen ? earliest : nil }
        if newCharacters >= burstCharacters { return earliest }
        guard newCharacters >= minimumNewCharacters else { return nil }
        let since = sinceLastUpdate ?? .infinity
        return max(earliest, interval(sessionElapsed: sessionElapsed) - since)
    }
}

/// Splits not-yet-mapped captions into request-sized pieces. Fragments never
/// exceed the smallest provider budget, so a batch built for the cloud can be
/// regrouped for the local model without splitting again.
enum MindMapBatcher {
    struct Fragment: Equatable, Sendable {
        let sourceID: UUID
        let text: String
        /// True for the fragment that completes its caption.
        let completesSource: Bool
    }

    static func fragments(_ entries: [CaptionEntry], limit: Int = LocalSummaryService.inputBudget) -> [Fragment] {
        var result: [Fragment] = []
        for entry in entries {
            let text = entry.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var start = text.startIndex
            while start < text.endIndex {
                let end = text.index(start, offsetBy: max(1, limit - 1), limitedBy: text.endIndex) ?? text.endIndex
                result.append(Fragment(sourceID: entry.id, text: String(text[start..<end]), completesSource: end == text.endIndex))
                start = end
            }
        }
        return result
    }

    /// The longest prefix of `fragments` whose newline-joined text fits.
    static func batch(_ fragments: ArraySlice<Fragment>, budget: Int) -> ArraySlice<Fragment> {
        var size = 0
        var end = fragments.startIndex
        while end < fragments.endIndex {
            let next = fragments[end].text.count + 1
            if size + next > budget, end > fragments.startIndex { break }
            size += next
            end += 1
        }
        return fragments[fragments.startIndex..<end]
    }
}

@MainActor @Observable final class ConversationSummaryModel {
    /// The mind-map pane is visible.
    var isExpanded = false
    private(set) var isAutoUpdating = true
    private(set) var map = ConversationMindMap()
    var text: String { map.outline }
    /// Each successfully merged batch is published at once; streamed text
    /// stays internal because a half-written JSON revision is meaningless.
    var displayedMap: ConversationMindMap { map }
    private(set) var isGenerating = false
    private(set) var isUpdateScheduled = false
    private(set) var backendDescription = "AI 脑图 · 自动选择"
    private(set) var progress = ""
    private(set) var errorMessage: String?
    private(set) var coveredCount = 0
    private(set) var completedAt: Date?
    /// Topics the latest update added or rewrote; the view opens these.
    private(set) var recentlyChangedTopicIDs: [String] = []
    /// Keep the map current while recording even when the pane is closed, so
    /// opening it shows a map immediately. Only used with a cloud provider:
    /// a background local model would hold ~4 GB during capture.
    var backgroundUpdatesRequested = false {
        didSet {
            guard backgroundUpdatesRequested != oldValue else { return }
            if isActive { evaluate() } else if !isGenerating { cancelScheduled() }
        }
    }
    var backgroundUpdates: Bool { backgroundUpdatesRequested && cloudAvailable }
    var isActive: Bool { isExpanded || backgroundUpdates }

    @ObservationIgnored private var source: (@MainActor () async throws -> [CaptionEntry])?
    @ObservationIgnored private var sessionStartedAt = Date()
    @ObservationIgnored private var sourceCharacters = 0
    @ObservationIgnored private var requestedCharacters = 0
    @ObservationIgnored private var mappedSourceIDs: Set<UUID> = []
    @ObservationIgnored private var previousTail = ""
    @ObservationIgnored private var lastUpdateAt: Date?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var service: (any ConversationSummaryProviding)?
    @ObservationIgnored private var memoryMonitor: DispatchSourceMemoryPressure?
    @ObservationIgnored private let makeService: () -> any ConversationSummaryProviding
    @ObservationIgnored private let idleTimeout: Duration
    @ObservationIgnored private let cadenceScale: Double
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let detectCloud: () -> Bool
    @ObservationIgnored private var cachedCloudAvailability: Bool?

    /// `cadenceScale` shortens every automatic delay in tests. The provider
    /// has no default so a trailing closure always means the provider.
    init(idleTimeout: Duration = .seconds(45), cadenceScale: Double = 1,
         now: @escaping () -> Date = Date.init,
         cloudAvailable: @escaping () -> Bool = { SummaryCloudConfiguration.load() != nil },
         makeService: @escaping () -> any ConversationSummaryProviding) {
        self.idleTimeout = idleTimeout; self.cadenceScale = cadenceScale
        self.now = now; self.detectCloud = cloudAvailable
        self.makeService = makeService
    }

    private var cloudAvailable: Bool {
        if let cachedCloudAvailability { return cachedCloudAvailability }
        let available = detectCloud()
        cachedCloudAvailability = available
        return available
    }

    /// Characters of caption text not yet sent for mapping, for the status line.
    var pendingCharacters: Int { max(0, sourceCharacters - requestedCharacters) }

    /// A new capture session: forget the old map and read this session's
    /// complete saved transcript from now on.
    func begin(sessionStartedAt: Date, load: @escaping @MainActor () async throws -> [CaptionEntry]) {
        reset()
        self.sessionStartedAt = sessionStartedAt
        source = load
        cachedCloudAvailability = nil
    }

    func reset() {
        cancel()
        map = ConversationMindMap(); mappedSourceIDs = []; previousTail = ""
        sourceCharacters = 0; requestedCharacters = 0; lastUpdateAt = nil
        coveredCount = 0; completedAt = nil; errorMessage = nil; isAutoUpdating = true
        recentlyChangedTopicIDs = []
    }

    /// Called whenever this session's original caption text grows or changes.
    func sourceDidChange(characters: Int) {
        sourceCharacters = characters
        evaluate()
    }

    func expand() {
        isExpanded = true
        evaluate(justOpened: true)
    }

    /// Closing the pane keeps background work; without it, the local model
    /// is released instead of waiting for the next update.
    func collapse() {
        isExpanded = false
        if !backgroundUpdates { cancel() }
    }

    func pauseAutomaticUpdates() { isAutoUpdating = false; cancel() }

    func resumeAutomaticUpdates() {
        isAutoUpdating = true; errorMessage = nil
        evaluate(justOpened: true)
    }

    /// Manual "整理一次": merge everything new right away.
    func requestNow() {
        errorMessage = nil
        generate()
    }

    func cancel() {
        generation &+= 1
        task?.cancel(); task = nil
        cancelScheduled()
        idleTask?.cancel(); idleTask = nil
        service?.cancel(); service = nil
        memoryMonitor?.cancel(); memoryMonitor = nil
        isGenerating = false; progress = ""
    }

    private func cancelScheduled() {
        scheduledTask?.cancel(); scheduledTask = nil
        isUpdateScheduled = false
    }

    private func evaluate(justOpened: Bool = false) {
        guard isActive, isAutoUpdating, errorMessage == nil, !isGenerating, source != nil else { return }
        let current = now()
        guard let delay = MindMapCadence.delay(
            newCharacters: sourceCharacters - requestedCharacters, hasMap: map.hasContent,
            paneOpen: isExpanded, justOpened: justOpened,
            sinceLastUpdate: lastUpdateAt.map { current.timeIntervalSince($0) },
            sessionElapsed: current.timeIntervalSince(sessionStartedAt)) else {
            cancelScheduled(); return
        }
        scheduledTask?.cancel()
        isUpdateScheduled = true
        let scheduledGeneration = generation
        let wait = Duration.seconds(delay * cadenceScale)
        scheduledTask = Task { [weak self] in
            if wait > .zero { do { try await Task.sleep(for: wait) } catch { return } }
            guard let self, self.generation == scheduledGeneration, self.isActive, self.isAutoUpdating else { return }
            self.scheduledTask = nil; self.isUpdateScheduled = false
            self.generate()
        }
    }

    func generate() {
        guard !isGenerating, let source else { return }
        cancelScheduled()
        idleTask?.cancel(); idleTask = nil
        memoryMonitor?.cancel()
        generation &+= 1
        let requestedGeneration = generation
        isGenerating = true; errorMessage = nil; progress = "正在读取本次记录…"
        let startCharacters = sourceCharacters
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestedGeneration, self.service?.usesLocalModel == true else { return }
                self.pauseAutomaticUpdates()
                self.errorMessage = "系统内存紧张，已暂停本机脑图整理以减少占用。可稍后重试。"
            }
        }
        memoryMonitor = monitor; monitor.resume()
        task = Task { [weak self] in
            guard let self else { return }
            var activeService = self.service
            var completed = false
            defer {
                if self.generation == requestedGeneration {
                    self.task = nil; self.isGenerating = false; self.progress = ""
                    self.lastUpdateAt = self.now()
                    // Failed or cancelled text stays pending for the retry.
                    if completed { self.requestedCharacters = startCharacters }
                    if self.isActive, self.isAutoUpdating, self.errorMessage == nil, activeService != nil {
                        self.service = activeService
                        self.releaseAfterIdle(generation: requestedGeneration)
                    } else {
                        activeService?.cancel(); self.service = nil
                        self.memoryMonitor?.cancel(); self.memoryMonitor = nil
                    }
                    self.evaluate()
                } else { activeService?.cancel() }
            }
            do {
                let entries = try await source()
                try Task.checkCancellation()
                guard self.generation == requestedGeneration else { return }
                let mapped = self.mappedSourceIDs
                let fragments = MindMapBatcher.fragments(entries.filter { !mapped.contains($0.id) })
                guard !fragments.isEmpty else { completed = true; return }
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
                var remaining = fragments[...]
                var round = 0
                while !remaining.isEmpty {
                    try Task.checkCancellation()
                    guard self.generation == requestedGeneration else { return }
                    let batch = MindMapBatcher.batch(remaining, budget: engine.inputBudget)
                    round += 1
                    let left = remaining.reduce(0) { $0 + $1.text.count }
                    let rounds = round - 1 + Int((Double(left) / Double(max(1, engine.inputBudget))).rounded(.up))
                    let label = rounds > 1 ? "正在整理第 \(round)/\(rounds) 段" : "正在整理新内容"
                    self.progress = label + "…"
                    let minutes = Int(self.now().timeIntervalSince(self.sessionStartedAt) / 60)
                    let limits = MindMapLimits.forSession(minutes: minutes, local: engine.usesLocalModel)
                    let baseline = self.map
                    let request = MindMapRequest(map: baseline.hasContent ? baseline.modelContext : "[]",
                        previousTail: self.previousTail,
                        newText: batch.map(\.text).joined(separator: "\n"),
                        limits: limits, sessionMinutes: minutes)
                    let output: String
                    do {
                        output = try await engine.summarize(request, validating: { value in
                            _ = try baseline.applying(value, limits: limits)
                        }) { [weak self] partial in
                            guard let self, self.generation == requestedGeneration, !Task.isCancelled else { return }
                            self.backendDescription = engine.backendDescription
                            if !partial.isEmpty { self.progress = label + " · 已生成 \(partial.count) 字" }
                        }
                    } catch SummaryError.retryWithLocalBudget {
                        round -= 1
                        continue
                    }
                    try Task.checkCancellation()
                    guard self.generation == requestedGeneration else { return }
                    self.backendDescription = engine.backendDescription
                    let revision = try baseline.applying(output, limits: limits)
                    // Commit each merged batch, so a long catch-up shows its
                    // first map after one request instead of after all of them.
                    self.map = revision.map
                    if !revision.changedTopicIDs.isEmpty { self.recentlyChangedTopicIDs = revision.changedTopicIDs }
                    for fragment in batch where fragment.completesSource { self.mappedSourceIDs.insert(fragment.sourceID) }
                    self.previousTail = String(request.newText.suffix(240))
                    self.coveredCount = self.mappedSourceIDs.count
                    self.completedAt = self.now()
                    remaining = remaining[batch.endIndex...]
                }
                completed = true
            } catch is CancellationError { return }
            catch {
                guard self.generation == requestedGeneration, !Task.isCancelled else { return }
                self.isAutoUpdating = false
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "脑图暂时未能更新，点击重试。"
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
