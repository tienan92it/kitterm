import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// A hook names its pane by `KITTERM_SESSION_ID`, and a process that
/// inherited that variable can host a conversation from another project
/// (issue #181). The pane that holds a join refuses such a hook: the join
/// and the agent status stay, nothing is held, and the feed says
/// `agent.join-mismatch` once. Driven through `/api/hooks` against a real
/// handler with real sessions whose cwd the kernel reports.
final class AgentJoinMismatchRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var approvals: ApprovalStore!
    private var eventLog: EventLog!
    private var stateDir: URL!
    private var sessions: [PtySession] = []
    private var port: Int!
    /// A checkout, the pane's project.
    private var home: String!
    /// Another checkout, the stranger's project.
    private var other: String!
    /// A directory outside every project.
    private var plain: String!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: AgentJoinMismatchRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        // Created first, then made real: the kernel reports a shell's cwd
        // as `/private/var/…`, and the paths here must compare equal to it.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-join-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.path), isDirectory: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        home = try dir("home")
        _ = try dir("home/.git")
        _ = try dir("home/sub")
        other = try dir("other")
        _ = try dir("other/.git")
        plain = try dir("plain")
        _ = try dir("plain/sub")

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLog = EventLog()
        registry = SessionRegistry(eventLog: eventLog)
        approvals = ApprovalStore()
        let registry = self.registry!
        let approvals = self.approvals!
        let eventLog = self.eventLog!
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
                            policy: .loopbackOnly,
                            agentControl: true,
                            approvals: approvals,
                            eventLog: eventLog,
                            staticRoot: nil
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        for session in sessions { session.terminate() }
        sessions = []
        try? channel?.close().wait()
        try? await group.shutdownGracefully()
        unsetenv("KITTERM_STATE_DIR")
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    // MARK: - Payloads, in the shape Claude Code sends them

    private static let owner = "0a0a0a0a-1111-4c0e-9a3b-000000000001"
    private static let second = "0a0a0a0a-2222-4c0e-9a3b-000000000002"
    private static let stranger = "0a0a0a0a-9999-4c0e-9a3b-000000000009"

    private static func transcript(_ run: String) -> String {
        "/Users/someone/.claude/projects/-Users-someone-Workspace/\(run).jsonl"
    }

    private static func payload(_ event: String, run: String, cwd: String, extra: String = "") -> String {
        #"{"hook_event_name":"\#(event)","session_id":"\#(run)","transcript_path":"\#(transcript(run))","cwd":"\#(cwd)"\#(extra)}"#
    }

    private static let waiting = #","message":"Claude is waiting for your input""#
    private static let bash = #","tool_name":"Bash","tool_input":{"command":"ls"}"#

    // MARK: - The stranger

    /// The measured defect: the pane holds its own join, and a hook with
    /// another `session_id` and a cwd in another project names it. The join
    /// and the status stay, and the feed says so once.
    func testAStrangerHookLeavesTheJoinAndTheStatusAloneAndEmitsOneEvent() async throws {
        let pane = try await spawn(cwd: home)
        try await hook(pane, Self.payload("Notification", run: Self.owner, cwd: home, extra: Self.waiting))

        try await hook(pane, Self.payload("PreToolUse", run: Self.stranger, cwd: other, extra: Self.bash))

        let row = try await sessionRow(pane)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.owner)
        XCTAssertEqual(row["agentTranscript"] as? String, Self.transcript(Self.owner))
        XCTAssertEqual(row["mergedState"] as? String, "needs-input", "the stranger's working is not the pane's")
        XCTAssertEqual((row["agent"] as? [String: Any])?["status"] as? String, "needs-input")

        XCTAssertEqual(
            events(pane, "agent.join-mismatch"),
            [["sessionId": Self.stranger, "cwd": other, "transcript": Self.transcript(Self.stranger)]]
        )
        XCTAssertEqual(
            events(pane, "agent.status"),
            [["status": "needs-input", "message": "Claude is waiting for your input"]],
            "the refused hook is no transition on the pane"
        )
    }

    /// The feed hears a stranger once per pane, whichever of its hooks
    /// comes and however many: a busy stranger must not wake a foreman per
    /// tool call. A second stranger is its own event.
    func testARepeatedStrangerHookEmitsNoSecondEvent() async throws {
        let pane = try await spawn(cwd: home)
        try await hook(pane, Self.payload("Notification", run: Self.owner, cwd: home, extra: Self.waiting))

        for _ in 0..<3 {
            try await hook(pane, Self.payload("PreToolUse", run: Self.stranger, cwd: other, extra: Self.bash))
        }
        try await hook(pane, Self.payload("Stop", run: Self.stranger, cwd: other))
        XCTAssertEqual(events(pane, "agent.join-mismatch").count, 1)

        try await hook(pane, Self.payload("Stop", run: Self.second, cwd: plain))
        XCTAssertEqual(
            events(pane, "agent.join-mismatch").map { $0["sessionId"] },
            [Self.stranger, Self.second]
        )
        let row = try await sessionRow(pane)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.owner)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")
    }

    // MARK: - The cases that stay as they were

    /// A second `claude` in the same shell is a new `session_id` whose cwd
    /// is in the pane's project: it replaces the join and its status counts.
    /// The cwd arrives through a symlink here, because the kernel names the
    /// pane's cwd by its real path and a hook need not.
    func testASecondClaudeInTheSameProjectReplacesTheJoin() async throws {
        let pane = try await spawn(cwd: home)
        try await hook(pane, Self.payload("Notification", run: Self.owner, cwd: home, extra: Self.waiting))

        let link = stateDir.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home)
        try await hook(pane, Self.payload("PreToolUse", run: Self.second, cwd: link + "/sub", extra: Self.bash))

        let row = try await sessionRow(pane)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.second)
        XCTAssertEqual(row["agentTranscript"] as? String, Self.transcript(Self.second))
        XCTAssertEqual((row["agent"] as? [String: Any])?["status"] as? String, "working")
        XCTAssertEqual(events(pane, "agent.join-mismatch"), [])
    }

    /// A pane with no join has no owner to protect, so its first hook is
    /// accepted wherever its cwd is: refusing it would leave a pane whose
    /// `claude` was started from another directory with no join at all.
    func testTheFirstHookOnAPaneWithNoJoinIsAcceptedWhereverItsCwdIs() async throws {
        let pane = try await spawn(cwd: home)

        try await hook(pane, Self.payload("PreToolUse", run: Self.stranger, cwd: other, extra: Self.bash))

        let row = try await sessionRow(pane)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.stranger)
        XCTAssertEqual(row["mergedState"] as? String, "working")
        XCTAssertEqual(events(pane, "agent.join-mismatch"), [])
    }

    /// A pane outside every project has no project to compare, so the
    /// payload's cwd is compared with the pane's own: at or under it is the
    /// pane's, anywhere else is a stranger's.
    func testAPaneWithNoProjectComparesThePayloadCwdWithItsOwn() async throws {
        let pane = try await spawn(cwd: plain)
        try await hook(pane, Self.payload("Notification", run: Self.owner, cwd: plain, extra: Self.waiting))

        try await hook(pane, Self.payload("Stop", run: Self.second, cwd: plain + "/sub"))
        var row = try await sessionRow(pane)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.second, "a cwd under the pane's is the pane's")
        XCTAssertEqual((row["agent"] as? [String: Any])?["status"] as? String, "completed")

        try await hook(pane, Self.payload("PreToolUse", run: Self.stranger, cwd: home, extra: Self.bash))
        row = try await sessionRow(pane)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.second)
        XCTAssertEqual((row["agent"] as? [String: Any])?["status"] as? String, "completed")
        XCTAssertEqual(events(pane, "agent.join-mismatch").map { $0["sessionId"] }, [Self.stranger])
    }

    // MARK: - The held event

    /// A stranger's `PermissionRequest` is not the pane's question: it is
    /// answered `{}` at once, so the agent shows its own dialog, and no
    /// approval waits on the wrong pane. The pane's own is still held.
    func testARefusedPermissionRequestAnswersAtOnceAndHoldsNoApproval() async throws {
        let pane = try await spawn(cwd: home)
        try await hook(pane, Self.payload("Notification", run: Self.owner, cwd: home, extra: Self.waiting))

        // A held hook would run into this request's timeout.
        let refused = try await request(
            "POST", "/api/hooks?timeout=60",
            body: Self.payload("PermissionRequest", run: Self.stranger, cwd: other, extra: Self.bash),
            headers: ["X-Kitterm-Session": pane.uuidString], timeout: 5
        )
        XCTAssertEqual(refused.status, 200, refused.body)
        XCTAssertEqual(refused.body, "{}")
        XCTAssertEqual(approvals.snapshot().count, 0)
        XCTAssertEqual(events(pane, "approval.pending"), [])
        XCTAssertEqual(events(pane, "agent.join-mismatch").count, 1)
        let row = try await sessionRow(pane)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")
        XCTAssertNil(row["pendingApproval"])

        // The pane's own agent still gets its hold and its verdict.
        let own = Self.payload("PermissionRequest", run: Self.owner, cwd: home, extra: Self.bash)
        let port = try XCTUnwrap(self.port)
        async let held = Self.request(
            port: port, "POST", "/api/hooks?timeout=60",
            body: own, headers: ["X-Kitterm-Session": pane.uuidString]
        )
        var pending: [ApprovalStore.Pending] = []
        try await wait("the pane's own request to be held") {
            pending = self.approvals.snapshot()
            return !pending.isEmpty
        }
        XCTAssertEqual(pending.first?.sessionID, pane)
        let decided = try await request(
            "POST", "/api/approvals/\(try XCTUnwrap(pending.first).id)", body: #"{"decision":"allow"}"#
        )
        XCTAssertEqual(decided.status, 200, decided.body)
        let answer = try await held
        XCTAssertTrue(answer.body.contains(#""behavior":"allow""#), answer.body)
    }

    // MARK: - Helpers

    private func dir(_ path: String) throws -> String {
        let url = stateDir.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// A session whose shell holds the terminal in `cwd`: before that the
    /// kernel reports the spawn helper, whose cwd is still this process's,
    /// and the pane's project would be this checkout's.
    private func spawn(cwd: String) async throws -> UUID {
        let session = try PtySession.spawn(cwd: cwd, spawnedByAPI: true)
        sessions.append(session)
        let id = await registry.register(session)
        try await wait("the shell to start in \(cwd)") {
            guard let leader = session.foregroundLeader, leader.group == session.pid, let name = leader.name
            else { return false }
            return name != SpawnHelperPath.name && session.liveCwd == cwd
        }
        return try XCTUnwrap(id)
    }

    private func hook(_ id: UUID, _ body: String) async throws {
        let answer = try await request(
            "POST", "/api/hooks", body: body, headers: ["X-Kitterm-Session": id.uuidString]
        )
        XCTAssertEqual(answer.status, 200, answer.body)
        XCTAssertEqual(answer.body, "{}")
    }

    /// The payloads of one event type on the feed for one session, in order.
    private func events(_ id: UUID, _ type: String) -> [[String: String]] {
        eventLog.snapshot(since: 0, session: id).events
            .filter { $0.type == type }
            .map(\.data)
    }

    private func sessionRow(_ id: UUID) async throws -> [String: Any] {
        let listed = try json(try await request("GET", "/api/sessions").body)
        let rows = try XCTUnwrap(listed["sessions"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { ($0["id"] as? String) == id.uuidString })
    }

    private func request(
        _ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> (status: Int, body: String) {
        try await Self.request(port: port, method, path, body: body, headers: headers, timeout: timeout)
    }

    /// Static, so an `async let` holds a request open without `self`.
    private static func request(
        port: Int, _ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private func wait(
        _ what: String, file: StaticString = #filePath, line: UInt = #line,
        until condition: () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }
}
