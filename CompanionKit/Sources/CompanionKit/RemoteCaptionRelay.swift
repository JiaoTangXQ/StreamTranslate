#if os(macOS)
import Foundation
import CryptoKit
import Observation

private final class RelayRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward the publisher credential to another origin.
    }
}

@MainActor @Observable
public final class RemoteCaptionRelay {
    public private(set) var isRunning = false
    public private(set) var isConnected = false
    public private(set) var status = "手机可用流量或不同 Wi-Fi"
    public private(set) var pairingURL = ""
    public private(set) var configured = false
    private struct Configuration: Decodable { let origin: String; let token: String }
    private let config: Configuration?
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var latest = CompanionSnapshot(status: .stopped)
    private var wantsInvitation = false
    private var cancelPending = false
    private var invitationUntil = Date.distantPast
    private var room = ""
    private var key = SymmetricKey(size: .bits256)

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RelayRedirectPolicy(), delegateQueue: nil)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StreamTranslate/RemoteRelay.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
           let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Configuration.self, from: data),
           let url = URL(string: value.origin), url.scheme == "https", url.host != nil,
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
           url.path.isEmpty, value.token.count == 64, value.token.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            config = value; configured = true
        } else { config = nil }
    }

    public func publish(_ value: CompanionSnapshot) { latest = value }
    public func createInvitation() { wantsInvitation = true; pairingURL = "" }
    public func cancelInvitation() {
        wantsInvitation = false; pairingURL = ""; cancelPending = true
    }
    private static func randomHex() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }
    public func start() {
        guard !isRunning, configured else { return }
        isRunning = true; room = Self.randomHex(); key = SymmetricKey(size: .bits256)
        task = Task { [weak self] in await self?.run() }
    }
    public func stop() {
        guard isRunning else { return }
        let oldRoom = room
        task?.cancel(); task = nil; isRunning = false; isConnected = false
        wantsInvitation = false; cancelPending = false; pairingURL = ""; latest = .init(status: .stopped)
        status = "跨网络连接已关闭"
        Task { [weak self] in _ = try? await self?.request("close", body: ["room": oldRoom]) }
    }
    private struct Reply { let code: Int; let value: [String: Any] }
    private func restoreReaders(_ reply: Reply, room: String) async throws {
        // iOS copies authentication cookies into a Home Screen app, not localStorage.
        // Rewrap the room key for that authorized browser's ephemeral P-256 key.
        // The server authenticates the cookie; it only transports the sealed answer.
        for request in (reply.value["recoveries"] as? [[String: String]] ?? []).prefix(3) {
            try Task.checkCancellation()
            guard let id = request["id"], id.count == 64,
                  id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  let encoded = request["publicKey"], let data = Data(base64Encoded: encoded),
                  let peer = try? P256.KeyAgreement.PublicKey(x963Representation: data) else { continue }
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
            let context = Data("StreamTranslate recovery v1:\(room):\(id)".utf8)
            let wrappingKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                salt: Data(room.utf8), sharedInfo: context, outputByteCount: 32)
            let clear = key.withUnsafeBytes { Data($0) }
            let sealed = try AES.GCM.seal(clear, using: wrappingKey, authenticating: context)
            guard let combined = sealed.combined else { continue }
            _ = try await self.request("recover", body: ["room": room, "id": id,
                "publicKey": ephemeral.publicKey.x963Representation.base64EncodedString(),
                "data": combined.base64EncodedString()])
        }
    }
    private func request(_ operation: String, body: [String: Any]) async throws -> Reply {
        guard let config, let url = URL(string: config.origin + "/publisher/" + operation) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard data.count < 8192, let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return Reply(code: http.statusCode, value: (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }
    private func run() async {
        let currentRoom = room
        var opened = false, sequence: UInt64 = 0, previous: CompanionSnapshot?, count = 0
        var nextHeartbeat = Date.distantPast, failures = 0
        while !Task.isCancelled && room == currentRoom {
            do {
                if !opened {
                    status = "正在建立加密连接…"
                    let reply = try await request("open", body: ["room": currentRoom])
                    guard reply.code == 200 else { throw URLError(.userAuthenticationRequired) }
                    try Task.checkCancellation()
                    sequence = (reply.value["seq"] as? NSNumber)?.uint64Value ?? 0
                    opened = true; previous = nil; count = 0
                }
                if !pairingURL.isEmpty && invitationUntil < Date() { cancelInvitation() }
                if cancelPending {
                    cancelPending = false
                    _ = try await request("invite", body: ["room": currentRoom, "ticket": NSNull()])
                }
                if wantsInvitation {
                    wantsInvitation = false
                    let ticket = Self.randomHex()
                    let reply = try await request("invite", body: ["room": currentRoom, "ticket": ticket])
                    try Task.checkCancellation()
                    guard reply.code == 200 else { opened = false; throw URLError(.badServerResponse) }
                    // Private-mode/window dismissal during the request must not expose a QR.
                    if !cancelPending {
                        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
                        pairingURL = config!.origin + "/#" + currentRoom + "." + ticket + "." + hex
                        invitationUntil = Date().addingTimeInterval(120)
                    }
                }
                var value = latest
                // Keep remote snapshots below the connection's bounded frame budget.
                value.captions = Array(value.captions.suffix(30))
                value.sequence = previous?.sequence ?? 0
                if previous != value {
                    value.sequence = sequence + 1
                    let encoder = JSONEncoder()
                    var kind = "snapshot"
                    var data = try encoder.encode(value)
                    if let previous, previous.sessionID == value.sessionID, count < 19 {
                        let delta = try encoder.encode(CompanionDelta(previous: previous, current: value))
                        if delta.count < data.count { data = delta; kind = "change" }
                    }
                    while data.count > 160_000 && !value.captions.isEmpty {
                        value.captions.removeFirst(); data = try encoder.encode(value); kind = "snapshot"
                    }
                    let aad = Data("\(currentRoom):\(value.sequence):\(kind)".utf8)
                    let sealed = try AES.GCM.seal(data, using: key, authenticating: aad)
                    guard let combined = sealed.combined else { throw URLError(.cannotParseResponse) }
                    let reply = try await request("publish", body: ["room": currentRoom,
                        "frame": ["seq": value.sequence, "kind": kind, "data": combined.base64EncodedString()]])
                    try Task.checkCancellation()
                    guard reply.code == 200 else { opened = false; throw URLError(.badServerResponse) }
                    previous = value; sequence = value.sequence; count = kind == "snapshot" ? 0 : count + 1
                    isConnected = (reply.value["viewers"] as? Int ?? 0) > 0
                    try await restoreReaders(reply, room: currentRoom)
                } else if nextHeartbeat < Date() {
                    let reply = try await request("status", body: ["room": currentRoom])
                    try Task.checkCancellation()
                    guard reply.code == 200 else { opened = false; throw URLError(.badServerResponse) }
                    isConnected = (reply.value["viewers"] as? Int ?? 0) > 0
                    try await restoreReaders(reply, room: currentRoom)
                    nextHeartbeat = Date().addingTimeInterval(2)
                }
                failures = 0; status = isConnected ? "手机已连接 · 跨网络加密" : "已就绪，等待手机扫码"
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                if Task.isCancelled { return }
                isConnected = false; status = "暂时无法连接中转，正在自动重试…"
                failures += 1
                do { try await Task.sleep(for: .seconds(min(8, failures))) } catch { return }
            }
        }
    }
}
#endif
