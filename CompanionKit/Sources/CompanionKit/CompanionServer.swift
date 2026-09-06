#if os(macOS)
import Foundation
import Observation
@preconcurrency import Network

@MainActor @Observable
public final class CompanionServer {
    public private(set) var isRunning = false
    public private(set) var isConnected = false
    public private(set) var status = "手机字幕服务未开启"
    public private(set) var pairingURL = ""
    public private(set) var pairingExpiresAt: Date?
    public private(set) var pairedNames: [String] = []
    public private(set) var port: UInt16?
    public private(set) var serviceName = ""
    public private(set) var peerToPeer = false
    public private(set) var fingerprint = ""
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var identity: CompanionServerIdentity?
    @ObservationIgnored private var connections: [UUID: CompanionConnection] = [:]
    @ObservationIgnored private var authorized: [UUID: UUID] = [:]
    @ObservationIgnored private var authorizer = CompanionAuthorizer()
    @ObservationIgnored private var current = CompanionSnapshot()
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let vault: CompanionVault

    public init(vault: CompanionVault = CompanionVault()) { self.vault = vault }

    public func start(peerToPeer: Bool = false, loopbackOnly: Bool = false) {
        guard listener == nil else { return }
        do {
            let identity = try CompanionServerIdentity(vault: vault)
            self.identity = identity
            fingerprint = identity.fingerprint
            authorizer = CompanionAuthorizer(clients: try vault.read([CompanionTrustedClient].self, account: "clients-v1") ?? [])
            pairedNames = authorizer.clients.map(\.name)
            self.peerToPeer = peerToPeer
            let parameters = try identity.parameters(peerToPeer: peerToPeer)
            if loopbackOnly { parameters.requiredInterfaceType = .loopback }
            let listener = try NWListener(using: parameters)
            serviceName = "StreamTranslate-" + String(UUID().uuidString.prefix(8))
            if !loopbackOnly { listener.service = .init(name: serviceName, type: CompanionLimits.serviceType) }
            self.listener = listener
            status = "正在启动安全字幕服务"
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.port = listener.port?.rawValue
                        self.status = "等待已配对的 iPhone"
                    case .failed:
                        self.stop()
                        self.status = "无法启动服务，请检查本地网络权限和防火墙"
                    case .waiting:
                        self.status = "等待网络或本地网络权限"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: DispatchQueue(label: "StreamTranslate.companion.listener"))
        } catch {
            stop()
            status = error.localizedDescription
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        expiryTask?.cancel()
        expiryTask = nil
        authorizer.invite(nil)
        pairingURL = ""
        pairingExpiresAt = nil
        for peer in Array(connections.values) { peer.close("电脑已关闭手机字幕服务") }
        connections.removeAll()
        authorized.removeAll()
        isRunning = false
        isConnected = false
        port = nil
        status = "手机字幕服务未开启"
    }

    public func createInvitation() {
        guard isRunning, let identity, authorizer.clients.isEmpty else {
            status = "请先开启服务；更换手机前需要解除原配对"
            return
        }
        do {
            let invitation = CompanionInvitation(serviceName: serviceName, fingerprint: identity.fingerprint,
                secret: try CompanionSecrets.random(), expiresAt: Date().addingTimeInterval(120), serverID: identity.id)
            authorizer.invite(invitation)
            pairingURL = try invitation.url()
            pairingExpiresAt = invitation.expiresAt
            expiryTask?.cancel()
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                self?.cancelInvitation()
            }
        } catch { status = error.localizedDescription }
    }

    public func cancelInvitation() {
        expiryTask?.cancel()
        expiryTask = nil
        authorizer.invite(nil)
        pairingURL = ""
        pairingExpiresAt = nil
    }

    public func revokePairing() {
        do {
            try vault.delete(account: "clients-v1")
            authorizer.revokeAll()
            cancelInvitation()
            pairedNames = []
            for peer in Array(connections.values) { peer.close("配对已解除") }
            status = "配对已解除，可为新手机生成二维码"
        } catch { status = error.localizedDescription }
    }

    public func publish(_ snapshot: CompanionSnapshot) {
        guard snapshot.isValid() else { return }
        var next = snapshot
        next.sequence = current.sequence
        guard next != current else { return }
        next.sequence = current.sequence &+ 1
        let changedSession = next.sessionID != current.sessionID
        let delta = CompanionDelta(previous: current, current: next)
        current = next
        for id in Array(authorized.keys) {
            connections[id]?.send(changedSession ? .snapshot(next) : .delta(delta))
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 4 else { connection.cancel(); return }
        let peer = CompanionConnection(connection)
        connections[peer.id] = peer
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.receive(message, from: peer)
        }
        peer.onClose = { [weak self, weak peer] _ in
            guard let self, let peer else { return }
            self.connections[peer.id] = nil
            self.authorized[peer.id] = nil
            self.isConnected = !self.authorized.isEmpty
            if self.isRunning { self.status = self.isConnected ? "iPhone 已连接" : "等待手机重新连接" }
        }
        peer.start()
    }

    private func receive(_ message: CompanionMessage, from peer: CompanionConnection) {
        if authorized[peer.id] == nil {
            guard case .authenticate(let request) = message, let identity else {
                peer.close("需要先完成配对认证"); return
            }
            do {
                var candidate = authorizer
                guard let client = try candidate.authorize(request) else {
                    peer.reject("配对已失效，请在 Mac 解除旧配对并重新绑定"); return
                }
                try vault.save(candidate.clients, account: "clients-v1")
                authorizer = candidate
                cancelInvitation()
                pairedNames = candidate.clients.map(\.name)
                // Deduplicate after authentication, never using an untrusted claimed ID.
                for (id, clientID) in Array(authorized) where clientID == client.id && id != peer.id {
                    connections[id]?.close("手机已建立新连接")
                }
                authorized[peer.id] = client.id
                isConnected = true
                status = "iPhone 已连接（TLS 加密）"
                peer.authenticated()
                peer.send(.authorized(serverID: identity.id, credential: client.credential))
                peer.send(.snapshot(current))
            } catch { peer.close("无法保存安全配对，请在电脑检查钥匙串") }
            return
        }
        switch message {
        case .ping(let nonce): peer.send(.pong(nonce))
        case .pong: break
        case .resynchronize: peer.send(.snapshot(current))
        default: peer.close("手机仅允许读取字幕")
        }
    }
}
#endif
