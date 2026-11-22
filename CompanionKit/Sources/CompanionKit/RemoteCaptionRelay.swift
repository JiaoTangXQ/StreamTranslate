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

/// The room a phone pairs with once. Saved in the login keychain so Mac and
/// relay restarts keep the same room, key and authorized browsers.
struct RemoteRelayRoom: Codable, Equatable, Sendable {
    var room: String
    var key: String
    var devices: [RemoteRelayDevice]

    static func random() -> Self {
        func hex() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } }
        return Self(room: hex(), key: hex(), devices: [])
    }

    var isValid: Bool {
        [room, key].allSatisfy { $0.count == 64 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    }

    var symmetricKey: SymmetricKey {
        var bytes = [UInt8](), index = key.startIndex
        while index < key.endIndex {
            let next = key.index(index, offsetBy: 2)
            bytes.append(UInt8(key[index..<next], radix: 16) ?? 0)
            index = next
        }
        return SymmetricKey(data: Data(bytes))
    }
}

@MainActor @Observable
public final class RemoteCaptionRelay {
    public private(set) var isRunning = false
    public private(set) var isConnected = false
    public private(set) var status = "手机可用流量或不同 Wi-Fi"
    public private(set) var pairingURL = ""
    public private(set) var configured = false
    public private(set) var pairedDeviceCount = 0
    /// Set by the app: whether audio uploaded from the phone page is fetched.
    public var acceptsPhoneAudio = false {
        didSet { if acceptsPhoneAudio != oldValue { restartAudioLoop() } }
    }
    /// Decrypted phone audio, in upload order.
    public let phoneAudio: AsyncStream<PhoneAudioBatch>
    private let phoneAudioInput: AsyncStream<PhoneAudioBatch>.Continuation
    private struct Configuration: Decodable { let origin: String; let token: String }
    private let config: Configuration?
    private let session: URLSession
    private let vault: CompanionVault
    private var task: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var latest = CompanionSnapshot(status: .stopped)
    private var wantsInvitation = false
    private var cancelPending = false
    private var invitationUntil = Date.distantPast
    private var saved = RemoteRelayRoom.random()
    private var lastAudio: [String: UInt64] = [:]
    private static let vaultAccount = "remote-relay-room"

    public init(vault: CompanionVault = CompanionVault()) {
        self.vault = vault
        (phoneAudio, phoneAudioInput) = AsyncStream<PhoneAudioBatch>.makeStream(bufferingPolicy: .bufferingNewest(240))
        session = Self.makeSession()
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

    /// Fixtures only: a loopback relay with its own vault service, so tests
    /// never touch the user's provisioning file or saved room.
    public init(loopbackOrigin origin: String, token: String, vault: CompanionVault) {
        self.vault = vault
        (phoneAudio, phoneAudioInput) = AsyncStream<PhoneAudioBatch>.makeStream(bufferingPolicy: .bufferingNewest(240))
        session = Self.makeSession()
        if let url = URL(string: origin), url.scheme == "http", url.host == "127.0.0.1", token.count == 64 {
            config = Configuration(origin: origin, token: token); configured = true
        } else { config = nil }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RelayRedirectPolicy(), delegateQueue: nil)
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
        if let stored = try? vault.read(RemoteRelayRoom.self, account: Self.vaultAccount), stored.isValid {
            saved = stored
        } else {
            saved = .random(); persist()
        }
        pairedDeviceCount = saved.devices.count
        isRunning = true
        let room = saved.room
        task = Task { [weak self] in await self?.run(room: room) }
        restartAudioLoop()
    }

    public func stop() {
        guard isRunning else { return }
        let room = saved.room
        task?.cancel(); task = nil
        audioTask?.cancel(); audioTask = nil
        isRunning = false; isConnected = false
        wantsInvitation = false; cancelPending = false; pairingURL = ""; latest = .init(status: .stopped)
        status = "跨网络连接已关闭"
        // Paired phones stay paired; the relay drops buffered ciphertext and
        // shows them "computer offline" instead of a pairing screen.
        Task { [weak self] in _ = try? await self?.request("offline", body: ["room": room]) }
    }

    /// Forget every paired phone: a new room and key make old links and
    /// cookies useless, and the old room is closed on the relay.
    public func revokeAllDevices() {
        let oldRoom = saved.room, wasRunning = isRunning
        stop()
        saved = .random(); persist(); pairedDeviceCount = 0
        Task { [weak self] in _ = try? await self?.request("close", body: ["room": oldRoom]) }
        if wasRunning { start() }
        status = "已撤销所有手机授权"
    }

    private func persist() {
        try? vault.save(saved, account: Self.vaultAccount)
    }

    private struct Reply { let code: Int; let value: [String: Any] }

    private func updateDevices(_ reply: Reply) {
        guard let rows = reply.value["devices"] as? [[String: Any]] else { return }
        let reported = rows.compactMap { row -> RemoteRelayDevice? in
            guard let hash = row["hash"] as? String, let expires = (row["expires"] as? NSNumber)?.doubleValue else { return nil }
            return RemoteRelayDevice(hash: hash, expires: expires)
        }
        let now = Date().timeIntervalSince1970 * 1000
        if let next = RemoteRelayDevice.reconciled(saved: saved.devices, reported: reported, now: now) {
            saved.devices = next; persist()
        }
        pairedDeviceCount = saved.devices.count
    }

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
            let clear = saved.symmetricKey.withUnsafeBytes { Data($0) }
            let sealed = try AES.GCM.seal(clear, using: wrappingKey, authenticating: context)
            guard let combined = sealed.combined else { continue }
            _ = try await self.request("recover", body: ["room": room, "id": id,
                "publicKey": ephemeral.publicKey.x963Representation.base64EncodedString(),
                "data": combined.base64EncodedString()])
        }
    }

    private func request(_ operation: String, body: [String: Any], limit: Int = 8192) async throws -> Reply {
        guard let config, let url = URL(string: config.origin + "/publisher/" + operation) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard data.count < limit, let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return Reply(code: http.statusCode, value: (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    private func restartAudioLoop() {
        audioTask?.cancel(); audioTask = nil
        guard isRunning, acceptsPhoneAudio else { return }
        let room = saved.room, key = saved.symmetricKey
        audioTask = Task { [weak self] in await self?.pullAudio(room: room, key: key) }
    }

    /// Long-polls the relay for encrypted phone audio and yields it in order.
    private func pullAudio(room: String, key: SymmetricKey) async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let reply = try await request("audio", body: ["room": room], limit: 2_000_000)
                try Task.checkCancellation()
                guard reply.code == 200 else { throw URLError(.badServerResponse) }
                failures = 0
                for item in reply.value["items"] as? [[String: Any]] ?? [] {
                    guard let stream = item["stream"] as? String, let sequence = (item["seq"] as? NSNumber)?.uint64Value,
                          let data = item["data"] as? String, sequence > lastAudio[stream, default: 0],
                          let batch = try? PhoneAudioBatch.open(sealed: data, stream: stream, sequence: sequence,
                                                                room: room, key: key) else { continue }
                    lastAudio[stream] = sequence
                    if lastAudio.count > 16 { lastAudio = [stream: sequence] }
                    phoneAudioInput.yield(batch)
                }
            } catch {
                if Task.isCancelled { return }
                failures += 1
                do { try await Task.sleep(for: .seconds(min(5, failures))) } catch { return }
            }
        }
    }

    private func run(room currentRoom: String) async {
        var opened = false, sequence: UInt64 = 0, previous: CompanionSnapshot?, count = 0
        var nextHeartbeat = Date.distantPast, failures = 0
        while !Task.isCancelled && saved.room == currentRoom {
            do {
                if !opened {
                    status = "正在建立加密连接…"
                    let devices = saved.devices.map { ["hash": $0.hash, "expires": $0.expires] as [String: Any] }
                    let reply = try await request("open", body: ["room": currentRoom, "devices": devices])
                    guard reply.code == 200 else { throw URLError(.userAuthenticationRequired) }
                    try Task.checkCancellation()
                    sequence = (reply.value["seq"] as? NSNumber)?.uint64Value ?? 0
                    updateDevices(reply)
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
                    if !cancelPending, let config {
                        pairingURL = config.origin + "/#" + currentRoom + "." + ticket + "." + saved.key
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
                    let sealed = try AES.GCM.seal(data, using: saved.symmetricKey, authenticating: aad)
                    guard let combined = sealed.combined else { throw URLError(.cannotParseResponse) }
                    let reply = try await request("publish", body: ["room": currentRoom,
                        "frame": ["seq": value.sequence, "kind": kind, "data": combined.base64EncodedString()]])
                    try Task.checkCancellation()
                    guard reply.code == 200 else { opened = false; throw URLError(.badServerResponse) }
                    previous = value; sequence = value.sequence; count = kind == "snapshot" ? 0 : count + 1
                    isConnected = (reply.value["viewers"] as? Int ?? 0) > 0
                    updateDevices(reply)
                    try await restoreReaders(reply, room: currentRoom)
                } else if nextHeartbeat < Date() {
                    let reply = try await request("status", body: ["room": currentRoom])
                    try Task.checkCancellation()
                    guard reply.code == 200 else { opened = false; throw URLError(.badServerResponse) }
                    isConnected = (reply.value["viewers"] as? Int ?? 0) > 0
                    updateDevices(reply)
                    try await restoreReaders(reply, room: currentRoom)
                    nextHeartbeat = Date().addingTimeInterval(2)
                }
                failures = 0
                status = isConnected ? "手机已连接 · 跨网络加密"
                    : pairedDeviceCount > 0 ? "已就绪 · \(pairedDeviceCount) 台手机已配对" : "已就绪，等待手机扫码"
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
