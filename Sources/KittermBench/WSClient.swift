import Foundation
import KittermProtocol

enum BenchError: Error, LocalizedError {
    case connectFailed(String)
    case timeout(String)
    case closed(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .connectFailed(let m), .timeout(let m), .closed(let m), .unexpected(let m):
            return m
        }
    }
}

/// Minimal binary-protocol client for bench scenarios (URLSession WebSocket).
final class WSClient: @unchecked Sendable {
    private let port: Int
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var outputBuffer = Data()
    private var signal = DispatchSemaphore(value: 0)
    private var _closedReason: String?

    /// Artificial delay before issuing the next WS receive (slow-drain tests).
    var receiveDelayNs: UInt64 = 0

    private(set) var bytesReceived: Int = 0
    private(set) var outputFrames: Int = 0
    private(set) var maxOutputFrameBytes: Int = 0

    var closedReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return _closedReason
    }

    init(port: Int) {
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        self.urlSession = URLSession(configuration: config)
    }

    func connect() async throws {
        let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
        var request = URLRequest(url: url)
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        let task = urlSession.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveNext()

        // Allow meta/title/cwd frames to arrive.
        try await Task.sleep(nanoseconds: 100_000_000)
        if let reason = closedReason {
            throw BenchError.connectFailed(reason)
        }
        if task.state == .completed {
            throw BenchError.connectFailed("websocket closed before ready")
        }
    }

    func close() {
        lock.lock()
        if _closedReason == nil {
            _closedReason = "closed"
        }
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession.invalidateAndCancel()
        signal.signal()
    }

    func send(_ frame: ClientFrame) throws {
        guard let task else { throw BenchError.closed("not connected") }
        let data = frame.encode()
        let semaphore = DispatchSemaphore(value: 0)
        let errorBox = ErrorBox()
        task.send(.data(data)) { error in
            errorBox.error = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            throw BenchError.timeout("send timed out")
        }
        if let sendError = errorBox.error {
            throw sendError
        }
    }

    func sendInput(_ string: String) throws {
        try send(.input(Data(string.utf8)))
    }

    func sendResize(cols: UInt16, rows: UInt16) throws {
        try send(.resize(cols: cols, rows: rows))
    }

    /// Drain until output is quiet for `quietMs`, or `maxMs` elapses.
    func drainQuiet(quietMs: Int = 200, maxMs: Int = 2_500) async {
        let deadline = Date().addingTimeInterval(Double(maxMs) / 1_000)
        var lastCount = bytesReceived
        var quietStart = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let nowCount = bytesReceived
            if nowCount != lastCount {
                lastCount = nowCount
                quietStart = Date()
            } else if Date().timeIntervalSince(quietStart) * 1_000 >= Double(quietMs) {
                return
            }
        }
    }

    func clearOutputBuffer() {
        lock.lock()
        outputBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Block until `needle` appears in the output buffer (consumed through the match).
    @discardableResult
    func waitFor(_ needle: Data, timeoutMs: Int) throws -> Data {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        while Date() < deadline {
            lock.lock()
            if let reason = _closedReason {
                lock.unlock()
                throw BenchError.closed(reason)
            }
            if let range = outputBuffer.range(of: needle) {
                let matched = outputBuffer
                outputBuffer.removeSubrange(outputBuffer.startIndex..<range.upperBound)
                lock.unlock()
                return matched
            }
            lock.unlock()
            _ = signal.wait(timeout: .now() + 0.02)
        }
        throw BenchError.timeout("waitFor \(timeoutMs)ms needle=\(String(data: needle, encoding: .utf8) ?? "?")")
    }

    /// Block until at least `count` total output bytes have been received.
    func waitForBytes(_ count: Int, timeoutMs: Int) throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        while Date() < deadline {
            lock.lock()
            let have = bytesReceived
            let reason = _closedReason
            lock.unlock()
            if have >= count { return }
            if let reason {
                throw BenchError.closed(reason)
            }
            _ = signal.wait(timeout: .now() + 0.05)
        }
        throw BenchError.timeout("waitForBytes \(count) got \(bytesReceived) in \(timeoutMs)ms")
    }

    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lock.lock()
                self._closedReason = error.localizedDescription
                self.lock.unlock()
                self.signal.signal()
                return
            case .success(let message):
                if case .data(let data) = message {
                    self.handleBinary(data)
                }
            }
            let delay = self.receiveDelayNs
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
                    self.receiveNext()
                }
            } else {
                self.receiveNext()
            }
        }
    }

    private func handleBinary(_ data: Data) {
        guard let frame = try? ServerFrame.decode(data) else { return }
        switch frame {
        case .output(let payload):
            lock.lock()
            bytesReceived += payload.count
            outputFrames += 1
            maxOutputFrameBytes = max(maxOutputFrameBytes, payload.count)
            outputBuffer.append(payload)
            // Cap retained buffer for burst scenarios.
            if outputBuffer.count > 2 * 1024 * 1024 {
                outputBuffer.removeFirst(outputBuffer.count - 1024 * 1024)
            }
            lock.unlock()
            signal.signal()
        case .exit(let code):
            lock.lock()
            _closedReason = "shell exited (\(code))"
            lock.unlock()
            signal.signal()
            default:
            break
        }
    }
}

private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
