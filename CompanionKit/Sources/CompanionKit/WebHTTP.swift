#if os(macOS)
import Foundation
@preconcurrency import Network

/// Deliberately small HTTP/1.1 surface: one request per connection, no proxy,
/// chunked request, upgrade, multipart, filesystem lookup or pipelining.
public struct WebRequest: Sendable {
    /// This listener is for private LANs, not Internet/CGNAT-facing hosting.
    public static func isPrivateAddress(_ data: Data) -> Bool {
        let bytes = Array(data)
        if bytes.count == 4 {
            return bytes[0] == 10 || bytes[0] == 127
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254)
        }
        guard bytes.count == 16 else { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return isPrivateAddress(Data(bytes.suffix(4)))
        }
        return (bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1)
            || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
    }
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public static func parse(_ data: Data) throws -> WebRequest? {
        guard data.count <= 12_288 else { throw WebError("Request too large") }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 8192 { throw WebError("Headers too large") }
            return nil
        }
        guard split.lowerBound <= 8192,
              let text = String(data: data[..<split.lowerBound], encoding: .ascii) else { throw WebError("Invalid headers") }
        let lines = text.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2] == "HTTP/1.1", ["GET", "POST"].contains(start[0]),
              start[1].hasPrefix("/"), !start[1].contains("#") else { throw WebError("Invalid request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw WebError("Invalid header") }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }), headers[name] == nil else { throw WebError("Invalid duplicate/header") }
            headers[name] = value
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil,
              headers["expect"] == nil else { throw WebError("Unsupported request framing") }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(rawLength), length <= 4096 else { throw WebError("Invalid body length") }
        if start[0] == "GET" && length != 0 { throw WebError("Unexpected body") }
        let body = data[split.upperBound...]
        guard body.count <= length else { throw WebError("Pipelining is unsupported") }
        guard body.count == length else { return nil }
        return .init(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body))
    }
}

@MainActor final class WebPeer {
    let id = UUID()
    let connection: NWConnection
    var onRequest: ((WebRequest) -> Void)?
    var onClose: (() -> Void)?
    var streaming = false
    var closed = false
    private var buffer = Data()
    private var deadline: Task<Void, Never>?
    private var writing = false
    private var pending: Data?
    private var writeDeadline: Task<Void, Never>?

    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close()
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.close() }
                if case .cancelled = state { self?.close() }
            }
        }
        connection.start(queue: DispatchQueue(label: "StreamTranslate.web.peer"))
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                guard error == nil else { self.close(); return }
                if let data { self.buffer.append(data) }
                do {
                    if let request = try WebRequest.parse(self.buffer) {
                        self.buffer.removeAll()
                        self.deadline?.cancel()
                        self.onRequest?(request)
                        if self.streaming { self.watchDisconnect() }
                    } else if complete { self.close() }
                    else { self.receive() }
                } catch { self.respond(400, text: "Invalid request") }
            }
        }
    }
    private func watchDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            Task { @MainActor in self?.close() }
        }
    }
    func respond(_ code: Int, text: String, type: String = "text/plain; charset=utf-8", extra: String = "") {
        respond(code, data: Data(text.utf8), type: type, extra: extra)
    }
    func respond(_ code: Int, data: Data, type: String, extra: String = "") {
        send(Data(headers(code, type: type, extra: extra + "Content-Length: \(data.count)\r\nConnection: close\r\n").utf8) + data, final: true)
    }
    func beginStream(_ event: Data) {
        streaming = true
        send(Data(headers(200, type: "text/event-stream", extra: "Connection: close\r\nX-Accel-Buffering: no\r\n").utf8) + event)
    }
    /// Only the latest full snapshot is pending while a socket is slow. No
    /// unbounded transcript queue and no partial delta discarded mid-sequence.
    func event(_ data: Data, fallback: Data? = nil) {
        guard streaming, !closed else { return }
        if writing { pending = fallback ?? data; return }
        send(data)
    }
    func heartbeat() {
        guard !writing, pending == nil else { return }
        event(Data("event: pulse\ndata: {}\n\n".utf8))
    }
    private func send(_ data: Data, final: Bool = false) {
        guard !closed, data.count <= CompanionLimits.maximumFrameBytes + 4096 else { close(); return }
        writing = true
        writeDeadline?.cancel()
        writeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.close()
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.writing = false
                self.writeDeadline?.cancel()
                if error != nil || final { self.close(); return }
                if let next = self.pending { self.pending = nil; self.send(next) }
            }
        })
    }
    func close() {
        guard !closed else { return }
        closed = true
        deadline?.cancel(); writeDeadline?.cancel()
        pending = nil; buffer.removeAll()
        connection.cancel()
        onClose?()
        onClose = nil; onRequest = nil
    }
    private func headers(_ code: Int, type: String, extra: String) -> String {
        "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\nPermissions-Policy: camera=(), microphone=(), geolocation=()\r\n\(extra)\r\n"
    }
}
#endif
