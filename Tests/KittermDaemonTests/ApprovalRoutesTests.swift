import Foundation
import KittermProtocol
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// The contract with a real agent: a `PreToolUse` hook POSTs and *does not get
/// a response* until a human answers or the hold expires. Everything else in
/// this feature is decoration around that one behaviour, so it is tested over a
/// real loop and a real socket rather than against the store directly.
final class ApprovalRoutesTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var approvals: ApprovalStore!
    private var port: Int!

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        approvals = ApprovalStore()
        channel = try makeServer(policy: .loopbackOnly)
        port = channel.localAddress?.port
    }

    override func tearDownWithError() throws {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }

    private func makeServer(policy: AccessPolicy) throws -> Channel {
        let approvals = self.approvals!
        return try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: SessionRegistry(),
                            policy: policy,
                            agentControl: true,
                            approvals: approvals,
                            staticRoot: nil
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    // MARK: - helpers

    private static func post(
        port: Int,
        _ path: String,
        _ body: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)\(path)")!
        )
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (
            (response as? HTTPURLResponse)?.statusCode ?? 0,
            String(decoding: data, as: UTF8.self)
        )
    }

    private static func get(port: Int, _ path: String) async throws -> (status: Int, body: String) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        return (
            (response as? HTTPURLResponse)?.statusCode ?? 0,
            String(decoding: data, as: UTF8.self)
        )
    }

    private static func json(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    /// The held event: Claude would show a permission dialog for this call.
    private static let permissionRequest = """
    {"hook_event_name":"PermissionRequest","tool_name":"Bash",\
    "tool_input":{"command":"rm -rf build"},"session_id":"abc"}
    """
    private static let preToolUse = """
    {"hook_event_name":"PreToolUse","tool_name":"Bash",\
    "tool_input":{"command":"rm -rf build"},"session_id":"abc"}
    """

    /// Wait for the hook to register, without assuming how fast the loop is.
    private static func waitForPendingID(port: Int) async throws -> String {
        for _ in 0..<100 {
            let listed = try Self.json(try await get(port: port, "/api/approvals").body)
            if let items = listed["approvals"] as? [[String: Any]], let first = items.first {
                return try XCTUnwrap(first["id"] as? String)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the hook never registered a pending approval")
        return ""
    }

    // MARK: - the loop

    func testAllowReachesTheBlockedAgent() async throws {
        let p = port!
        async let hook = Self.post(port: p, "/api/hooks", Self.permissionRequest)

        let id = try await Self.waitForPendingID(port: p)
        let answered = try await Self.post(
            port: p, "/api/approvals/\(id)", #"{"decision":"allow","reason":"fine"}"#
        )
        XCTAssertEqual(answered.status, 200, answered.body)

        let response = try await hook
        XCTAssertEqual(response.status, 200)
        let specific = try XCTUnwrap(
            try Self.json(response.body)["hookSpecificOutput"] as? [String: Any]
        )
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(specific["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
    }

    func testDenyReachesTheBlockedAgent() async throws {
        let p = port!
        async let hook = Self.post(port: p, "/api/hooks", Self.permissionRequest)
        let id = try await Self.waitForPendingID(port: p)
        _ = try await Self.post(port: p, "/api/approvals/\(id)", #"{"decision":"deny","reason":"not on main"}"#)

        let response = try await hook
        let specific = try XCTUnwrap(
            try Self.json(response.body)["hookSpecificOutput"] as? [String: Any]
        )
        let decision = try XCTUnwrap(specific["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "not on main")
    }

    /// The failure mode that matters most: nobody answers. The agent must get a
    /// response with no opinion in it, promptly, and fall back to its own
    /// prompt — not hang until Claude's own hook timeout kills it.
    func testUnansweredHoldExpiresWithNoDecision() async throws {
        let started = Date()
        let response = try await Self.post(port: port, "/api/hooks?timeout=1", Self.permissionRequest)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(try Self.json(response.body).isEmpty, "expected no opinion: \(response.body)")
        XCTAssertGreaterThan(elapsed, 0.8, "it must actually hold, not answer instantly")
        XCTAssertLessThan(elapsed, 10, "and it must give up near its deadline")
    }

    /// A pane's own identity travels in a header, because a hook config is
    /// static and cannot look it up.
    func testSessionHeaderIsCarriedIntoTheListing() async throws {
        let session = UUID()
        let p = port!
        async let hook = Self.post(
            port: p, "/api/hooks?timeout=2", Self.permissionRequest,
            headers: ["X-Kitterm-Session": session.uuidString]
        )
        _ = try await Self.waitForPendingID(port: p)
        let listed = try Self.json(try await Self.get(port: p, "/api/approvals").body)
        let items = try XCTUnwrap(listed["approvals"] as? [[String: Any]])
        XCTAssertEqual(items.first?["session"] as? String, session.uuidString)
        XCTAssertEqual(items.first?["tool"] as? String, "Bash")
        _ = try await hook
    }

    /// `PreToolUse` fires for every tool call, allowed or not, so it must
    /// never be held: an always-on hook that held it made every Read and Edit
    /// in a pane wait up to five minutes. It answers `{}` at once and
    /// registers nothing.
    func testPreToolUseDoesNotHoldOrRegister() async throws {
        let started = Date()
        let response = try await Self.post(port: port, "/api/hooks", Self.preToolUse)
        XCTAssertEqual(response.status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "must not hold")
        XCTAssertEqual(try Self.json(response.body).count, 0, "no opinion: \(response.body)")
        let listed = try Self.json(try await Self.get(port: port, "/api/approvals").body)
        XCTAssertEqual((listed["approvals"] as? [[String: Any]])?.count ?? 0, 0,
                       "a PreToolUse must not appear as something to approve")
    }

    /// Informational events are recorded and answered at once; nothing waits.
    func testNotificationEventDoesNotBlock() async throws {
        let started = Date()
        let response = try await Self.post(
            port: port,
            "/api/hooks",
            #"{"hook_event_name":"Notification","message":"agent_needs_input"}"#
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "must not hold")
        XCTAssertEqual(try Self.json(response.body).count, 0)
    }

    /// An over-broad hook config costs nothing.
    func testUnknownEventIsHarmless() async throws {
        let response = try await Self.post(port: port, "/api/hooks", #"{"hook_event_name":"SessionStart"}"#)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(try Self.json(response.body).isEmpty)
    }

    func testAnsweringAnUnknownApprovalIs404() async throws {
        let response = try await Self.post(port: port, "/api/approvals/nope", #"{"decision":"allow"}"#)
        XCTAssertEqual(response.status, 404, response.body)
    }

    func testMalformedDecisionIsRejected() async throws {
        let response = try await Self.post(port: port, "/api/approvals/whatever", #"{"decision":"maybe"}"#)
        XCTAssertEqual(response.status, 400, response.body)
    }

    /// Deciding for an agent is a human privilege, and a watch token exists to
    /// withhold exactly this.
    ///
    /// Driven through an `EmbeddedChannel` rather than a socket because
    /// loopback is unconditionally full-grade — the only way a token decides
    /// anything is a request naming a trusted host, which needs a `Host` header
    /// URLSession will not let a test set.
    func testWatchTokenCannotDecide() throws {
        let watch = "ktw_" + String(repeating: "e", count: 32)
        let handler = HTTPAPIHandler(
            registry: SessionRegistry(),
            policy: .proxied(
                token: String(repeating: "f", count: 32),
                watchToken: watch,
                trustedHosts: ["box.example.test"]
            ),
            agentControl: true,
            approvals: approvals,
            staticRoot: nil
        )
        let channel = EmbeddedChannel(handler: handler)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        defer { _ = try? channel.finish() }

        let denied = try Self.embeddedPost(
            channel,
            uri: "/api/approvals/anything?token=\(watch)",
            host: "box.example.test",
            body: #"{"decision":"allow"}"#
        )
        XCTAssertEqual(denied.status, .forbidden, denied.body)
        XCTAssertTrue(denied.body.contains("watch-only"), denied.body)
    }

    /// The same request with the full token gets past the grade check — proving
    /// the 403 above is about the grade and not about the route.
    func testFullTokenPassesTheGradeCheck() throws {
        let full = String(repeating: "f", count: 32)
        let handler = HTTPAPIHandler(
            registry: SessionRegistry(),
            policy: .proxied(
                token: full,
                watchToken: "ktw_" + String(repeating: "e", count: 32),
                trustedHosts: ["box.example.test"]
            ),
            agentControl: true,
            approvals: approvals,
            staticRoot: nil
        )
        let channel = EmbeddedChannel(handler: handler)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        defer { _ = try? channel.finish() }

        let answered = try Self.embeddedPost(
            channel,
            uri: "/api/approvals/no-such-id?token=\(full)",
            host: "box.example.test",
            body: #"{"decision":"allow"}"#
        )
        // 404 because that id does not exist — but it reached the lookup, which
        // the watch token never does.
        XCTAssertEqual(answered.status, .notFound, answered.body)
    }

    /// Feed one POST through an embedded pipeline and drain the response.
    private static func embeddedPost(
        _ channel: EmbeddedChannel,
        uri: String,
        host: String,
        body: String
    ) throws -> (status: HTTPResponseStatus, body: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(version: .http1_1, method: .POST, uri: uri, headers: headers)
            )
        )
        var buffer = channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        try channel.writeInbound(HTTPServerRequestPart.body(buffer))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        var status: HTTPResponseStatus?
        var text = ""
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let head): status = head.status
            case .body(.byteBuffer(var chunk)):
                text += chunk.readString(length: chunk.readableBytes) ?? ""
            default: break
            }
        }
        return (status ?? .internalServerError, text)
    }
}

