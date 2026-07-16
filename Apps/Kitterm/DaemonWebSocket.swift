import Foundation
import KittermProtocol

/// Binary WebSocket client for one kitterm PTY session (`tab = shell`).
final class DaemonWebSocket: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case closed
    }

    private let queue = DispatchQueue(label: "kitterm.app.ws")
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveLoopActive = false

    private let lock = NSLock()
    private var _state: State = .idle

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var onStateChange: ((State) -> Void)?
    var onFrame: ((ServerFrame) -> Void)?

    func connect(port: Int) {
        queue.async { [weak self] in
            self?.connectLocked(port: port)
        }
    }

    func send(_ frame: ClientFrame) {
        let data = frame.encode()
        queue.async { [weak self] in
            guard let self, let task = self.task else { return }
            task.send(.data(data)) { [weak self] error in
                if let error {
                    self?.fail("send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func close() {
        queue.async { [weak self] in
            self?.closeLocked()
        }
    }

    private func connectLocked(port: Int) {
        closeLocked(notify: false)
        setState(.connecting)

        let url = DaemonPort.webSocketURL(port: port)
        var request = URLRequest(url: url)
        request.setValue(
            "http://\(KittermConstants.defaultHost):\(port)",
            forHTTPHeaderField: "Origin"
        )
        request.timeoutInterval = 10

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        receiveLoopActive = true
        task.resume()
        setState(.connected)
        receiveNext()
    }

    private func closeLocked(notify: Bool = true) {
        receiveLoopActive = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if notify {
            setState(.closed)
        }
    }

    private func receiveNext() {
        guard receiveLoopActive, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.handleReceive(result)
            }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard receiveLoopActive else { return }
        switch result {
        case .failure(let error):
            fail("receive failed: \(error.localizedDescription)")
        case .success(let message):
            switch message {
            case .data(let data):
                do {
                    let frame = try ServerFrame.decode(data)
                    onFrame?(frame)
                } catch {
                    fail("bad frame: \(error)")
                    return
                }
            case .string(let text):
                fail("unexpected text frame (\(text.prefix(32)))")
                return
            @unknown default:
                break
            }
            receiveNext()
        }
    }

    private func fail(_ reason: String) {
        receiveLoopActive = false
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        setState(.failed(reason))
    }

    private func setState(_ state: State) {
        lock.lock()
        _state = state
        lock.unlock()
        onStateChange?(state)
    }
}
