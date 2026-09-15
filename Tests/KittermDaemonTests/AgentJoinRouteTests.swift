import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// Every Claude Code hook carries `session_id` and `transcript_path`, and the
/// daemon used to discard both. Now they are the join between a kitterm
/// session and the transcript that holds its bill: on the row as
/// `agentSessionId` and `agentTranscript`, and in the archive under the same
/// names. Driven through `/api/hooks` against a real handler with a real
/// session in the registry, the way `PushSendRouteTests` drives it.
final class AgentJoinRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var approvals: ApprovalStore!
    private var eventLog: EventLog!
    private var stateDir: URL!
    private var sessions: [PtySession] = []
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: AgentJoinRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        // A scratch state dir so the archive lands somewhere disposable.
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-agent-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)

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

    private static let firstRun = "e89e7ec8-1111-4c0e-9a3b-000000000001"
    private static let secondRun = "e89e7ec8-2222-4c0e-9a3b-000000000002"
    private static func transcript(_ run: String) -> String {
        "/Users/someone/.claude/projects/-Users-someone-Workspace-kitterm/\(run).jsonl"
    }

    private static func notification(run: String) -> String {
        #"{"hook_event_name":"Notification","session_id":"\#(run)","transcript_path":"\#(transcript(run))","message":"Claude is waiting for your input"}"#
    }

    private static func preToolUse(run: String) -> String {
        #"{"hook_event_name":"PreToolUse","session_id":"\#(run)","transcript_path":"\#(transcript(run))","tool_name":"Bash","tool_input":{}}"#
    }

    // MARK: - The proof from plan.md row 1

    /// A `Notification` hook puts both fields on the row; a second run's hook
    /// replaces them; the archive carries them; a session with no hook has
    /// neither.
    func testAHookPutsTheJoinOnTheRowAndInTheArchive() async throws {
        let ran = try await spawn()
        let quiet = try await spawn()

        try await hook(ran, Self.notification(run: Self.firstRun))
        var row = try await sessionRow(ran)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.firstRun)
        XCTAssertEqual(row["agentTranscript"] as? String, Self.transcript(Self.firstRun))
        XCTAssertEqual(row["mergedState"] as? String, "needs-input", "the hook path itself is unchanged")

        // The same shell runs `claude` again: the latest run wins, from
        // whichever hook arrives first.
        try await hook(ran, Self.preToolUse(run: Self.secondRun))
        row = try await sessionRow(ran)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.secondRun)
        XCTAssertEqual(row["agentTranscript"] as? String, Self.transcript(Self.secondRun))

        // The single-session route is the same row.
        let detail = try json(try await request("GET", "/api/sessions/\(ran.uuidString)").body)
        XCTAssertEqual(detail["agentSessionId"] as? String, Self.secondRun)
        XCTAssertEqual(detail["agentTranscript"] as? String, Self.transcript(Self.secondRun))

        // A session that never ran `claude` has neither field.
        let other = try await sessionRow(quiet)
        XCTAssertNil(other["agentSessionId"])
        XCTAssertNil(other["agentTranscript"])

        // The archive keeps the join, in the listing and in the detail.
        let archived = try await request("POST", "/api/sessions/\(ran.uuidString)/archive")
        XCTAssertEqual(archived.status, 200, archived.body)
        let detailed = try await request("GET", "/api/archives/\(ran.uuidString)")
        XCTAssertEqual(detailed.status, 200, detailed.body)
        let archive = try json(detailed.body)
        XCTAssertEqual(archive["agentSessionId"] as? String, Self.secondRun)
        XCTAssertEqual(archive["agentTranscript"] as? String, Self.transcript(Self.secondRun))
        let listed = try json(try await request("GET", "/api/archives").body)
        let entry = try XCTUnwrap(
            (listed["archives"] as? [[String: Any]])?.first { ($0["id"] as? String) == ran.uuidString }
        )
        XCTAssertEqual(entry["agentSessionId"] as? String, Self.secondRun)
        XCTAssertEqual(entry["agentTranscript"] as? String, Self.transcript(Self.secondRun))

        // And the file on disk says the same, so a reader with no daemon
        // finds the path there too.
        let file = stateDir.appendingPathComponent("archive/\(ran.uuidString)/archive.json")
        let onDisk = try json(String(decoding: try Data(contentsOf: file), as: UTF8.self))
        XCTAssertEqual(onDisk["agentSessionId"] as? String, Self.secondRun)
        XCTAssertEqual(onDisk["agentTranscript"] as? String, Self.transcript(Self.secondRun))

        // A session with no hook archives with neither field.
        _ = try await request("POST", "/api/sessions/\(quiet.uuidString)/archive")
        let quietArchive = try json(try await request("GET", "/api/archives/\(quiet.uuidString)").body)
        XCTAssertNil(quietArchive["agentSessionId"])
        XCTAssertNil(quietArchive["agentTranscript"])
    }

    /// Both fields or neither: a hook with one of them, or an empty one,
    /// leaves the row as it was. A `Stop` and a `PermissionRequest` carry
    /// the join too, so a run whose first hook is either still gets one.
    func testAHookWithHalfAJoinLeavesTheRowAlone() async throws {
        let id = try await spawn()

        try await hook(id, #"{"hook_event_name":"Notification","session_id":"\#(Self.firstRun)","message":"hi"}"#)
        try await hook(id, #"{"hook_event_name":"Notification","transcript_path":"/tmp/x.jsonl","message":"hi"}"#)
        try await hook(id, #"{"hook_event_name":"Notification","session_id":"","transcript_path":"","message":"hi"}"#)
        var row = try await sessionRow(id)
        XCTAssertNil(row["agentSessionId"])
        XCTAssertNil(row["agentTranscript"])

        try await hook(
            id,
            #"{"hook_event_name":"Stop","session_id":"\#(Self.firstRun)","transcript_path":"\#(Self.transcript(Self.firstRun))"}"#
        )
        row = try await sessionRow(id)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.firstRun)
        XCTAssertEqual(row["agentTranscript"] as? String, Self.transcript(Self.firstRun))

        // A later hook with half a join does not erase the whole one.
        try await hook(id, #"{"hook_event_name":"Notification","session_id":"\#(Self.secondRun)","message":"hi"}"#)
        row = try await sessionRow(id)
        XCTAssertEqual(row["agentSessionId"] as? String, Self.firstRun)
    }

    // MARK: - Helpers

    private func spawn() async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        sessions.append(session)
        let id = await registry.register(session)
        return try XCTUnwrap(id)
    }

    private func hook(_ id: UUID, _ body: String) async throws {
        let answer = try await request(
            "POST", "/api/hooks", body: body, headers: ["X-Kitterm-Session": id.uuidString]
        )
        XCTAssertEqual(answer.status, 200, answer.body)
    }

    private func sessionRow(_ id: UUID) async throws -> [String: Any] {
        let listed = try json(try await request("GET", "/api/sessions").body)
        let rows = try XCTUnwrap(listed["sessions"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { ($0["id"] as? String) == id.uuidString })
    }

    private func request(
        _ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:]
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }
}
