import Foundation

/// A complete bundled pair takes precedence over a development installation.
/// Never combine a bundled helper with an unrelated per-user model implicitly.
struct LocalModelAssets: Sendable {
    let executable: URL
    let model: URL

    static func resolve(name: String, executableName: String,
                        bundleURL: URL = Bundle.main.bundleURL,
                        supportURL: URL = FileManager.default.urls(
                            for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("StreamTranslate")) -> Self? {
        let bundled = Self(
            executable: bundleURL.appendingPathComponent("Contents/Helpers/\(name)/\(executableName)"),
            model: bundleURL.appendingPathComponent("Contents/Resources/Models/\(name).gguf"))
        let local = Self(
            executable: supportURL.appendingPathComponent("\(name)/runtime/\(executableName)"),
            model: supportURL.appendingPathComponent("\(name)/model.gguf"))
        return [bundled, local].first { $0.isAvailable }
    }

    private var isAvailable: Bool {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: executable.path),
              files.isReadableFile(atPath: model.path),
              let values = try? model.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        // Resolve development symlinks before checking file type and length.
        let target = model.resolvingSymlinksInPath()
        let resolved = try? target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return (resolved?.isRegularFile ?? values.isRegularFile) == true
            && (resolved?.fileSize ?? values.fileSize ?? 0) > 0
    }
}
