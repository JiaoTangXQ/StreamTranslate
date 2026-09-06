import Foundation
@preconcurrency import Network

/// Main-actor ownership, bounded buffers, a single send in flight. Slow readers
/// are disconnected instead of making the ASR producer wait or accumulating text.
@MainActor
final class CompanionConnection {
    let id = UUID()
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((CompanionMessage) -> Void)?
    var onClose: ((String) -> Void)?
    private var decoder = CompanionFrameDecoder()
    private var pending: [Data] = []
    private var queuedBytes = 0
    private var sending = false
    private var closed = false
    private var closeWhenDrained: String?
    private var deadline: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var lastReceived = ContinuousClock.now
    private var pingNumber: UInt64 = 0

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close("连接或认证超时")
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.receive()
                    self.onReady?()
                case .failed:
                    self.close("安全连接失败，请检查网络和配对身份")
                case .cancelled:
                    self.close("连接已关闭")
                default: break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "StreamTranslate.companion.connection"))
    }

    func authenticated() {
        deadline?.cancel()
        deadline = nil
        lastReceived = .now
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, !self.closed else { return }
                if self.lastReceived.duration(to: .now) > .seconds(15) {
                    self.close("连接无响应，正在恢复")
                    return
                }
                self.pingNumber &+= 1
                self.send(.ping(self.pingNumber))
            }
        }
    }

    @discardableResult func send(_ message: CompanionMessage) -> Bool {
        guard !closed, let bytes = try? CompanionFrameDecoder.encode(message),
              pending.count < 8, queuedBytes + bytes.count <= 2 * CompanionLimits.maximumFrameBytes else {
            close("接收速度不足或数据超过限制，正在重新同步")
            return false
        }
        pending.append(bytes)
        queuedBytes += bytes.count
        drain()
        return true
    }

    func reject(_ reason: String) {
        guard !closed else { return }
        closeWhenDrained = reason
        send(.rejected(reason))
    }

    private func drain() {
        guard !closed, !sending, !pending.isEmpty else { return }
        sending = true
        let data = pending.removeFirst()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.queuedBytes -= data.count
                self.sending = false
                if error != nil { self.close("发送失败，正在恢复"); return }
                if self.pending.isEmpty, let reason = self.closeWhenDrained {
                    self.close(reason)
                    return
                }
                self.drain()
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let content, !content.isEmpty {
                    do {
                        for message in try self.decoder.append(content) {
                            guard !self.closed else { return }
                            self.lastReceived = .now
                            self.onMessage?(message)
                        }
                    } catch { self.close("字幕协议无效"); return }
                }
                if complete || error != nil { self.close("连接中断，正在恢复"); return }
                self.receive()
            }
        }
    }

    func close(_ reason: String = "连接已关闭") {
        guard !closed else { return }
        closed = true
        deadline?.cancel()
        heartbeat?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.removeAll()
        queuedBytes = 0
        onClose?(reason)
        onReady = nil
        onMessage = nil
        onClose = nil
    }
}
