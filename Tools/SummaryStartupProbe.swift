import Foundation
import Darwin

// Synthetic startup only: never sends speech or user transcript. Retains logs
// under ignored build/diagnosis; exits if another summary worker is active.
func runProbe() throws -> Int {
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StreamTranslate/Summary")
    let mode = CommandLine.arguments.dropFirst().first ?? "baseline"
    let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    check.arguments = ["-f", "/Summary/runtime/llama-server"]
    check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
    try check.run(); check.waitUntilExit()
    guard check.terminationStatus != 0 else { print("SKIP existing summary worker"); return 2 }
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("summary-startup-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let socket = folder.appendingPathComponent("model.sock").path
    let log = URL(fileURLWithPath: "build/diagnosis/summary-startup-\(mode).log")
    FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let child = Process(); child.executableURL = support.appendingPathComponent("runtime/llama-server")
    child.arguments = ["-m", support.appendingPathComponent("model.gguf").path, "--host", socket,
        "-ngl", "0", "-c", "4096", "-t", "2", "-tb", "2", "-np", "1", "--jinja",
        "--chat-template-kwargs", "{\"enable_thinking\":false}", "--reasoning-budget", "0", "--no-context-shift", "--no-webui"]
    if mode != "baseline" { child.arguments! += ["--device", "none", "--no-kv-offload", "--no-op-offload"] }
    if mode == "cold" { child.arguments! += ["--no-warmup"] }
    child.qualityOfService = .utility
    child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = output
    let start = Date(); try child.run()
    print("START mode=\(mode) pid=\(child.processIdentifier)"); fflush(nil)
    defer {
        if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
    }
    while Date().timeIntervalSince(start) < 65, child.isRunning {
        let curl = Process(), pipe = Pipe(); curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["--silent", "--fail", "--max-time", "1", "--noproxy", "*", "--unix-socket", socket, "http://localhost/health"]
        curl.standardOutput = pipe; curl.standardError = FileHandle.nullDevice
        try curl.run(); curl.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if curl.terminationStatus == 0, String(decoding: data, as: UTF8.self).contains("ok") {
            print("READY mode=\(mode) seconds=\(Date().timeIntervalSince(start))"); return 0
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    print("FAILED mode=\(mode) seconds=\(Date().timeIntervalSince(start)) running=\(child.isRunning)")
    if !child.isRunning { print("EXIT reason=\(child.terminationReason.rawValue) code=\(child.terminationStatus)") }
    return 1
}
exit(Int32(try runProbe()))
