import Foundation
import CryptoKit
import Security
import Network
#if os(macOS)
import X509
#endif

public enum CompanionSecrets {
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw CompanionProtocolError.keychain(result) }
        return Data(bytes).base64EncodedString()
    }
    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public struct CompanionVault: Sendable {
    private let service: String
    public init(service: String = "com.jiaotangxq.StreamTranslate.companion") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        #if os(macOS)
        // The locally signed Mac app has no provisioned access group. Use its
        // login keychain ACL, not the entitlement-gated data-protection store.
        query[kSecUseDataProtectionKeychain as String] = false
        #endif
        return query
    }
    public func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CompanionProtocolError.keychain(status)
        }
        return try JSONDecoder().decode(type, from: data)
    }
    public func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CompanionProtocolError.keychain(status) }
        var request = query(account)
        request[kSecValueData as String] = data
        #if !os(macOS)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let added = SecItemAdd(request as CFDictionary, nil)
        guard added == errSecSuccess else { throw CompanionProtocolError.keychain(added) }
    }
    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CompanionProtocolError.keychain(status)
        }
    }
}

public struct CompanionTrustedClient: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let credential: String
    public let pairedAt: Date
}

/// Single-use, expiring pairing invitation. The caller must persist a new
/// credential before sending authorization or any caption data.
public struct CompanionAuthorizer: Sendable {
    public private(set) var clients: [CompanionTrustedClient]
    public private(set) var invitation: CompanionInvitation?
    public init(clients: [CompanionTrustedClient] = []) { self.clients = clients }
    public mutating func invite(_ value: CompanionInvitation?) { invitation = value }
    public mutating func revokeAll() { clients = []; invitation = nil }
    public mutating func authorize(_ request: CompanionAuthentication, now: Date = Date()) throws -> CompanionTrustedClient? {
        guard request.version == CompanionLimits.protocolVersion,
              !request.name.isEmpty, request.name.count <= 64 else { return nil }
        if let credential = request.credential,
           let existing = clients.first(where: { $0.id == request.clientID }),
           CompanionSecrets.equal(existing.credential, credential) { return existing }
        guard clients.isEmpty, let current = invitation, current.expiresAt > now,
              let secret = request.invitation,
              CompanionSecrets.equal(secret, current.secret) else { return nil }
        let client = CompanionTrustedClient(id: request.clientID, name: request.name,
                                             credential: try CompanionSecrets.random(), pairedAt: now)
        clients = [client]
        invitation = nil
        return client
    }
}

public enum CompanionTLS {
    public static func client(fingerprint: String, peerToPeer: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let leaf = chain.first else { complete(false); return }
            let actual = CompanionSecrets.fingerprint(SecCertificateCopyData(leaf) as Data)
            // Explicit per-device pin from the QR invitation / saved pairing.
            // TLS proves possession of the corresponding private key.
            complete(CompanionSecrets.equal(actual, fingerprint))
        }, DispatchQueue(label: "StreamTranslate.companion.trust"))
        return parameters(tls: tls, peerToPeer: peerToPeer)
    }
    public static func parameters(tls: NWProtocolTLS.Options, peerToPeer: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = peerToPeer
        return parameters
    }
}

#if os(macOS)
public final class CompanionServerIdentity: @unchecked Sendable {
    private struct Stored: Codable {
        var id: UUID
        var key: Data
        var certificate: Data
    }
    public let id: UUID
    public let fingerprint: String
    private let identity: SecIdentity

    public init(vault: CompanionVault = CompanionVault()) throws {
        let stored: Stored
        if let previous = try vault.read(Stored.self, account: "server-identity-v1") {
            stored = previous
        } else {
            let key = P256.Signing.PrivateKey()
            let id = UUID()
            let name = try DistinguishedName { CommonName("StreamTranslate Companion \(id.uuidString)") }
            let certificate = try Certificate(
                version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
                notValidBefore: Date().addingTimeInterval(-3600),
                notValidAfter: Date().addingTimeInterval(10 * 365 * 24 * 3600),
                issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                }, issuerPrivateKey: .init(key)
            )
            stored = Stored(id: id, key: key.x963Representation,
                            certificate: Data(try certificate.serializeAsPEM().derBytes))
            try vault.save(stored, account: "server-identity-v1")
        }
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(stored.key as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256
        ] as CFDictionary, &keyError),
        let certificate = SecCertificateCreateWithData(nil, stored.certificate as CFData) else {
            throw CompanionProtocolError.unavailableIdentity
        }
        // Public API binds this exact key and certificate in memory. The key
        // remains protected in the vault; do not mix legacy keychain key refs
        // with modern SecKeyCreateWithData references.
        guard let result = SecIdentityCreate(nil, certificate, key) else {
            throw CompanionProtocolError.unavailableIdentity
        }
        id = stored.id
        fingerprint = CompanionSecrets.fingerprint(stored.certificate)
        identity = result
    }

    public func parameters(peerToPeer: Bool) throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        guard let local = sec_identity_create(identity) else { throw CompanionProtocolError.unavailableIdentity }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        return CompanionTLS.parameters(tls: tls, peerToPeer: peerToPeer)
    }
}
#endif
