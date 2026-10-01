import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// A pane that reconnects with `?session=<gone id>&since=<old offset>` gets a
/// new shell, and its offset names the dead stream. The daemon must replay
/// the new shell from byte 0 and send `logState` with resync. Before the fix
/// the daemon honoured the stale offset: when the offset was at or below the
/// new shell's byte count, `SessionLog.snapshot(from:)` did not report it
/// pruned, the client kept its old screen, and a slice from the middle of the
/// new stream landed on it.
///
/// Runs the built `kitterm` binary beside the test bundle under a scratch
/// `KITTERM_STATE_DIR`, so the restart is a real one.
final class RespawnResyncTests: XCTestCase {
    private var stateDir: URL!
    private var daemon: Process?
    private var port = 0

    private static var buildDir: URL {
        Bundle(for: RespawnResyncTests.self).bundleURL.deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-respawn-resync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try startDaemon()
    }

    override func tearDownWithError() throws {
        stopDaemon()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    /// Offset 0 is at or below every byte count, so this case does not depend
    /// on how much the new shell printed before the handler attached.
    func testAGoneSessionAtOffsetZeroGetsAResync() async throws {
        let gone = UUID().uuidString
        let pane = PaneClient(port: port)
        defer { pane.close() }
        pane.connect(session: gone, since: 0)
        try await waitFor("logState for the new shell") { pane.logState != nil }

        let logState = try XCTUnwrap(pane.logState)
        XCTAssertNotEqual(pane.sessionID, gone, "the gone id gets a new shell")
        XCTAssertTrue(logState.resync, "a shell that replaced a requested session resets the screen")
        XCTAssertEqual(logState.offset, 0)
    }

    /// The reported case: `kitterm restart` with a pane open. The pane's
    /// count is small, the new shell prints its `Last login:` line and its
    /// prompt, and the count names a byte in the middle of them.
    func testARestartRespawnReplaysTheNewShellFromItsStart() async throws {
        let before = PaneClient(port: port)
        before.connect(session: nil, since: nil)
        try await waitFor("the first shell's prompt") { !before.received.isEmpty }
        let oldID = try XCTUnwrap(before.sessionID)
        let counted = UInt64(before.received.count)
        before.close()

        stopDaemon()
        try startDaemon()

        let pane = PaneClient(port: port)
        defer { pane.close() }
        pane.connect(session: oldID, since: counted)
        try await waitFor("logState after the restart") { pane.logState != nil }
        let logState = try XCTUnwrap(pane.logState)
        let newID = try XCTUnwrap(pane.sessionID)
        XCTAssertNotEqual(newID, oldID, "the restart ended the old shell")
        XCTAssertTrue(logState.resync, "the old screen must be reset, since=\(counted)")
        XCTAssertEqual(logState.offset, 0, "the replay starts at the new shell's first byte")

        // The pane's stream is the new shell's ring from byte 0. The ring
        // leads the socket, so compare at a quiet point: after the command's
        // own output, when the two already agree.
        pane.send(Data("echo respawn-marker\n".utf8))
        var ring: (status: Int, body: Data, headers: [String: String]) = (0, Data(), [:])
        try? await waitFor("the pane's stream to equal the ring", timeout: 5) {
            ring = try await self.requestRaw("/api/sessions/\(newID)/output?tail=\(256 * 1024)")
            return pane.received.range(of: Data("respawn-marker\r\n".utf8)) != nil
                && ring.body == pane.received
        }
        XCTAssertEqual(ring.status, 200)
        XCTAssertEqual(ring.headers["X-Kitterm-Start"], "0")
        XCTAssertEqual(
            ring.body, pane.received,
            "ring: \(String(decoding: ring.body, as: UTF8.self).debugDescription)\n"
                + "pane: \(String(decoding: pane.received, as: UTF8.self).debugDescription)"
        )
    }

    /// The unchanged path: the session is alive, so the offset is the pane's
    /// own and the daemon replays exactly the gap, with no resync.
    func testALiveReattachStillGetsTheExactGap() async throws {
        let pane = PaneClient(port: port)
        defer { pane.close() }
        pane.connect(session: nil, since: nil)
        try await waitFor("the shell's prompt") { !pane.received.isEmpty }
        let id = try XCTUnwrap(pane.sessionID)
        pane.send(Data("echo before-drop\n".utf8))
        try await waitFor("the command's output") {
            pane.received.range(of: Data("before-drop\r\n".utf8)) != nil
        }

        pane.close()
        try await waitFor("the session to detach") {
            let row = try await self.requestRaw("/api/sessions/\(id)")
            let json = try JSONSerialization.jsonObject(with: row.body) as? [String: Any]
            return json?["attached"] as? Bool == false
        }
        // The pane names what it counted. The next prompt may have missed the
        // closed socket; that gap is what the daemon replays.
        let counted = UInt64(pane.received.count)
        pane.connect(session: id, since: counted)
        try await waitFor("logState on the reattach") { pane.logState != nil }

        let logState = try XCTUnwrap(pane.logState)
        XCTAssertEqual(pane.sessionID, id, "the same shell")
        XCTAssertFalse(logState.resync)
        XCTAssertEqual(logState.offset, counted)
    }

    // MARK: - Helpers

    private func startDaemon() throws {
        let executable = Self.buildDir.appendingPathComponent("kitterm")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "kitterm binary not built beside the test bundle"
        )
        port = try Self.freePort()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--port", "\(port)"]
        var environment = ProcessInfo.processInfo.environment
        environment["KITTERM_STATE_DIR"] = stateDir.path
        environment["SHELL"] = "/bin/sh"
        environment["PATH"] = Self.buildDir.path + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        try process.run()
        daemon = process
        try waitUntilHealthy()
    }

    /// Stop the daemon the way `kitterm stop` does, so its shells are reaped.
    private func stopDaemon() {
        guard let daemon, daemon.isRunning else { return }
        daemon.terminate()
        waitForExit(of: daemon)
    }

    private func waitFor(
        _ what: String,
        timeout: TimeInterval = 10,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await condition()) == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }

    private func waitUntilHealthy() throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/health")!)
            request.timeoutInterval = 1
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ok = false
            URLSession.shared.dataTask(with: request) { _, response, _ in
                ok = (response as? HTTPURLResponse)?.statusCode == 200
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 1.5)
            if ok { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("daemon on port \(port) never became healthy")
        throw CancellationError()
    }

    private func requestRaw(
        _ path: String
    ) async throws -> (status: Int, body: Data, headers: [String: String]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers["\(key)"] = "\(value)"
        }
        return (http?.statusCode ?? 0, data, headers)
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, streamSocketType, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw CancellationError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw CancellationError() }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// A pane over the binary WebSocket protocol: it keeps the session id, the
/// first `logState` of each connection, and every output byte of the current
/// connection, which is what a pane holds after a resync from offset 0.
private final class PaneClient: @unchecked Sendable {
    private let port: Int
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var buffer = Data()
    private var id: String?
    private var firstLogState: (resync: Bool, offset: UInt64, replayLen: UInt64)?

    init(port: Int) {
        self.port = port
    }

    var received: Data { lock.withLock { buffer } }
    var sessionID: String? { lock.withLock { id } }
    var logState: (resync: Bool, offset: UInt64, replayLen: UInt64)? { lock.withLock { firstLogState } }

    /// Opens a connection. A nil `session` is a new tab. The output of an
    /// earlier connection stays in `received`, as a pane's count does.
    func connect(session id: String?, since: UInt64?) {
        lock.withLock {
            self.id = nil
            firstLogState = nil
        }
        var query: [String] = []
        if let id { query.append("session=\(id)") }
        if let since { query.append("since=\(since)") }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws\(suffix)")!)
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receiveNext(task)
    }

    func send(_ input: Data) {
        task?.send(.data(ClientFrame.input(input).encode())) { _ in }
    }

    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, case .success(let message) = result else { return }
            if case .data(let data) = message, let frame = try? ServerFrame.decode(data) {
                self.lock.withLock {
                    switch frame {
                    case .output(let bytes):
                        self.buffer.append(bytes)
                    case .sessionId(let id):
                        self.id = id
                    case .logState(let resync, let offset, let replayLen):
                        if self.firstLogState == nil {
                            self.firstLogState = (resync, offset, replayLen)
                        }
                        // A resync resets the screen: the pane then holds
                        // only what this connection replays and streams.
                        if resync { self.buffer = Data() }
                    default:
                        break
                    }
                }
            }
            self.receiveNext(task)
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }
}
