import Foundation
import KittermProtocol
import NIOPosix
import XCTest

@testable import KittermDaemon

/// A live upgrade end to end (`docs/live-upgrade.md`): a scratch daemon under
/// `KITTERM_STATE_DIR` execs into itself on `POST /api/upgrade/takeover`.
/// The process keeps its pid, the session keeps its shell with `cat` in the
/// foreground, a client that reconnects with `?since=` gets exactly the gap,
/// and the event feed keeps its epoch.
///
/// Runs the built `kitterm` binary beside the test bundle, so this is the
/// real `serve` path, not a handler in-process.
final class LiveTakeoverTests: XCTestCase {
    private var stateDir: URL!
    private var daemon: Process!
    private var port: Int!

    private static var buildDir: URL {
        Bundle(for: LiveTakeoverTests.self).bundleURL.deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-takeover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        port = try Self.freePort()

        let executable = Self.buildDir.appendingPathComponent("kitterm")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "kitterm binary not built beside the test bundle"
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--port", "\(port!)", "--agent-control"]
        var environment = ProcessInfo.processInfo.environment
        environment["KITTERM_STATE_DIR"] = stateDir.path
        environment["SHELL"] = "/bin/sh"
        environment["PATH"] = Self.buildDir.path + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        try process.run()
        daemon = process
        try waitUntilHealthy()
    }

    override func tearDownWithError() throws {
        if let daemon, daemon.isRunning {
            daemon.terminate()
            daemon.waitUntilExit()
        }
        if let stateDir {
            if let log = try? String(contentsOf: stateDir.appendingPathComponent("server.log"), encoding: .utf8),
               log.contains("takeover: exec failed") || log.contains("starting clean") {
                XCTFail("daemon log reports a failed takeover:\n\(log)")
            }
            try? FileManager.default.removeItem(at: stateDir)
        }
    }

    func testExecTakeoverKeepsPidSessionStreamAndEpoch() async throws {
        let pidBefore = daemon.processIdentifier

        // A session with `cat` in the foreground: a program, not the shell,
        // reads the terminal, so its survival is the whole point.
        let spawned = try await request("POST", "/api/sessions", body: #"{"input":"cat\n","name":"crew"}"#)
        XCTAssertEqual(spawned.status, 201, spawned.body)
        let sessionID = try XCTUnwrap(json(spawned.body)["id"] as? String)
        try await waitFor("cat in the foreground") {
            try await self.foregroundProgram(sessionID) == "cat"
        }
        let rowBefore = try json(try await request("GET", "/api/sessions/\(sessionID)").body)
        let shellPid = try XCTUnwrap(rowBefore["pid"] as? Int32)

        // A client watching the session, counting every output byte from
        // stream offset zero, so its count is an absolute offset.
        let client = StreamClient(port: port)
        try await client.connect(session: sessionID, since: 0)
        let before = Data("before-takeover\n".utf8)
        _ = try await request("POST", "/api/sessions/\(sessionID)/input", body: before)
        try await waitFor("cat echoes the first line") {
            client.received.range(of: Data("before-takeover\r\n".utf8)) != nil
        }

        // The feed's cursor and epoch from before the handoff.
        let feed = try json(try await request("GET", "/api/events?since=0").body)
        let epoch = try XCTUnwrap(feed["epoch"] as? String)
        let cursor = try XCTUnwrap(feed["next"] as? Int)

        // The takeover. The daemon answers before it quiesces.
        let takeover = try await request("POST", "/api/upgrade/takeover")
        XCTAssertEqual(takeover.status, 200, takeover.body)
        XCTAssertEqual(try json(takeover.body)["pid"] as? Int32, pidBefore)

        // The successor announces itself inside the same epoch.
        var started: [String: Any] = [:]
        try await waitFor("daemon.started with takeover in the same epoch", timeout: 15) {
            guard let after = try? self.json(try await self.request(
                "GET", "/api/events?since=\(cursor)&epoch=\(epoch)"
            ).body) else { return false }
            XCTAssertEqual(after["epoch"] as? String, epoch)
            XCTAssertEqual(after["pruned"] as? Bool, false)
            let events = after["events"] as? [[String: Any]] ?? []
            guard let hit = events.first(where: { $0["type"] as? String == "daemon.started" }) else { return false }
            started = hit
            return true
        }
        let startedData = try XCTUnwrap(started["data"] as? [String: String])
        XCTAssertEqual(startedData["takeover"], "true")
        XCTAssertEqual(startedData["epoch"], epoch)
        XCTAssertEqual(startedData["pid"], "\(pidBefore)")

        // Same process, same child, same reader in the foreground.
        XCTAssertTrue(daemon.isRunning)
        XCTAssertEqual(daemon.processIdentifier, pidBefore)
        let pidFile = try String(contentsOf: stateDir.appendingPathComponent("pid"), encoding: .utf8)
        XCTAssertEqual(pidFile.trimmingCharacters(in: .whitespacesAndNewlines), "\(pidBefore)")
        XCTAssertEqual(kill(shellPid, 0), 0, "the shell must still be alive")
        let rowAfter = try json(try await request("GET", "/api/sessions/\(sessionID)").body)
        XCTAssertEqual(rowAfter["pid"] as? Int32, shellPid)
        XCTAssertEqual(rowAfter["name"] as? String, "crew")
        XCTAssertEqual(rowAfter["foregroundProgram"] as? String, "cat")
        XCTAssertEqual(rowAfter["attached"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("takeover").path))

        // The client lost its socket. It reconnects with what it counted and
        // must get exactly the gap: no resync, offset equal to its count.
        try await waitFor("client socket closed by the handoff") { client.closed }
        let counted = UInt64(client.received.count)
        try await client.connect(session: sessionID, since: counted)
        try await waitFor("logState frame on reconnect") { client.logState != nil }
        let logState = try XCTUnwrap(client.logState)
        XCTAssertFalse(logState.resync)
        XCTAssertEqual(logState.offset, counted)

        // Typing continues into the same `cat`.
        _ = try await request("POST", "/api/sessions/\(sessionID)/input", body: Data("after-takeover\n".utf8))
        try await waitFor("cat echoes the second line") {
            client.received.range(of: Data("after-takeover\r\n".utf8)) != nil
        }

        // The stream the client assembled across the boundary is byte for
        // byte the ring the daemon holds, from offset zero.
        let output = try await requestRaw("GET", "/api/sessions/\(sessionID)/output?tail=\(256 * 1024)")
        XCTAssertEqual(output.headers["X-Kitterm-Start"], "0")
        XCTAssertEqual(output.headers["X-Kitterm-Head"], "\(client.received.count)")
        XCTAssertEqual(
            output.body, client.received,
            "ring: \(String(decoding: output.body, as: UTF8.self).debugDescription)\nclient: \(String(decoding: client.received, as: UTF8.self).debugDescription)"
        )
        client.close()
    }

    /// A takeover that arrives while another is already admitted is refused.
    ///
    /// This was two `POST /api/upgrade/takeover` requests raced from a task
    /// group, asserting the statuses sorted to `[200, 409]`. Two requests
    /// started together are not two requests in flight together: on a loaded
    /// runner the first finishes its handoff before the second arrives and
    /// nothing refuses it, which is why CI saw this fail while a developer
    /// machine did not. The refusal is a decision `TakeoverController` makes,
    /// so it is proved here at that level, with no timing at all. The route's
    /// mapping of `.inProgress` to 409 is a `switch` in `serveTakeover`, and
    /// the accepted path is covered end to end by the test above.
    func testSecondTakeoverWhileOneIsAdmittedIsRefused() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let controller = TakeoverController(executable: "/bin/echo") { _ in }

        let first = try await controller.admit(on: loop).get()
        guard case .accepted = first else {
            return XCTFail("the first takeover should be admitted, got \(first)")
        }
        let second = try await controller.admit(on: loop).get()
        XCTAssertEqual(second, .inProgress)

        // And every later one, however many arrive.
        let third = try await controller.admit(on: loop).get()
        XCTAssertEqual(third, .inProgress)

        try await group.shutdownGracefully()
    }

    // MARK: - Helpers

    private func foregroundProgram(_ id: String) async throws -> String? {
        try json(try await request("GET", "/api/sessions/\(id)").body)["foregroundProgram"] as? String
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
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/api/health")!)
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
        XCTFail("daemon on port \(port!) never became healthy")
        throw CancellationError()
    }

    private func request(
        _ method: String, _ path: String, body: String
    ) async throws -> (status: Int, body: String) {
        try await request(method, path, body: Data(body.utf8))
    }

    private func request(
        _ method: String, _ path: String, body: Data? = nil
    ) async throws -> (status: Int, body: String) {
        let raw = try await requestRaw(method, path, body: body)
        return (raw.status, String(decoding: raw.body, as: UTF8.self))
    }

    private func requestRaw(
        _ method: String, _ path: String, body: Data? = nil
    ) async throws -> (status: Int, body: Data, headers: [String: String]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers["\(key)"] = "\(value)"
        }
        return (http?.statusCode ?? 0, data, headers)
    }

    private func json(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any], body)
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
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

/// A controller over the binary WebSocket protocol that keeps every output
/// byte it receives, so a reconnect can name its offset and the assembled
/// stream can be compared with the daemon's ring.
private final class StreamClient: @unchecked Sendable {
    private let port: Int
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var buffer = Data()
    private var closedFlag = false
    private var lastLogState: (resync: Bool, offset: UInt64, replayLen: UInt64)?

    init(port: Int) {
        self.port = port
    }

    var received: Data { lock.withLock { buffer } }
    var closed: Bool { lock.withLock { closedFlag } }
    var logState: (resync: Bool, offset: UInt64, replayLen: UInt64)? { lock.withLock { lastLogState } }

    func connect(session id: String, since: UInt64?) async throws {
        lock.withLock {
            closedFlag = false
            lastLogState = nil
        }
        var url = "ws://127.0.0.1:\(port)/ws?session=\(id)"
        if let since { url += "&since=\(since)" }
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receiveNext(task)
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.lock.withLock { self.closedFlag = true }
            case .success(let message):
                if case .data(let data) = message, let frame = try? ServerFrame.decode(data) {
                    self.lock.withLock {
                        switch frame {
                        case .output(let bytes): self.buffer.append(bytes)
                        case .logState(let resync, let offset, let replayLen):
                            self.lastLogState = (resync, offset, replayLen)
                        default: break
                        }
                    }
                }
                self.receiveNext(task)
            }
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }
}
