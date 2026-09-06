import Foundation
import Testing
import CompanionKit
import Network
@testable import StreamTranslate

@Test func webListenerOnlyAcceptsPrivateLANAddresses() {
    for ip in ["127.0.0.1", "10.2.3.4", "192.168.5.6", "172.16.0.1", "169.254.1.2"] {
        #expect(WebRequest.isPrivateAddress(IPv4Address(ip)!.rawValue))
    }
    for ip in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.1.2", "100.64.0.1"] {
        #expect(!WebRequest.isPrivateAddress(IPv4Address(ip)!.rawValue))
    }
    for ip in ["::1", "fe80::1", "fd12::1", "::ffff:192.168.1.2"] {
        #expect(WebRequest.isPrivateAddress(IPv6Address(ip)!.rawValue))
    }
    #expect(!WebRequest.isPrivateAddress(IPv6Address("2606:4700:4700::1111")!.rawValue))
}

@Test func webHTTPRequestWaitsForCompleteBody() throws {
    let head = "POST /api/pair HTTP/1.1\r\nHost: test.local:18443\r\nContent-Length: 2\r\n\r\n"
    #expect(try WebRequest.parse(Data((head + "{").utf8)) == nil)
    let request = try WebRequest.parse(Data((head + "{}").utf8))
    #expect(request?.method == "POST")
    #expect(request?.path == "/api/pair")
    #expect(request?.body == Data("{}".utf8))
}

@Test func webHTTPRejectsAmbiguousRequests() {
    let invalid = [
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\n\r\nGET / HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5000\r\n\r\n",
        "GET / HTTP/1.1\r\n Host: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\nInjected: yes\r\n\r\n",
        String(repeating: "A", count: 8193)
    ]
    for text in invalid {
        do { _ = try WebRequest.parse(Data(text.utf8)); Issue.record("Accepted ambiguous HTTP request") }
        catch { }
    }
}

@Test @MainActor func webServiceDefaultsOffAndPersistsSeparately() {
    let suite = "StreamTranslate.web-settings-test.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = CaptionSettings(defaults: defaults)
    #expect(!settings.webCompanionEnabled)
    #expect(!settings.webQuickConnection)
    settings.webCompanionEnabled = true
    let restored = CaptionSettings(defaults: defaults)
    #expect(restored.webCompanionEnabled)
    #expect(!restored.companionEnabled)
    #expect(!restored.phoneOnlyDisplay)
    #expect(!restored.webQuickConnection)
    settings.webQuickConnection = true
    #expect(CaptionSettings(defaults: defaults).webQuickConnection)
}

@Test func webTransportsHaveSeparateCredentialsAndExplicitSecurity() {
    #expect(WebTransport.secure.port != WebTransport.trustedLAN.port)
    #expect(WebTransport.secure.cookieName.hasPrefix("__Host-"))
    #expect(WebTransport.secure.cookieName != WebTransport.trustedLAN.cookieName)
    #expect(WebTransport.secure.cookieAttributes.contains("Secure;"))
    #expect(!WebTransport.trustedLAN.cookieAttributes.contains("Secure;"))
    #expect(WebTransport.trustedLAN.cookieAttributes.contains("HttpOnly; SameSite=Strict"))
    #expect(WebTransport.trustedLAN.authorizationSeconds == 43200)
}
