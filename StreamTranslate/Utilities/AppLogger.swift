import Foundation

/// Writes logs to ~/Library/Logs/StreamTranslate.log for easy debugging.
/// Usage: AppLogger.log("message") or AppLogger.log("context", "detail")
///
/// Called from the main actor during capture, so a line is one write on a
/// handle that stays open (not open/seek/write/close per line). The file is
/// private to the user because finals and translations are logged.
enum AppLogger {
    private static let maximumBytes: UInt64 = 10 * 1_024 * 1_024
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?

    private static let logURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("StreamTranslate.log")
    }()

    private static var previousURL: URL {
        logURL.deletingLastPathComponent().appendingPathComponent("StreamTranslate.previous.log")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ items: Any...) {
        let message = items.map { "\($0)" }.joined(separator: " ")
        lock.withLock {
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let handle = openHandle() else { return }
            handle.write(Data(line.utf8))
            if handle.offsetInFile > maximumBytes { rotateLocked() }
        }
    }

    /// Clear the log file.
    static func clear() {
        lock.withLock {
            closeLocked()
            try? Data().write(to: logURL)
            restrictPermissions()
        }
    }

    /// Keep the previous launch's log so a stall or crash can still be read
    /// after the app is reopened, then start an empty log.
    static func startNewLaunch() {
        lock.withLock { rotateLocked() }
    }

    static var path: String { logURL.path }

    private static func openHandle() -> FileHandle? {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        restrictPermissions()
        let opened = try? FileHandle(forWritingTo: logURL)
        opened?.seekToEndOfFile()
        handle = opened
        return opened
    }

    private static func rotateLocked() {
        closeLocked()
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: logURL, to: previousURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    private static func closeLocked() {
        try? handle?.close()
        handle = nil
    }

    private static func restrictPermissions() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }
}
