import Foundation

public enum CompanionLimits {
    public static let protocolVersion = 1
    public static let maximumFrameBytes = 2 * 1024 * 1024
    public static let maximumHistory = 60
    public static let maximumTextCharacters = 4_000
    public static let serviceType = "_stcaption._tcp"
}

public struct CompanionCaption: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var original: String
    public var translation: String
    public var language: String

    public init(id: UUID, timestamp: Date, original: String, translation: String, language: String) {
        self.id = id
        self.timestamp = timestamp
        self.original = String(original.prefix(CompanionLimits.maximumTextCharacters))
        self.translation = String(translation.prefix(CompanionLimits.maximumTextCharacters))
        self.language = String(language.prefix(32))
    }
}

public enum CompanionEngineStatus: String, Codable, Sendable {
    case ready, preparing, listening, finishing, stopped, unavailable
    public var title: String {
        switch self {
        case .ready: "已就绪"
        case .preparing: "电脑正在准备翻译"
        case .listening: "正在聆听"
        case .finishing: "正在完成最后一句"
        case .stopped: "电脑已停止翻译"
        case .unavailable: "请在电脑上检查翻译设置"
        }
    }
}

public struct CompanionSnapshot: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var sequence: UInt64
    public var captions: [CompanionCaption]
    public var streaming: CompanionCaption?
    public var status: CompanionEngineStatus

    public init(sessionID: UUID = UUID(), sequence: UInt64 = 0,
                captions: [CompanionCaption] = [], streaming: CompanionCaption? = nil,
                status: CompanionEngineStatus = .ready) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.captions = Array(captions.suffix(CompanionLimits.maximumHistory))
        self.streaming = streaming
        self.status = status
    }

    public func isValid() -> Bool {
        let rows = captions + (streaming.map { [$0] } ?? [])
        return captions.count <= CompanionLimits.maximumHistory
            && Set(captions.map(\.id)).count == captions.count
            && rows.allSatisfy {
                $0.original.count <= CompanionLimits.maximumTextCharacters
                    && $0.translation.count <= CompanionLimits.maximumTextCharacters
                    && $0.language.count <= 32 && $0.timestamp.timeIntervalSince1970.isFinite
            }
    }
}

public struct CompanionDelta: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var sequence: UInt64
    public var upserts: [CompanionCaption]
    public var retainedIDs: [UUID]
    public var streaming: CompanionCaption?
    public var status: CompanionEngineStatus

    public init(previous: CompanionSnapshot, current: CompanionSnapshot) {
        sessionID = current.sessionID
        sequence = current.sequence
        let previousRows = Dictionary(uniqueKeysWithValues: previous.captions.map { ($0.id, $0) })
        upserts = current.captions.filter { previousRows[$0.id] != $0 }
        retainedIDs = current.captions.map(\.id)
        streaming = current.streaming
        status = current.status
    }
}

/// A gap requires a fresh snapshot, never a best-effort merge of stale text.
public struct CompanionReplica: Sendable {
    public private(set) var snapshot: CompanionSnapshot?
    public init() {}
    public mutating func clear() { snapshot = nil }
    @discardableResult public mutating func accept(_ value: CompanionSnapshot) -> Bool {
        guard value.isValid() else { return false }
        if let previous = snapshot, value.sessionID == previous.sessionID,
           value.sequence < previous.sequence { return false }
        snapshot = value
        return true
    }
    @discardableResult public mutating func apply(_ delta: CompanionDelta) -> Bool {
        guard let previous = snapshot,
              previous.sessionID == delta.sessionID,
              previous.sequence < UInt64.max,
              delta.sequence == previous.sequence + 1,
              delta.upserts.count <= CompanionLimits.maximumHistory,
              delta.retainedIDs.count <= CompanionLimits.maximumHistory,
              Set(delta.retainedIDs).count == delta.retainedIDs.count,
              Set(delta.upserts.map(\.id)).count == delta.upserts.count else { return false }
        var rows = Dictionary(uniqueKeysWithValues: previous.captions.map { ($0.id, $0) })
        for row in delta.upserts { rows[row.id] = row }
        let ordered = delta.retainedIDs.compactMap { rows[$0] }
        guard ordered.count == delta.retainedIDs.count else { return false }
        let next = CompanionSnapshot(sessionID: delta.sessionID, sequence: delta.sequence,
                                     captions: ordered, streaming: delta.streaming, status: delta.status)
        return accept(next)
    }
}

public struct CompanionAuthentication: Codable, Sendable {
    public var version: Int
    public var clientID: UUID
    public var name: String
    public var invitation: String?
    public var credential: String?
    public init(clientID: UUID, name: String, invitation: String? = nil, credential: String? = nil) {
        version = CompanionLimits.protocolVersion
        self.clientID = clientID
        self.name = String(name.prefix(64))
        self.invitation = invitation
        self.credential = credential
    }
}

public enum CompanionMessage: Codable, Sendable {
    case authenticate(CompanionAuthentication)
    case authorized(serverID: UUID, credential: String)
    case snapshot(CompanionSnapshot)
    case delta(CompanionDelta)
    case resynchronize
    case ping(UInt64)
    case pong(UInt64)
    case rejected(String)
}

public enum CompanionProtocolError: Error, LocalizedError {
    case invalidFrame, invalidPairing, unavailableIdentity, keychain(Int32), invalidCertificate
    public var errorDescription: String? {
        switch self {
        case .invalidFrame: "字幕协议数据无效或超过大小限制"
        case .invalidPairing: "配对链接无效或已过期，请在电脑上重新生成"
        case .unavailableIdentity: "无法创建安全连接身份"
        case .keychain(let status): "无法访问安全凭据（\(status)）"
        case .invalidCertificate: "电脑身份与配对记录不一致"
        }
    }
}

/// Length-prefixed JSON over a reliable, encrypted byte stream.
public struct CompanionFrameDecoder: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [CompanionMessage] {
        guard buffer.count + bytes.count <= CompanionLimits.maximumFrameBytes + 4 + 64 * 1024 else {
            throw CompanionProtocolError.invalidFrame
        }
        buffer.append(bytes)
        var messages: [CompanionMessage] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= CompanionLimits.maximumFrameBytes else {
                throw CompanionProtocolError.invalidFrame
            }
            guard buffer.count >= size + 4 else { break }
            let payload = Data(buffer.dropFirst(4).prefix(size))
            messages.append(try JSONDecoder().decode(CompanionMessage.self, from: payload))
            buffer = Data(buffer.dropFirst(size + 4))
        }
        return messages
    }
    public static func encode(_ message: CompanionMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard !payload.isEmpty, payload.count <= CompanionLimits.maximumFrameBytes else {
            throw CompanionProtocolError.invalidFrame
        }
        let size = UInt32(payload.count)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + payload
    }
}

public struct CompanionInvitation: Codable, Equatable, Sendable {
    public var serviceName: String
    public var fingerprint: String
    public var secret: String
    public var expiresAt: Date
    public var serverID: UUID

    public init(serviceName: String, fingerprint: String, secret: String, expiresAt: Date, serverID: UUID) {
        self.serviceName = serviceName
        self.fingerprint = fingerprint
        self.secret = secret
        self.expiresAt = expiresAt
        self.serverID = serverID
    }
    public func url() throws -> String {
        let data = try JSONEncoder().encode(self)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "streamtranslate://pair?v=1&data=\(encoded)"
    }
    public static func parse(_ string: String, now: Date = Date()) throws -> Self {
        guard string.utf8.count <= 4096, let url = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "streamtranslate", url.host == "pair",
              url.queryItems?.first(where: { $0.name == "v" })?.value == "1",
              var raw = url.queryItems?.first(where: { $0.name == "data" })?.value else {
            throw CompanionProtocolError.invalidPairing
        }
        raw = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: raw), let invitation = try? JSONDecoder().decode(Self.self, from: data),
              invitation.expiresAt > now, invitation.expiresAt.timeIntervalSince(now) <= 10 * 60,
              invitation.fingerprint.count == 64,
              invitation.fingerprint.allSatisfy({ $0.isHexDigit }),
              Data(base64Encoded: invitation.secret)?.count == 32,
              !invitation.serviceName.isEmpty, invitation.serviceName.utf8.count <= 63 else {
            throw CompanionProtocolError.invalidPairing
        }
        return invitation
    }
}
