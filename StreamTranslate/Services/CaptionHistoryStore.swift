import Foundation
import Observation

struct CaptionHistorySession: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let preview: String
}

/// Text-only, append-only journals. Translation/review updates retain the same
/// caption UUID; reading folds them into the latest version of each sentence.
/// All disk work is serialized off the main thread, including deletion.
@MainActor @Observable
final class CaptionHistoryStore {
    private(set) var revision = 0
    private(set) var sessionListRevision = 0
    private(set) var sessionRevisions: [UUID: Int] = [:]
    private(set) var errorMessage: String?
    private(set) var readWarning: String?
    @ObservationIgnored private var mutationGeneration = 0
    @ObservationIgnored private let queue = DispatchQueue(label: "StreamTranslate.caption-history", qos: .utility)
    @ObservationIgnored private let archive: CaptionHistoryArchive

    init(directory: URL? = nil) {
        archive = CaptionHistoryArchive(directory: directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamTranslate/TranscriptHistory", isDirectory: true))
    }

    func record(_ entry: CaptionEntry, sessionID: UUID, startedAt: Date) {
        let archive = archive
        let generation = mutationGeneration
        queue.async { [weak self] in
            let error: String?
            let created: Bool
            do {
                created = try archive.record(entry, sessionID: sessionID, startedAt: startedAt)
                error = nil
            } catch let failure {
                created = false
                error = "字幕记录未能保存：\(failure.localizedDescription)"
            }
            Task { @MainActor [weak self] in
                guard let self, self.mutationGeneration == generation else { return }
                if let error { self.errorMessage = error }
                self.sessionRevisions[sessionID, default: 0] &+= 1
                if created { self.sessionListRevision &+= 1 }
                self.revision &+= 1
            }
        }
    }

    func sessions() async throws -> [CaptionHistorySession] {
        let archive = archive
        let listing = try await perform { try archive.sessions() }
        readWarning = listing.invalidCount > 0
            ? "有 \(listing.invalidCount) 次记录的索引损坏，其他记录仍可查看。可用清空按钮删除此窗口内的全部记录。" : nil
        return listing.sessions
    }

    func captions(in sessionID: UUID) async throws -> [CaptionEntry] {
        let archive = archive
        return try await perform { try archive.captions(in: sessionID) }
    }

    func clear() async throws {
        mutationGeneration &+= 1
        let archive = archive
        try await perform { try archive.clear() }
        errorMessage = nil
        readWarning = nil
        sessionRevisions = [:]
        sessionListRevision &+= 1
        revision &+= 1
    }

    /// Also serves as a FIFO barrier for shutdown and deterministic tests.
    func flush() async throws { try await perform {} }

    func finishPendingWrites() { queue.sync {} }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private struct CaptionHistoryArchive: Sendable {
    let directory: URL

    func record(_ entry: CaptionEntry, sessionID: UUID, startedAt: Date) throws -> Bool {
        let folder = directory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let metadata = folder.appendingPathComponent("session.json")
        let created = !manager.fileExists(atPath: metadata.path)
        if created {
            let session = CaptionHistorySession(id: sessionID,
                startedAt: startedAt == .distantPast ? entry.timestamp : startedAt,
                preview: String(entry.originalText.prefix(80)))
            try JSONEncoder().encode(session).write(to: metadata, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        }
        let journal = folder.appendingPathComponent("captions.jsonl")
        if !manager.fileExists(atPath: journal.path) {
            guard manager.createFile(atPath: journal.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: journal)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONEncoder().encode(entry) + Data([10]))
        return created
    }

    struct Listing: Sendable {
        var sessions: [CaptionHistorySession] = []
        var invalidCount = 0
    }

    func sessions() throws -> Listing {
        guard FileManager.default.fileExists(atPath: directory.path) else { return Listing() }
        let folders = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        var listing = Listing()
        for folder in folders {
            do {
                let session = try JSONDecoder().decode(CaptionHistorySession.self,
                    from: Data(contentsOf: folder.appendingPathComponent("session.json")))
                guard session.id.uuidString == folder.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
                listing.sessions.append(session)
            } catch { listing.invalidCount += 1 }
        }
        listing.sessions.sort { $0.startedAt > $1.startedAt }
        return listing
    }

    func captions(in sessionID: UUID) throws -> [CaptionEntry] {
        let journal = directory.appendingPathComponent(sessionID.uuidString)
            .appendingPathComponent("captions.jsonl")
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        let data = try Data(contentsOf: journal)
        var entries: [CaptionEntry] = []
        var positions: [UUID: Int] = [:]
        let lines = data.split(separator: 10, omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            // A process interruption can leave an incomplete final write. It
            // must not make the preceding complete transcript unreadable.
            if index == lines.count - 1, data.last != 10 { break }
            let entry = try JSONDecoder().decode(CaptionEntry.self, from: Data(line))
            if let position = positions[entry.id] { entries[position] = entry }
            else { positions[entry.id] = entries.count; entries.append(entry) }
        }
        return entries
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
