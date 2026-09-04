import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// A `Notification` or `Stop` hook used to be dropped; now it drives the typed
/// status the fleet view shows. Tested over a real loop with a real session in
/// the registry, so the summary join actually runs.
final class HookStatusRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var approvals: ApprovalStore!
    private var session: PtySession!
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: HookStatusRouteTests.self)
            .bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        registry = SessionRegistry()
        approvals = ApprovalStore()
    }

    override func tearDown() async throws {
        session?.terminate()
        try? channel.close().wait()
        try? await group.shutdownGracefully()
    }

    private func makeServer(policy: AccessPolicy) throws -> Channel {
        let registry = self.registry!
        let approvals = self.approvals!
        return try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
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

    private func registerSession() async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse("run:x"))
        self.session = session
        let id = await registry.register(session)
        return try XCTUnwrap(id)
    }

    private func post(_ path: String, _ body: String, headers: [String: String] = [:]) async throws
        -> (status: Int, body: String)
    {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func sessionRow(_ id: UUID) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port!)/api/sessions")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        return try XCTUnwrap(sessions.first { ($0["id"] as? String) == id.uuidString })
    }

    /// A `Notification` marks the session `needs-input` and carries its message
    /// into the listing.
    func testNotificationBecomesNeedsInput() async throws {
        channel = try makeServer(policy: .loopbackOnly)
        port = channel.localAddress?.port
        let id = try await registerSession()

        let response = try await post(
            "/api/hooks",
            #"{"hook_event_name":"Notification","message":"Claude needs your permission"}"#,
            headers: ["X-Kitterm-Session": id.uuidString]
        )
        XCTAssertEqual(response.status, 200, response.body)
        XCTAssertEqual(response.body, "{}", "a Notification never blocks")

        let row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")
        let agent = try XCTUnwrap(row["agent"] as? [String: Any])
        XCTAssertEqual(agent["status"] as? String, "needs-input")
        XCTAssertEqual(agent["message"] as? String, "Claude needs your permission")
    }

    /// A `Stop` marks the session `completed` when nothing is running.
    func testStopBecomesCompleted() async throws {
        channel = try makeServer(policy: .loopbackOnly)
        port = channel.localAddress?.port
        let id = try await registerSession()

        let response = try await post(
            "/api/hooks",
            #"{"hook_event_name":"Stop"}"#,
            headers: ["X-Kitterm-Session": id.uuidString]
        )
        XCTAssertEqual(response.status, 200, response.body)

        let row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
    }

    /// `PreToolUse` records `working` — the edge that clears a stale
    /// `needs-input` — and answers at once. A `PermissionRequest` then holds,
    /// during which the row reads `needs-approval` (the hard fact outranks the
    /// report). Answered so the hold releases.
    func testPreToolUseRecordsWorkingAndPermissionRequestHoldsAsNeedsApproval() async throws {
        channel = try makeServer(policy: .loopbackOnly)
        port = channel.localAddress?.port
        let id = try await registerSession()
        // A stale notification the tool call should supersede.
        _ = try await post(
            "/api/hooks", #"{"hook_event_name":"Notification","message":"old"}"#,
            headers: ["X-Kitterm-Session": id.uuidString]
        )
        let stale = try await sessionRow(id)
        XCTAssertEqual(stale["mergedState"] as? String, "needs-input")

        // The tool call itself: recorded, never held.
        let pre = try await post(
            "/api/hooks", #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#,
            headers: ["X-Kitterm-Session": id.uuidString]
        )
        XCTAssertEqual(pre.body, "{}")
        let working = try await sessionRow(id)
        XCTAssertEqual(working["mergedState"] as? String, "working", "PreToolUse clears the stale notification")

        let p = port!
        let header = id.uuidString
        let held = Task { () -> Int in
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(p)/api/hooks?timeout=20")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}"#.utf8)
            request.setValue(header, forHTTPHeaderField: "X-Kitterm-Session")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        // Wait for the hold to register, then read the row while it is held.
        var pendingID: String?
        for _ in 0..<100 {
            let url = URL(string: "http://127.0.0.1:\(p)/api/approvals")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let first = (json?["approvals"] as? [[String: Any]])?.first {
                pendingID = first["id"] as? String
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let approvalID = try XCTUnwrap(pendingID, "the PermissionRequest hook never registered a hold")
        let row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-approval")
        XCTAssertEqual((row["agent"] as? [String: Any])?["status"] as? String, "working")

        _ = try await post("/api/approvals/\(approvalID)", #"{"decision":"allow"}"#)
        let hookStatus = try await held.value
        XCTAssertEqual(hookStatus, 200)
        // Hold released: the stale notification is gone, the agent is working.
        let after = try await sessionRow(id)
        XCTAssertEqual(after["mergedState"] as? String, "working")
    }

    /// An unknown event still degrades to "no opinion" — recorded by nobody,
    /// answered `{}` — so an over-broad hook config and a schema change both
    /// stay harmless.
    func testUnknownEventRecordsNothing() async throws {
        channel = try makeServer(policy: .loopbackOnly)
        port = channel.localAddress?.port
        let id = try await registerSession()

        let response = try await post(
            "/api/hooks",
            #"{"hook_event_name":"SessionStart"}"#,
            headers: ["X-Kitterm-Session": id.uuidString]
        )
        XCTAssertEqual(response.status, 200, response.body)
        XCTAssertEqual(response.body, "{}")

        let row = try await sessionRow(id)
        XCTAssertNil(row["agent"], "an unrecognised event leaves no status")
    }
}
