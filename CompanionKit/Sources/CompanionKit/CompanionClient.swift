import Foundation
import Observation
import Security
@preconcurrency import Network

public enum CompanionClientState: String, Sendable {
    case unpaired, discovering, connecting, synchronizing, live, retrying, paused
}

@MainActor @Observable
public final class CompanionClient {
    private struct Pairing: Codable {
        var clientID: UUID
        var serverID: UUID
        var fingerprint: String
        var credential: String
        var serviceName: String
    }
    public private(set) var state: CompanionClientState = .unpaired
    public private(set) var status = "请扫描电脑上的配对二维码"
    public private(set) var snapshot: CompanionSnapshot?
    public private(set) var hasPairing = false
    public private(set) var receivedUpdates = 0
    public private(set) var negotiatedTLS13 = false
    public var peerToPeer = false
    @ObservationIgnored private let vault: CompanionVault
    @ObservationIgnored private var pairing: Pairing?
    @ObservationIgnored private var invitation: CompanionInvitation?
    @ObservationIgnored private var invitationClientID = UUID()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var peer: CompanionConnection?
    @ObservationIgnored private var candidates: [NWEndpoint] = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var browseDeadline: Task<Void, Never>?
    @ObservationIgnored private var snapshotDeadline: Task<Void, Never>?
    @ObservationIgnored private var replica = CompanionReplica()
    @ObservationIgnored private var authenticated = false
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var directEndpoint: NWEndpoint?
    @ObservationIgnored private var awaitingSnapshot = false

    public init(vault: CompanionVault = CompanionVault()) {
        self.vault = vault
        do {
            pairing = try vault.read(Pairing.self, account: "phone-pairing-v1")
            hasPairing = pairing != nil
            if hasPairing { status = "已配对，打开后自动连接电脑"; state = .paused }
        } catch { status = error.localizedDescription }
    }

    public func pair(url: String) throws {
        let parsed = try CompanionInvitation.parse(url)
        // Do not destroy a working pairing until the new identity authenticates.
        pause()
        invitation = parsed
        invitationClientID = UUID()
        start()
    }

    public func start() {
        guard !wantsConnection else { return }
        guard pairing != nil || invitation != nil else { state = .unpaired; return }
        wantsConnection = true
        attempt = 0
        discover()
    }

    public func reconnect() {
        pause()
        start()
    }

    /// Lifecycle suspension is expected. Never portray cached text as live.
    public func pause() {
        wantsConnection = false
        generation = UUID()
        stopDiscovery()
        retryTask?.cancel()
        retryTask = nil
        snapshotDeadline?.cancel()
        snapshotDeadline = nil
        let previous = peer
        peer = nil
        previous?.close()
        authenticated = false
        negotiatedTLS13 = false
        awaitingSnapshot = false
        replica.clear()
        snapshot = nil
        state = hasPairing ? .paused : .unpaired
        status = hasPairing ? "已暂停，打开后恢复当前字幕" : "请扫描电脑上的配对二维码"
    }

    public func forget() throws {
        pause()
        try vault.delete(account: "phone-pairing-v1")
        pairing = nil
        invitation = nil
        hasPairing = false
        state = .unpaired
        status = "已移除本机配对；更换手机请在 Mac 上解除原配对"
    }

    /// Explicit address fallback and loopback acceptance tests. TLS pinning and
    /// authentication remain mandatory; this never bypasses pairing.
    public func useDirectAddress(host: String?, port: UInt16?) {
        if let host, !host.isEmpty, let port, let nwPort = NWEndpoint.Port(rawValue: port) {
            directEndpoint = .hostPort(host: .init(host), port: nwPort)
        } else { directEndpoint = nil }
        if wantsConnection { reconnect() }
    }

    private func stopDiscovery() {
        browser?.cancel()
        browser = nil
        browseDeadline?.cancel()
        browseDeadline = nil
        candidates = []
    }

    private func discover() {
        guard wantsConnection else { return }
        if let invitation, invitation.expiresAt <= Date() {
            pause()
            self.invitation = nil
            status = "配对邀请已过期，请在 Mac 重新生成"
            return
        }
        state = .discovering
        status = "正在寻找已配对的电脑"
        let stamp = generation
        if let directEndpoint { connect(directEndpoint); return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = peerToPeer
        let browser = NWBrowser(for: .bonjour(type: CompanionLimits.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser,
                      self.generation == stamp, self.wantsConnection, self.peer == nil else { return }
                let preferred = self.invitation?.serviceName ?? self.pairing?.serviceName
                let endpoints = results.map(\.endpoint).sorted { String(describing: $0) < String(describing: $1) }
                self.candidates = Array(endpoints.sorted { a, b in
                    func preferredName(_ endpoint: NWEndpoint) -> Bool {
                        if case .service(let name, _, _, _) = endpoint { return name == preferred }
                        return false
                    }
                    return preferredName(a) && !preferredName(b)
                }.prefix(8))
                if let first = self.candidates.first {
                    self.candidates.removeFirst()
                    // Stop browsing before connecting, especially on P2P Wi-Fi.
                    self.browser?.cancel()
                    self.browser = nil
                    self.browseDeadline?.cancel()
                    self.connect(first)
                }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] value in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser, self.generation == stamp else { return }
                if case .failed = value { self.scheduleRetry("发现服务失败，请检查本地网络权限") }
                if case .waiting = value { self.status = "等待本地网络权限或可用网络" }
            }
        }
        browser.start(queue: DispatchQueue(label: "StreamTranslate.companion.discovery"))
        browseDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.generation == stamp, self.peer == nil else { return }
            self.scheduleRetry("尚未找到电脑，正在重试；请确认 Mac 服务已开启")
        }
    }

    private func connect(_ endpoint: NWEndpoint) {
        guard wantsConnection, let fingerprint = invitation?.fingerprint ?? pairing?.fingerprint else { return }
        state = .connecting
        status = "正在建立加密连接"
        authenticated = false
        awaitingSnapshot = true
        negotiatedTLS13 = false
        let connection = NWConnection(to: endpoint, using: CompanionTLS.client(fingerprint: fingerprint, peerToPeer: peerToPeer))
        let peer = CompanionConnection(connection)
        self.peer = peer
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            if let metadata = peer.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                self.negotiatedTLS13 = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13
            }
            guard self.negotiatedTLS13 else { peer.close("未协商到所需的 TLS 1.3 加密"); return }
            self.state = .synchronizing
            self.status = "正在验证身份并恢复当前字幕"
            let request: CompanionAuthentication
            if let invitation = self.invitation {
                request = .init(clientID: self.invitationClientID, name: "我的 iPhone", invitation: invitation.secret)
            } else if let pairing = self.pairing {
                request = .init(clientID: pairing.clientID, name: "我的 iPhone", credential: pairing.credential)
            } else { peer.close("缺少配对信息"); return }
            peer.send(.authenticate(request))
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer else { return }
            self.receive(message, from: peer)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peer === peer else { return }
            self.peer = nil
            self.snapshotDeadline?.cancel()
            self.snapshotDeadline = nil
            self.authenticated = false
            self.negotiatedTLS13 = false
            if self.wantsConnection { self.scheduleRetry(reason) }
        }
        peer.start()
    }

    private func scheduleRetry(_ reason: String) {
        guard wantsConnection else { return }
        state = .retrying
        status = reason
        browser?.cancel()
        browser = nil
        browseDeadline?.cancel()
        browseDeadline = nil
        retryTask?.cancel()
        let stamp = generation
        let delay = candidates.isEmpty ? min(8.0, pow(2, Double(min(attempt, 3)))) : 0.3
        attempt += 1
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(Int(delay * 1000))) } catch { return }
            guard let self, self.generation == stamp, self.wantsConnection else { return }
            if !self.candidates.isEmpty { self.connect(self.candidates.removeFirst()) }
            else { self.discover() }
        }
    }

    private func receive(_ message: CompanionMessage, from peer: CompanionConnection) {
        switch message {
        case .authorized(let serverID, let credential):
            guard !authenticated, serverID == (invitation?.serverID ?? pairing?.serverID),
                  Data(base64Encoded: credential)?.count == 32 else { peer.close("电脑身份认证失败"); return }
            do {
                if let invitation {
                    let saved = Pairing(clientID: invitationClientID, serverID: serverID,
                        fingerprint: invitation.fingerprint, credential: credential, serviceName: invitation.serviceName)
                    try vault.save(saved, account: "phone-pairing-v1")
                    pairing = saved
                    self.invitation = nil
                    hasPairing = true
                } else if let pairing, !CompanionSecrets.equal(pairing.credential, credential) {
                    peer.close("配对凭据发生变化"); return
                }
                authenticated = true
                replica.clear()
                peer.authenticated()
                startSnapshotDeadline(peer)
            } catch { peer.close("无法保存配对，请检查钥匙串"); return }
        case .snapshot(let snapshot):
            guard authenticated, replica.accept(snapshot) else { peer.close("字幕快照无效"); return }
            awaitingSnapshot = false
            snapshotDeadline?.cancel()
            snapshotDeadline = nil
            self.snapshot = replica.snapshot
            receivedUpdates += 1
            state = .live
            status = "已连接 · 加密传输"
            attempt = 0
        case .delta(let delta):
            guard authenticated else { peer.close("未认证的字幕"); return }
            if !awaitingSnapshot, replica.apply(delta) {
                snapshot = replica.snapshot
                receivedUpdates += 1
            } else if !awaitingSnapshot {
                awaitingSnapshot = true
                state = .synchronizing
                status = "正在恢复最新字幕"
                peer.send(.resynchronize)
                startSnapshotDeadline(peer)
            }
        case .ping(let nonce):
            guard authenticated else { peer.close("未认证的消息"); return }
            peer.send(.pong(nonce))
        case .pong:
            guard authenticated else { peer.close("未认证的消息"); return }
        case .rejected(let reason):
            pause()
            invitation = nil
            status = String(reason.prefix(160))
        default: peer.close("字幕协议不匹配")
        }
    }

    private func startSnapshotDeadline(_ peer: CompanionConnection) {
        snapshotDeadline?.cancel()
        snapshotDeadline = Task { [weak self, weak peer] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, let peer, self.peer === peer, self.awaitingSnapshot else { return }
            peer.close("字幕同步超时，正在重新连接")
        }
    }
}
