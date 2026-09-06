#if os(macOS)
import Foundation
import Darwin
import SystemConfiguration
import Network

/// Plain HTTP is opt-in at the Mac UI; it is never a TLS failure fallback.
public enum WebTransport: String, Sendable {
    case secure, trustedLAN
    public var port: UInt16 { self == .secure ? 18443 : 18444 }
    public var scheme: String { self == .secure ? "https" : "http" }
    public var cookieName: String { self == .secure ? "__Host-stcaption" : "stcaption_lan" }
    public var authorizationSeconds: Int { self == .secure ? 7_776_000 : 43_200 }
    public var cookieAttributes: String {
        "Path=/; " + (self == .secure ? "Secure; " : "") + "HttpOnly; SameSite=Strict; Max-Age=\(authorizationSeconds)"
    }

    /// Prefer a directly usable LAN IP over mDNS/VPN resolution. No routes,
    /// proxies or firewall settings are changed. IPv6-only LANs use .local.
    public static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        let store = SCDynamicStoreCreate(nil, "StreamTranslate" as CFString, nil, nil)
        let info = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let primary = info?["PrimaryInterface"] as? String
        var candidates: [(name: String, ip: String)] = []
        var entry = list
        while let node = entry {
            defer { entry = node.pointee.ifa_next }
            guard let address = node.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  node.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  node.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: node.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let parsed = IPv4Address(ip), WebRequest.isPrivateAddress(parsed.rawValue) else { continue }
            candidates.append((name, ip))
        }
        return candidates.sorted {
            func rank(_ name: String) -> Int { name == primary ? 0 : name.hasPrefix("en") ? 1 : 2 }
            return rank($0.name) == rank($1.name) ? $0.name < $1.name : rank($0.name) < rank($1.name)
        }.first?.ip
    }
}
#endif
