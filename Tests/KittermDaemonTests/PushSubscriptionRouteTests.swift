import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `POST` and `DELETE /api/push/subscriptions`: the grades, the duplicate
/// endpoint, the removal, and the one property the routes exist for — a
/// subscription the daemon stored is still known after the daemon that
/// stored it is gone.
///
/// The grade cases run against a `.proxied` policy over a raw socket that
/// names the trusted host, because loopback is full grade unconditionally
/// and only a request naming a trusted host lets a token decide; URLSession
/// will not set `Host`. The persistence cases run a real `kitterm serve`
/// under `KITTERM_STATE_DIR`, stopped and started again, and upgraded in
/// place, the way `PreviousRunReportTests` and `LiveTakeoverTests` do.
final class PushSubscriptionRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var stateDir: URL!
    private var store: PushSubscriptionStore!
    private var port: Int!

    private static var buildDir: URL {
        Bundle(for: PushSubscriptionRouteTests.self).bundleURL.deletingLastPathComponent()
    }

    private static let p256dh = "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM"
    private static let auth = "tBHItJI5svbpez7KI4CCXg"
    private static let endpoint = "https://fcm.googleapis.com/fcm/send/phone-1"
    private static let full = String(repeating: "f", count: 32)
    private static let watch = "ktw_" + String(repeating: "e", count: 32)
    private static let trustedHost = "box.example.test"

    override class func setUp() {
        super.setUp()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-push-routes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        store = PushSubscriptionStore(file: pushFile)
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channel = try makeServer(store: store)
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        try? channel.close().wait()
        try? await group.shutdownGracefully()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private var pushFile: URL { stateDir.appendingPathComponent("push.json") }

    private func makeServer(store: PushSubscriptionStore?, policy: AccessPolicy = .loopbackOnly) throws -> Channel {
        try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: SessionRegistry(),
                            policy: policy,
                            // Off on purpose: registering a phone is a
                            // person's act, not a program driving a shell.
                            agentControl: false,
                            staticRoot: nil,
                            pushSubscriptions: store
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    /// The body a page sends: `JSON.stringify(await pushManager.subscribe(…))`.
    private static func browserBody(endpoint: String = endpoint, auth: String = auth) -> String {
        #"{"endpoint":"\#(endpoint)","expirationTime":null,"keys":{"p256dh":"\#(p256dh)","auth":"\#(auth)"}}"#
    }

    // MARK: - Store, once per endpoint, and forget

    func testAPostStoresTheSubscriptionOwnerOnly() async throws {
        let answer = try await request("POST", port: port, "/api/push/subscriptions", body: Self.browserBody())
        XCTAssertEqual(answer.status, 201, answer.body)
        let json = try self.json(answer.body)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["created"] as? Bool, true)
        XCTAssertEqual(json["count"] as? Int, 1)

        XCTAssertEqual(store.all.map(\.endpoint), [Self.endpoint])
        XCTAssertEqual(store.all.first?.p256dh, Self.p256dh)
        XCTAssertEqual(store.all.first?.auth, Self.auth)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: pushFile.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    /// The page posts on every load. The second post is an update, not an
    /// error and not a second entry, and the later keys are the ones kept.
    func testTheSameEndpointTwiceIsOneEntryWithTheLaterKeys() async throws {
        let first = try await request("POST", port: port, "/api/push/subscriptions", body: Self.browserBody())
        XCTAssertEqual(first.status, 201, first.body)
        let second = try await request(
            "POST", port: port, "/api/push/subscriptions", body: Self.browserBody(auth: "rotated_rotated_rotate")
        )
        XCTAssertEqual(second.status, 200, second.body)
        XCTAssertEqual(try json(second.body)["created"] as? Bool, false)
        XCTAssertEqual(try json(second.body)["count"] as? Int, 1)

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.all.first?.auth, "rotated_rotated_rotate")
        XCTAssertEqual(PushSubscriptionStore(file: pushFile).count, 1, "the file agrees")
    }

    func testADeleteForgetsItAndASecondDeleteIs404() async throws {
        _ = try await request("POST", port: port, "/api/push/subscriptions", body: Self.browserBody())
        _ = try await request(
            "POST", port: port, "/api/push/subscriptions", body: Self.browserBody(endpoint: "https://push.example/other")
        )

        let removed = try await request(
            "DELETE", port: port, "/api/push/subscriptions", body: #"{"endpoint":"\#(Self.endpoint)"}"#
        )
        XCTAssertEqual(removed.status, 200, removed.body)
        XCTAssertEqual(try json(removed.body)["count"] as? Int, 1)
        XCTAssertEqual(store.all.map(\.endpoint), ["https://push.example/other"], "only the named one goes")
        XCTAssertEqual(PushSubscriptionStore(file: pushFile).all.map(\.endpoint), ["https://push.example/other"])

        let again = try await request(
            "DELETE", port: port, "/api/push/subscriptions", body: #"{"endpoint":"\#(Self.endpoint)"}"#
        )
        XCTAssertEqual(again.status, 404, again.body)
    }

    func testAMalformedBodyIs400AndStoresNothing() async throws {
        for body in [
            "not json",
            #"{"endpoint":"http://push.example/plain","keys":{"p256dh":"\#(Self.p256dh)","auth":"\#(Self.auth)"}}"#,
            #"{"endpoint":"\#(Self.endpoint)"}"#,
            #"{"endpoint":"\#(Self.endpoint)","keys":{"p256dh":"\#(Self.p256dh)","auth":"not base64url!"}}"#,
        ] {
            let answer = try await request("POST", port: port, "/api/push/subscriptions", body: body)
            XCTAssertEqual(answer.status, 400, "\(body) → \(answer.body)")
            XCTAssertEqual(try json(answer.body)["ok"] as? Bool, false)
        }
        let delete = try await request("DELETE", port: port, "/api/push/subscriptions", body: #"{"nope":1}"#)
        XCTAssertEqual(delete.status, 400, delete.body)
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pushFile.path), "nothing valid, nothing written")
    }

    func testAHandlerWithNoStoreAnswers503() async throws {
        try? channel.close().wait()
        channel = try makeServer(store: nil)
        port = channel.localAddress?.port
        let answer = try await request("POST", port: port, "/api/push/subscriptions", body: Self.browserBody())
        XCTAssertEqual(answer.status, 503, answer.body)
    }

    // MARK: - The grades

    /// A watch token exists to withhold the answer, so it does not get the
    /// question either (`goal.md`, exclusions).
    func testAWatchTokenIs403OnBothMethods() throws {
        try useProxiedServer()

        let post = try raw("POST", "/api/push/subscriptions?token=\(Self.watch)", body: Self.browserBody())
        XCTAssertEqual(post.status, 403, post.body)
        XCTAssertTrue(post.body.contains("watch-only"), post.body)

        let delete = try raw("DELETE", "/api/push/subscriptions?token=\(Self.watch)", body: #"{"endpoint":"\#(Self.endpoint)"}"#)
        XCTAssertEqual(delete.status, 403, delete.body)
        XCTAssertEqual(store.count, 0)
    }

    /// The same requests with the full token reach the store, which proves
    /// the 403 above is about the grade and not about the route.
    func testAFullTokenThroughTheProxyPassesTheGrade() throws {
        try useProxiedServer()

        let post = try raw("POST", "/api/push/subscriptions?token=\(Self.full)", body: Self.browserBody())
        XCTAssertEqual(post.status, 201, post.body)
        XCTAssertEqual(store.count, 1)

        let delete = try raw("DELETE", "/api/push/subscriptions?token=\(Self.full)", body: #"{"endpoint":"\#(Self.endpoint)"}"#)
        XCTAssertEqual(delete.status, 200, delete.body)
        XCTAssertEqual(store.count, 0)
    }

    /// No token at all through the proxy is the plain 403 every route gives.
    func testNoTokenThroughTheProxyIs403() throws {
        try useProxiedServer()
        let post = try raw("POST", "/api/push/subscriptions", body: Self.browserBody())
        XCTAssertEqual(post.status, 403, post.body)
        XCTAssertEqual(store.count, 0)
    }

    // MARK: - Proved with real processes

    /// A restart closes every shell but not the phone's subscription: the
    /// origin did not change. The second run must know the endpoint the
    /// first one stored — the re-post reads as an update and the delete
    /// finds it.
    func testASubscriptionSurvivesARestartOnTheSameStateDirectory() async throws {
        let first = try startDaemon()
        defer { stop(first) }
        try await waitFor("the first run to be healthy") { await self.isHealthy(port: first.port) }
        let stored = try await request("POST", port: first.port, "/api/push/subscriptions", body: Self.browserBody())
        XCTAssertEqual(stored.status, 201, stored.body)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: pushFile.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(mode & 0o777, 0o600)

        XCTAssertEqual(kill(first.pid, SIGTERM), 0)
        first.process.waitUntilExit()

        let second = try startDaemon()
        defer { stop(second) }
        try await waitFor("the second run to be healthy") { await self.isHealthy(port: second.port) }

        let rePosted = try await request("POST", port: second.port, "/api/push/subscriptions", body: Self.browserBody())
        XCTAssertEqual(rePosted.status, 200, rePosted.body)
        XCTAssertEqual(try json(rePosted.body)["created"] as? Bool, false, "the second run already had it")
        XCTAssertEqual(try json(rePosted.body)["count"] as? Int, 1)

        let removed = try await request(
            "DELETE", port: second.port, "/api/push/subscriptions", body: #"{"endpoint":"\#(Self.endpoint)"}"#
        )
        XCTAssertEqual(removed.status, 200, removed.body)
        XCTAssertEqual(PushSubscriptionStore(file: pushFile).count, 0)
    }

    /// A live upgrade keeps the pid and the shells; the successor builds its
    /// store from the same file and must know the endpoint too.
    func testASubscriptionSurvivesALiveUpgrade() async throws {
        let daemon = try startDaemon()
        defer { stop(daemon) }
        try await waitFor("the run to be healthy") { await self.isHealthy(port: daemon.port) }
        let stored = try await request("POST", port: daemon.port, "/api/push/subscriptions", body: Self.browserBody())
        XCTAssertEqual(stored.status, 201, stored.body)

        let feed = try json(try await request("GET", port: daemon.port, "/api/events?since=0").body)
        let epoch = try XCTUnwrap(feed["epoch"] as? String)
        let cursor = try XCTUnwrap(feed["next"] as? Int)
        let takeover = try await request("POST", port: daemon.port, "/api/upgrade/takeover")
        XCTAssertEqual(takeover.status, 200, takeover.body)
        try await waitFor("daemon.started with takeover in the same epoch", timeout: 20) {
            guard let after = try? self.json(try await self.request(
                "GET", port: daemon.port, "/api/events?since=\(cursor)&epoch=\(epoch)"
            ).body) else { return false }
            let events = after["events"] as? [[String: Any]] ?? []
            return events.contains { event in
                event["type"] as? String == "daemon.started"
                    && (event["data"] as? [String: String])?["takeover"] == "true"
            }
        }
        XCTAssertEqual(daemon.process.processIdentifier, daemon.pid, "same process")

        let rePosted = try await request("POST", port: daemon.port, "/api/push/subscriptions", body: Self.browserBody())
        XCTAssertEqual(rePosted.status, 200, rePosted.body)
        XCTAssertEqual(try json(rePosted.body)["created"] as? Bool, false, "the successor already had it")
        XCTAssertEqual(try json(rePosted.body)["count"] as? Int, 1)
    }

    // MARK: - Helpers

    /// Loopback is full grade; a request naming the trusted host must present
    /// a token, which is how a watch grade reaches the route.
    private func useProxiedServer() throws {
        try? channel.close().wait()
        channel = try makeServer(
            store: store,
            policy: .proxied(token: Self.full, watchToken: Self.watch, trustedHosts: [Self.trustedHost])
        )
        port = channel.localAddress?.port
    }

    /// One HTTP/1.1 request over a raw socket with `Host` set to the trusted
    /// host, so the policy reads it as a remote caller.
    private func raw(_ method: String, _ target: String, body: String) throws -> (status: Int, body: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connect failed: errno \(errno)")
        let lines = [
            "\(method) \(target) HTTP/1.1", "Host: \(Self.trustedHost)", "Connection: close",
            "Content-Type: application/json", "Content-Length: \(body.utf8.count)",
        ]
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        request.withUnsafeBytes { XCTAssertEqual(send(fd, $0.baseAddress, $0.count, 0), request.count) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        guard let split = received.range(of: Data("\r\n\r\n".utf8)) else {
            XCTFail("no header block in \(String(decoding: received, as: UTF8.self))")
            return (0, "")
        }
        let head = String(decoding: received[..<split.lowerBound], as: UTF8.self).split(separator: "\r\n")
        let status = Int(head.first?.split(separator: " ").dropFirst().first ?? "0") ?? 0
        return (status, String(decoding: received[split.upperBound...], as: UTF8.self))
    }

    private struct Daemon {
        let process: Process
        let port: Int
        let pid: Int32
    }

    /// A scratch `kitterm serve` on a free port under the test's own state
    /// directory, never the one the developer's daemon uses.
    private func startDaemon() throws -> Daemon {
        let executable = Self.buildDir.appendingPathComponent("kitterm")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "kitterm binary not built beside the test bundle"
        )
        let port = try freePort()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--port", "\(port)"]
        var environment = ProcessInfo.processInfo.environment
        environment["KITTERM_STATE_DIR"] = stateDir.path
        environment["SHELL"] = "/bin/sh"
        process.environment = environment
        try process.run()
        return Daemon(process: process, port: port, pid: process.processIdentifier)
    }

    private func stop(_ daemon: Daemon) {
        guard daemon.process.isRunning else { return }
        kill(daemon.pid, SIGTERM)
        daemon.process.waitUntilExit()
    }

    private func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func waitFor(
        _ what: String, timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = SuspendingClock.now + .seconds(timeout)
        while SuspendingClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50), clock: .suspending)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        throw CancellationError()
    }

    private func request(
        _ method: String, port: Int, _ path: String, body: String? = nil
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private func freePort() throws -> Int {
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
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw CancellationError() }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
