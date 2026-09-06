#if os(macOS)
import Foundation
import CryptoKit
import Security
import Network
import X509

/// A dedicated, one-year local HTTPS identity. The CA signing key is never
/// persisted: after issuing this one leaf it is discarded. Export is public
/// certificate material only, never a key or an authentication credential.
public final class WebIdentity: @unchecked Sendable {
    private struct Stored: Codable {
        var host: String
        var id: UUID
        var key: Data
        var leaf: Data
        var root: Data
        var expires: Date
    }
    private let stored: Stored
    private let identity: SecIdentity
    private let root: SecCertificate
    public var hostname: String { stored.host }
    public var expires: Date { stored.expires }
    public var fingerprint: String { CompanionSecrets.fingerprint(stored.root) }
    public var rootDER: Data { stored.root }

    public init(hostname: String, vault: CompanionVault) throws {
        guard hostname.hasSuffix(".local"), hostname.utf8.count <= 253,
              hostname.utf8.allSatisfy({ (45...46).contains($0) || (48...57).contains($0) || (97...122).contains($0) }) else {
            throw WebError("无法确定有效的本机 .local 地址，请检查系统的本地主机名。")
        }
        if let existing = try vault.read(Stored.self, account: "web-identity-v1") {
            guard existing.host == hostname else {
                throw WebError("电脑名称已更改。请恢复原本地主机名 \(existing.host)，或重置网页证书后重新安装。")
            }
            guard existing.expires > .now else { throw WebError("网页证书已到期，请重置证书并在手机上重新安装。") }
            stored = existing
        } else {
            let id = UUID(), caKey = P256.Signing.PrivateKey(), leafKey = P256.Signing.PrivateKey()
            let start = Date().addingTimeInterval(-300), end = Date().addingTimeInterval(365 * 86400)
            let caName = try DistinguishedName { CommonName("StreamTranslate Local \(id.uuidString.prefix(8))") }
            let root = try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(caKey.publicKey),
                notValidBefore: start, notValidAfter: end, issuer: caName, subject: caName,
                signatureAlgorithm: .ecdsaWithSHA256, extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                    Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                    Critical(NameConstraints(permittedDNSDomains: [hostname]))
                }, issuerPrivateKey: .init(caKey))
            let leaf = try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey),
                notValidBefore: start, notValidAfter: end, issuer: caName,
                subject: try DistinguishedName { CommonName(hostname) }, signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    Critical(KeyUsage(digitalSignature: true))
                    try ExtendedKeyUsage([.serverAuth])
                    SubjectAlternativeNames([.dnsName(hostname)])
                }, issuerPrivateKey: .init(caKey))
            stored = Stored(host: hostname, id: id, key: leafKey.x963Representation,
                leaf: Data(try leaf.serializeAsPEM().derBytes), root: Data(try root.serializeAsPEM().derBytes), expires: end)
            try vault.save(stored, account: "web-identity-v1")
        }
        guard let key = SecKeyCreateWithData(stored.key as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256] as CFDictionary, nil),
              let leaf = SecCertificateCreateWithData(nil, stored.leaf as CFData),
              let root = SecCertificateCreateWithData(nil, stored.root as CFData),
              let identity = SecIdentityCreate(nil, leaf, key) else { throw WebError("无法创建网页 TLS 身份。") }
        self.identity = identity
        self.root = root
    }

    public func parameters() throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        guard let local = sec_identity_create_with_certificates(identity, [root] as CFArray) else {
            throw WebError("无法设置网页证书链。")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        return CompanionTLS.parameters(tls: tls, peerToPeer: false)
    }

    public func profile() throws -> Data {
        let identifier = "com.jiaotangxq.StreamTranslate.web.\(stored.id.uuidString)"
        return try PropertyListSerialization.data(fromPropertyList: [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": identifier, "PayloadUUID": stored.id.uuidString,
            "PayloadDisplayName": "StreamTranslate 私密字幕（\(hostname)）",
            "PayloadDescription": "仅含本机字幕 HTTPS 公共证书，无设备管理、VPN、私钥或字幕。有效期一年。不再使用时可删除此描述文件。",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [["PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                "PayloadIdentifier": identifier + ".root", "PayloadUUID": UUID().uuidString,
                "PayloadDisplayName": "StreamTranslate Local \(stored.id.uuidString.prefix(8))",
                "PayloadCertificateFileName": "StreamTranslate-local.cer", "PayloadContent": stored.root]]
        ], format: .xml, options: 0)
    }
}

public struct WebError: LocalizedError, Sendable {
    public var errorDescription: String?
    public init(_ text: String) { errorDescription = text }
}
#endif
