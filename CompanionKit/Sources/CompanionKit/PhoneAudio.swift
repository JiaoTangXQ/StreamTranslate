import Foundation
import CryptoKit

/// One encrypted upload of phone microphone audio: 16 kHz mono 16-bit PCM in
/// 100 ms frames. The relay only forwards ciphertext; the Mac decrypts with a
/// key derived from the room key the phone received in the pairing QR code.
///
/// Plaintext layout: "STA1" | first frame index (UInt32, big endian) |
/// flags (bit 0: end of stream) | reserved byte | Int16 little-endian samples.
public struct PhoneAudioBatch: Equatable, Sendable {
    public static let sampleRate = 16_000
    public static let frameSamples = 1_600
    public static let maximumSamples = 16_000
    private static let magic = Data("STA1".utf8)

    public let stream: String
    public let sequence: UInt64
    public let firstFrame: UInt32
    public let isEnd: Bool
    public let samples: [Int16]

    public init(stream: String, sequence: UInt64, firstFrame: UInt32, isEnd: Bool, samples: [Int16]) {
        self.stream = stream; self.sequence = sequence; self.firstFrame = firstFrame
        self.isEnd = isEnd; self.samples = samples
    }

    public static func isValidStream(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Separate from the caption key so the two directions never share
    /// (key, nonce) space and a downlink frame cannot pass as audio.
    public static func uplinkKey(room: String, key: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(room.utf8),
                               info: Data("StreamTranslate phone audio v1".utf8), outputByteCount: 32)
    }

    static func associatedData(room: String, stream: String, sequence: UInt64) -> Data {
        Data("\(room):\(stream):\(sequence):audio".utf8)
    }

    public static func open(sealed base64: String, stream: String, sequence: UInt64,
                            room: String, key: SymmetricKey) throws -> PhoneAudioBatch {
        guard isValidStream(stream), sequence > 0, base64.count <= 60_000,
              let combined = Data(base64Encoded: base64), combined.count >= 28 + 10 else {
            throw CompanionProtocolError.invalidFrame
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let clear = try AES.GCM.open(box, using: uplinkKey(room: room, key: key),
                                     authenticating: associatedData(room: room, stream: stream, sequence: sequence))
        guard clear.count >= 10, clear.prefix(4) == magic, (clear.count - 10) % 2 == 0,
              (clear.count - 10) / 2 <= maximumSamples else { throw CompanionProtocolError.invalidFrame }
        let bytes = [UInt8](clear)
        let frame = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        var samples = [Int16](repeating: 0, count: (bytes.count - 10) / 2)
        for index in samples.indices {
            let low = UInt16(bytes[10 + index * 2]), high = UInt16(bytes[11 + index * 2])
            samples[index] = Int16(bitPattern: low | high << 8)
        }
        return PhoneAudioBatch(stream: stream, sequence: sequence, firstFrame: frame,
                               isEnd: bytes[8] & 1 == 1, samples: samples)
    }

    /// The phone's encoding, used by tests and fixtures.
    public func seal(room: String, key: SymmetricKey) throws -> String {
        var clear = Self.magic
        clear.append(contentsOf: [UInt8(firstFrame >> 24), UInt8(firstFrame >> 16 & 255),
                                  UInt8(firstFrame >> 8 & 255), UInt8(firstFrame & 255), isEnd ? 1 : 0, 0])
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            clear.append(contentsOf: [UInt8(value & 255), UInt8(value >> 8)])
        }
        let sealed = try AES.GCM.seal(clear, using: Self.uplinkKey(room: room, key: key),
            authenticating: Self.associatedData(room: room, stream: stream, sequence: sequence))
        guard let combined = sealed.combined else { throw CompanionProtocolError.invalidFrame }
        return combined.base64EncodedString()
    }
}

/// A browser authorized for a remote room. The relay only ever sees the
/// SHA-256 of the cookie; the Mac keeps this list so pairing survives relay
/// and Mac restarts without anyone storing the cookie itself.
public struct RemoteRelayDevice: Codable, Equatable, Sendable {
    public var hash: String
    /// Milliseconds since 1970, as reported by the relay.
    public var expires: Double

    public init(hash: String, expires: Double) { self.hash = hash; self.expires = expires }

    public static func isValidHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The relay's list for an opened room is authoritative. Returns the list
    /// to save, or nil when nothing worth saving changed (an expiry moving by
    /// less than a day is not rewritten on every heartbeat).
    public static func reconciled(saved: [RemoteRelayDevice], reported: [RemoteRelayDevice],
                                  now: Double, limit: Int = 5) -> [RemoteRelayDevice]? {
        let next = reported.filter { isValidHash($0.hash) && $0.expires.isFinite && $0.expires > now }
            .sorted { $0.expires > $1.expires }.prefix(limit).sorted { $0.hash < $1.hash }
        let previous = Dictionary(saved.map { ($0.hash, $0.expires) }, uniquingKeysWith: { max($0, $1) })
        let changed = next.count != previous.count || next.contains { device in
            guard let old = previous[device.hash] else { return true }
            return device.expires - old >= 86_400_000
        }
        return changed ? Array(next) : nil
    }
}
