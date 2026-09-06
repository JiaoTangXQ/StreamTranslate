#if os(macOS)
import Foundation
import Observation
import SystemConfiguration
@preconcurrency import Network

@MainActor @Observable public final class WebCaptionServer {
    public private(set) var isRunning = false
    public private(set) var isConnected = false
    public private(set) var status = "网页字幕未开启"
    public private(set) var address = ""
    public private(set) var pairingURL = ""
    public private(set) var pairingCode = ""
    public private(set) var pairedCount = 0
    public private(set) var certificateFingerprint = ""
    public private(set) var certificateExpires: Date?
    public private(set) var transport: WebTransport = .secure
    @ObservationIgnored private var identity: WebIdentity?
    @ObservationIgnored private let vault: CompanionVault
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [UUID: WebPeer] = [:]
    @ObservationIgnored private var streams: [UUID: String] = [:]
    @ObservationIgnored private var seen: [String: Date] = [:]
    @ObservationIgnored private var current = CompanionSnapshot()
    @ObservationIgnored private var clients: [Client] = []
    @ObservationIgnored private var secret = ""
    @ObservationIgnored private var invitationExpiry = Date.distantPast
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    private struct Client: Codable { var hash: String; var expires: Date }

    public init(vault: CompanionVault = CompanionVault()) { self.vault = vault }

    public func start(port: UInt16? = nil, hostname: String? = nil, loopbackOnly: Bool = false, transport: WebTransport = .secure) {
        if listener != nil {
            guard self.transport != transport else { return }
            stop()
        }
        self.transport = transport
        let port = port ?? transport.port
        do {
            let localName = ((SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "").lowercased() + ".local"
            let host = hostname ?? (transport == .trustedLAN ? WebTransport.localIPv4() ?? localName : localName)
            let parameters: NWParameters
            if transport == .secure {
                let identity = try WebIdentity(hostname: host, vault: vault)
                self.identity = identity
                certificateFingerprint = identity.fingerprint
                certificateExpires = identity.expires
                clients = try vault.read([Client].self, account: "web-clients-v1") ?? []
                parameters = try identity.parameters()
            } else {
                identity = nil; certificateFingerprint = ""; certificateExpires = nil
                clients = [] // Never persist an unencrypted browser credential.
                parameters = NWParameters.tcp
            }
            clients.removeAll { $0.expires <= .now }
            pairedCount = clients.count
            if loopbackOnly { parameters.requiredInterfaceType = .loopback }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw WebError("无效端口") }
            let listener = try NWListener(using: parameters, on: nwPort)
            self.listener = listener
            address = "\(transport.scheme)://\(host):\(port)"
            status = "正在启动字幕网页"
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.isRunning = true; self.status = "网页已开启，等待手机配对"
                    case .failed: self.stop(); self.status = "网页无法监听，请检查端口 \(port)、网络权限和防火墙。"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: DispatchQueue(label: "StreamTranslate.web.listener"))
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self else { return }
                    if self.invitationExpiry <= .now { self.cancelInvitation() }
                    for (id, hash) in self.streams {
                        if !self.clients.contains(where: { $0.hash == hash && $0.expires > .now }) { self.peers[id]?.close() }
                        else { self.peers[id]?.heartbeat() }
                    }
                    self.updateConnected()
                }
            }
        } catch { status = error.localizedDescription }
    }

    public func stop() {
        listener?.cancel(); listener = nil; timer?.cancel(); timer = nil
        cancelInvitation()
        for peer in Array(peers.values) { peer.close() }
        peers.removeAll(); streams.removeAll(); seen.removeAll()
        current = CompanionSnapshot()
        if transport == .trustedLAN { clients = []; pairedCount = 0 }
        isRunning = false; isConnected = false; status = "网页字幕已关闭"
    }
    public func createInvitation() {
        clients.removeAll { $0.expires <= .now }; pairedCount = clients.count
        guard isRunning, clients.count < 3 else { status = "最多授权 3 个浏览器，请先解除旧配对。"; return }
        do {
            secret = try CompanionSecrets.random()
            pairingCode = String(format: "%08u", arc4random_uniform(100_000_000))
            failures = 0
            invitationExpiry = Date().addingTimeInterval(120)
            var url = URLComponents(string: address + "/")!
            url.fragment = secret
            pairingURL = url.string ?? ""
        } catch { status = error.localizedDescription }
    }
    public func cancelInvitation() {
        secret = ""; pairingCode = ""; pairingURL = ""; invitationExpiry = .distantPast
    }
    public func revokePairings() {
        do {
            if transport == .secure { try vault.delete(account: "web-clients-v1") }
            clients = []; pairedCount = 0; seen = [:]; cancelInvitation()
            for id in Array(streams.keys) { peers[id]?.close() }
            updateConnected()
        } catch { status = error.localizedDescription }
    }
    public func resetCertificate() {
        stop()
        do {
            try vault.delete(account: "web-clients-v1")
            try vault.delete(account: "web-identity-v1")
            clients = []; pairedCount = 0; identity = nil
            certificateFingerprint = ""; certificateExpires = nil
            status = "证书已重置；请重新开启并重新安装手机证书，删除旧描述文件。"
        } catch { status = error.localizedDescription }
    }
    public func certificateProfile() throws -> Data {
        guard let identity else { throw WebError("请先开启网页服务。") }
        return try identity.profile()
    }
    public var rootCertificate: Data? { identity?.rootDER }

    public func publish(_ snapshot: CompanionSnapshot) {
        guard isRunning, snapshot.isValid() else { return }
        var next = snapshot
        next.sequence = current.sequence
        guard next != current else { return }
        next.sequence &+= 1
        let previous = current
        current = next
        guard let data = event(snapshot: next) else { return }
        var update = data
        if previous.sessionID == next.sessionID,
           let json = try? JSONEncoder().encode(CompanionDelta(previous: previous, current: next)) {
            let delta = Data("event: change\ndata: ".utf8) + json + Data("\n\n".utf8)
            if delta.count < data.count { update = delta }
        }
        for id in Array(streams.keys) { peers[id]?.event(update, fallback: data) }
    }
    private func event(snapshot: CompanionSnapshot) -> Data? {
        guard let json = try? JSONEncoder().encode(snapshot), json.count <= CompanionLimits.maximumFrameBytes else { return nil }
        return Data("event: snapshot\ndata: ".utf8) + json + Data("\n\n".utf8)
    }
    private func accept(_ connection: NWConnection) {
        guard listener != nil, peers.count < 24 else { connection.cancel(); return }
        guard case .hostPort(let host, _) = connection.endpoint else { connection.cancel(); return }
        let bytes: Data
        switch host {
        case .ipv4(let ip): bytes = ip.rawValue
        case .ipv6(let ip): bytes = ip.rawValue
        default: connection.cancel(); return
        }
        guard WebRequest.isPrivateAddress(bytes) else { connection.cancel(); return }
        let peer = WebPeer(connection)
        peers[peer.id] = peer
        peer.onRequest = { [weak self, weak peer] request in
            guard let self, let peer else { return }
            self.route(request, peer: peer)
        }
        peer.onClose = { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.peers[peer.id] = nil; self.streams[peer.id] = nil; self.updateConnected()
        }
        peer.start()
    }
    private func updateConnected() {
        isConnected = streams.values.contains { hash in
            (seen[hash] ?? .distantPast) > Date().addingTimeInterval(-10)
        }
        if isRunning { status = isConnected ? "手机网页正在接收字幕 · \(transport == .secure ? "HTTPS 加密" : "局域网未加密")" : "网页已开启，等待手机连接" }
    }
    private func authenticated(_ request: WebRequest) -> String? {
        let cookies = (request.headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let prefix = transport.cookieName + "="
        let values = cookies.filter { $0.hasPrefix(prefix) }
        guard values.count == 1 else { return nil }
        let value = String(values[0].dropFirst(prefix.count))
        let hash = CompanionSecrets.fingerprint(Data(value.utf8))
        return clients.first { CompanionSecrets.equal($0.hash, hash) && $0.expires > .now }?.hash
    }
    private func route(_ request: WebRequest, peer: WebPeer) {
        guard request.headers["host"]?.lowercased() == String(address.dropFirst(transport.scheme.count + 3)).lowercased(),
              request.headers["origin"].map({ $0 == address }) ?? true else { peer.respond(403, text: "Origin denied"); return }
        if request.method == "POST" {
            guard request.headers["origin"] == address,
                  request.headers["content-type"] == "application/json" else { peer.respond(403, text: "Origin required"); return }
        }
        if request.method == "GET" {
            switch request.path {
            case "/": peer.respond(200, text: WebAssets.html, type: "text/html; charset=utf-8")
            case "/app.js": peer.respond(200, text: WebAssets.js, type: "text/javascript; charset=utf-8")
            case "/style.css": peer.respond(200, text: WebAssets.css, type: "text/css; charset=utf-8")
            case "/manifest.webmanifest": peer.respond(200, text: WebAssets.manifest, type: "application/manifest+json")
            case "/icon.svg": peer.respond(200, text: WebAssets.icon, type: "image/svg+xml")
            case "/api/state":
                peer.respond(authenticated(request) == nil ? 401 : 200, text: "{}", type: "application/json")
            case "/api/events":
                guard let hash = authenticated(request), let data = event(snapshot: current) else { peer.respond(401, text: "Pair again"); return }
                // Safari and Home Screen can have separate storage. Each
                // explicitly paired browser may hold one active stream.
                for (id, value) in streams where value == hash { peers[id]?.close() }
                streams[peer.id] = hash
                peer.beginStream(data)
            default: peer.respond(404, text: "Not found")
            }
            return
        }
        switch request.path {
        case "/api/pair":
            guard invitationExpiry > .now, !secret.isEmpty, clients.count < 3, failures < 6 else {
                peer.respond(403, text: "邀请已失效，请在 Mac 重新生成配对码。"); return
            }
            let value = (try? JSONSerialization.jsonObject(with: request.body) as? [String: String])?["invitation"] ?? ""
            guard CompanionSecrets.equal(value, secret) || CompanionSecrets.equal(value, pairingCode) else {
                failures += 1
                if failures >= 6 { cancelInvitation() }
                peer.respond(403, text: "配对码不正确或已失效。"); return
            }
            do {
                let token = try CompanionSecrets.random().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                let client = Client(hash: CompanionSecrets.fingerprint(Data(token.utf8)), expires: Date().addingTimeInterval(TimeInterval(transport.authorizationSeconds)))
                let next = clients + [client]
                if transport == .secure { try vault.save(next, account: "web-clients-v1") }
                clients = next; pairedCount = clients.count; cancelInvitation()
                peer.respond(200, text: "{}", type: "application/json",
                    extra: "Set-Cookie: \(transport.cookieName)=\(token); \(transport.cookieAttributes)\r\n")
            } catch { peer.respond(500, text: "无法保存配对，请在 Mac 检查钥匙串。") }
        case "/api/seen":
            guard let hash = authenticated(request) else { peer.respond(401, text: "Pair again"); return }
            seen[hash] = .now; updateConnected(); peer.respond(200, text: "{}", type: "application/json")
        default: peer.respond(404, text: "Not found")
        }
    }
}
#endif
