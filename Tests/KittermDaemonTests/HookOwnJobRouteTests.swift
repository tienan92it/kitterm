import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KittermProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// An agent that ends its turn with a background job of its own still running
/// is not finished and does not want the human: the row stays `working`, the
/// feed hears no transition, and no push goes out, until the job ends.
///
/// The payloads are the shapes Claude Code 2.1.330 sent on 2026-11-22: `Stop`
/// carries `background_tasks`, and the idle notice carries
/// `notification_type: "idle_prompt"`. Two task types were measured, `shell`
/// (a Bash call with `run_in_background`) and `monitor`. Driven over a real
/// loop with a real session whose terminal a program holds, as an agent's is.
final class HookOwnJobRouteTests: XCTestCase {
    private final class RecordingTransport: PushTransport, @unchecked Sendable {
        private let lock = NIOLock()
        private var requests: [PushRequest] = []
        var sent: [PushRequest] { lock.withLock { requests } }

        func send(_ request: PushRequest) async -> Int? {
            lock.withLock {
                requests.append(request)
                return 201
            }
        }
    }

    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var approvals: ApprovalStore!
    private var eventLog: EventLog!
    private var stateDir: URL!
    private var transport: RecordingTransport!
    private var notifier: PushNotifier!
    private var session: PtySession!
    private var port: Int!

    private static let preToolUse = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#
    private static let idleNotice =
        #"{"hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#
    private static let stopWithNoJob = #"{"hook_event_name":"Stop","background_tasks":[],"session_crons":[]}"#

    /// A `Stop` payload with one task per `(type, status)` pair.
    private static func stop(_ tasks: [(type: String, status: String)]) -> String {
        let list = tasks.enumerated().map { index, task in
            #"{"id":"job\#(index)","type":"\#(task.type)","status":"\#(task.status)","command":"make watch"}"#
        }
        return #"{"hook_event_name":"Stop","background_tasks":[\#(list.joined(separator: ","))],"session_crons":[]}"#
    }

    private static let stopWithAShell = stop([("shell", "running")])

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: HookOwnJobRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUp() async throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-own-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLog = EventLog()
        registry = SessionRegistry(eventLog: eventLog)
        approvals = ApprovalStore()
        transport = RecordingTransport()
        let store = PushSubscriptionStore(file: stateDir.appendingPathComponent("push.json"))
        _ = store.upsert(FakeBrowser().subscription(endpoint: "https://push.example/phone"))
        notifier = PushNotifier(store: store, keys: VAPIDKeys(), registry: registry, transport: transport)

        let registry = self.registry!
        let approvals = self.approvals!
        let eventLog = self.eventLog!
        let notifier = self.notifier!
        channel = try await ServerBootstrap(group: group)
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
                            staticRoot: nil,
                            pushNotifier: notifier
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        session?.terminate()
        try? await channel?.close()
        try? await group.shutdownGracefully()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    /// A session whose terminal a program holds, the way `claude` holds an
    /// agent's pane: `sleep` stands in for the agent.
    private func registerAgentPane() async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse("run:x"))
        self.session = session
        // Input reaches the shell only through the reader channel the spawn
        // service would have made.
        try await session.makeReader(group: group, eventLoop: group.next()).get()
        try session.write(Data("sleep 600\n".utf8))
        try await waitForForeground("sleep", in: session)
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

    private func hook(_ id: UUID, _ body: String) async throws {
        let response = try await post("/api/hooks", body, headers: ["X-Kitterm-Session": id.uuidString])
        XCTAssertEqual(response.status, 200, response.body)
    }

    private func sessionRow(_ id: UUID) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port!)/api/sessions")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        return try XCTUnwrap(sessions.first { ($0["id"] as? String) == id.uuidString })
    }

    private func statusEvents(_ id: UUID) -> [[String: String]] {
        eventLog.snapshot(since: 0, session: id).events
            .filter { $0.type == "agent.status" }
            .map(\.data)
    }

    /// The pushes sent so far, once the notifier has none in flight.
    private func pushes() async throws -> Int {
        let deadline = SuspendingClock.now + .seconds(10)
        while !notifier.isDrained {
            guard SuspendingClock.now < deadline else {
                XCTFail("the notifier never drained")
                break
            }
            try await Task.sleep(for: .milliseconds(10), clock: .suspending)
        }
        return transport.sent.count
    }

    private func ownJobs(_ row: [String: Any]) -> Int? {
        (row["agent"] as? [String: Any])?["ownJobs"] as? Int
    }

    // MARK: - the fault

    /// Proof 1: `Stop` with a job, then the idle notice a minute later. The
    /// row stays `working` with the count, the feed holds the one `working`
    /// the tool call made, and the phone hears nothing.
    func testStopThenIdleNoticeWithAJobStaysWorkingWithNoEventAndNoPush() async throws {
        let id = try await registerAgentPane()

        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "working")
        XCTAssertEqual(ownJobs(row), 1)

        try await hook(id, Self.idleNotice)
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "working")
        XCTAssertEqual(ownJobs(row), 1)
        XCTAssertNil((row["agent"] as? [String: Any])?["message"], "the idle notice is not recorded")

        XCTAssertEqual(statusEvents(id), [["status": "working"]])
        let sent = try await pushes()
        XCTAssertEqual(sent, 0)
    }

    /// Proof 2: the same two hooks with no job read as they always did:
    /// `completed`, then `needs-input` with one push.
    func testStopThenIdleNoticeWithNoJobGivesCompletedThenNeedsInput() async throws {
        let id = try await registerAgentPane()

        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithNoJob)
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
        XCTAssertNil(ownJobs(row))

        try await hook(id, Self.idleNotice)
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")

        XCTAssertEqual(statusEvents(id), [
            ["status": "working"],
            ["status": "completed"],
            ["status": "needs-input", "message": "Claude is waiting for your input"],
        ])
        let sent = try await pushes()
        XCTAssertEqual(sent, 1)
    }

    /// Proof 3: a tool call held for a human during a job is `needs-approval`,
    /// and the phone hears it.
    func testAPermissionRequestDuringAJobGivesNeedsApproval() async throws {
        let id = try await registerAgentPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)

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
        XCTAssertNil(ownJobs(row), "the detail belongs to a working row")
        let sent = try await pushes()
        XCTAssertEqual(sent, 1)

        _ = try await post("/api/approvals/\(approvalID)", #"{"decision":"allow"}"#)
        let status = try await held.value
        XCTAssertEqual(status, 200)
    }

    /// A permission notice and a question are not the idle notice: during a
    /// job each still gives `needs-input`.
    func testANoticeThatIsNotTheIdleNoticeStillGivesNeedsInputDuringAJob() async throws {
        let id = try await registerAgentPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)

        try await hook(
            id,
            #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#
        )
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")

        // A layout with no `notification_type` falls back to the old rule.
        try await hook(id, Self.stopWithAShell)
        try await hook(id, #"{"hook_event_name":"Notification","message":"Which branch do you want?"}"#)
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")
        XCTAssertEqual((row["agent"] as? [String: Any])?["message"] as? String, "Which branch do you want?")
    }

    /// Proof 4: the job's end wakes the agent, and its next `Stop` names no
    /// job. The state leaves `working` for `completed`, and the idle notice
    /// then counts again.
    func testWhenTheJobEndsTheStateLeavesWorking() async throws {
        let id = try await registerAgentPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)
        try await hook(id, Self.idleNotice)

        try await hook(id, Self.stopWithNoJob)
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
        XCTAssertNil(ownJobs(row))

        try await hook(id, Self.idleNotice)
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")
        XCTAssertEqual(statusEvents(id).map { $0["status"] }, ["working", "completed", "needs-input"])
    }

    // MARK: - what counts as a job

    /// Only `status` is read. `shell` and `monitor` are the measured types;
    /// a type nobody has seen is still a job, so a new kind of background
    /// task does not bring the fault back. A task that is not `running` is
    /// not waited on.
    func testOnlyRunningTasksCountAndAnUnknownTypeIsAJob() async throws {
        let id = try await registerAgentPane()
        try await hook(id, Self.preToolUse)

        try await hook(id, Self.stop([("shell", "running"), ("monitor", "running"), ("shell", "completed")]))
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "working")
        XCTAssertEqual(ownJobs(row), 2)

        try await hook(id, Self.stop([("a-type-of-next-year", "running")]))
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "working")
        XCTAssertEqual(ownJobs(row), 1)

        try await hook(id, Self.stop([("shell", "completed"), ("monitor", "failed"), ("shell", "killed")]))
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
        XCTAssertNil(ownJobs(row))
    }

    func testRunningJobsReadsOnlyAListOfObjectsWithARunningStatus() {
        XCTAssertEqual(AgentStatus.runningJobs(in: nil), 0)
        XCTAssertEqual(AgentStatus.runningJobs(in: ["hook_event_name": "Stop"]), 0, "no field: the old rule")
        XCTAssertEqual(AgentStatus.runningJobs(in: ["background_tasks": "running"]), 0)
        XCTAssertEqual(AgentStatus.runningJobs(in: ["background_tasks": ["running", 1]]), 0)
        XCTAssertEqual(AgentStatus.runningJobs(in: ["background_tasks": [["status": "running"]]]), 1, "no type at all")
        XCTAssertEqual(AgentStatus.runningJobs(in: ["background_tasks": [["type": "shell", "status": 1]]]), 0)
    }

    // MARK: - the agent is gone

    /// The count must not outlive the agent. No hook says that `claude` has
    /// exited, so the row asks the terminal: once the shell reads it again,
    /// the report no longer counts and the marks decide, as they did before.
    func testTheJobCountDoesNotOutliveTheProgramAtTheTerminal() async throws {
        let id = try await registerAgentPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "working")

        // The stand-in agent ends, as `claude` does on `/exit`.
        let agent = try XCTUnwrap(session.foregroundLeader?.group)
        XCTAssertEqual(kill(agent, SIGKILL), 0)
        let deadline = SuspendingClock.now + .seconds(10)
        while session.foregroundProgram != nil, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50), clock: .suspending)
        }
        XCTAssertNil(session.foregroundProgram, "the stand-in agent never left the terminal")

        row = try await sessionRow(id)
        XCTAssertNotEqual(row["mergedState"] as? String, "working")
        XCTAssertNil(ownJobs(row))
    }

    /// Until the session's marks say a command is running (a preExec mark).
    private func waitForRunningMark() async throws {
        let deadline = SuspendingClock.now + .seconds(10)
        while SuspendingClock.now < deadline {
            if DerivedSessionState.derive(from: session.marksSnapshot()).state == .running { return }
            try await Task.sleep(for: .milliseconds(50), clock: .suspending)
        }
        XCTFail("the preExec mark never arrived")
    }

    /// The typed line that sends a preExec mark (OSC 133;C), as a shell with
    /// integration does before each command, then runs `command`.
    private static func marked(_ command: String) -> Data {
        Data(#"printf '\033]133;C\007'; \#(command)"#.utf8 + [0x0A])
    }

    /// The human exits the agent and runs a long command in the same pane.
    /// The command's mark is newer than the report, so the marks give
    /// `working`, and the row must print the command, not the wait: the
    /// count shows only when the report is what the state was read from.
    func testACommandNewerThanTheReportIsWorkingWithNoJobCount() async throws {
        let id = try await registerAgentPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)
        let before = try await sessionRow(id)
        XCTAssertEqual(ownJobs(before), 1)

        let agent = try XCTUnwrap(session.foregroundLeader?.group)
        XCTAssertEqual(kill(agent, SIGKILL), 0)
        try session.write(Self.marked("sleep 500"))
        try await waitForRunningMark()
        try await waitForForeground("sleep", in: session)

        let row = try await sessionRow(id)
        XCTAssertEqual(row["state"] as? String, "running")
        XCTAssertEqual(row["mergedState"] as? String, "working")
        XCTAssertNil(ownJobs(row), "the marks made this row working, not the report")
    }

    /// The second path to the same row: no program holds the terminal, so
    /// the report is dropped, and marks older than the report say running.
    func testRunningMarksWithNoProgramAtTheTerminalCarryNoJobCount() async throws {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse("run:x"))
        self.session = session
        try await session.makeReader(group: group, eventLoop: group.next()).get()
        try session.write(Self.marked("true"))
        try await waitForRunningMark()
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered)
        XCTAssertNil(session.foregroundProgram)

        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)

        let row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "working")
        XCTAssertNil(ownJobs(row), "the marks made this row working, not the report")
    }

    /// The same rule at the merge, with marks: a shell whose `claude` has
    /// ended reads `idle` or `failed` from the marks whatever their age, and
    /// a plain `working` report is not touched by the terminal's reader.
    func testTheMergeDropsAWaitingReportOnceNoProgramHoldsTheTerminal() {
        let now = Date()
        let waiting = AgentStatus(report: .working, message: nil, at: now, ownJobs: 1)
        let idle = DerivedSessionState(
            state: .idle, lastCommand: "claude", lastExit: 0, lastMarkAt: now.addingTimeInterval(-60)
        )
        func merged(_ agent: AgentStatus, _ derived: DerivedSessionState, holds: Bool) -> MergedSessionState {
            MergedSessionState.merge(
                derived: derived, agent: agent, pendingApproval: false, exited: false, programHoldsTerminal: holds
            )
        }
        XCTAssertEqual(merged(waiting, idle, holds: true), .working)
        XCTAssertEqual(merged(waiting, idle, holds: false), .idle)
        let failed = DerivedSessionState(
            state: .idle, lastCommand: "claude", lastExit: 1, lastMarkAt: now.addingTimeInterval(-60)
        )
        XCTAssertEqual(merged(waiting, failed, holds: false), .failed)

        let plain = AgentStatus(report: .working, message: nil, at: now)
        XCTAssertEqual(merged(plain, idle, holds: false), .working, "only the waiting report asks the terminal")
        let done = AgentStatus(report: .completed, message: nil, at: now)
        XCTAssertEqual(merged(done, idle, holds: false), .completed)
    }

    // MARK: - takeover

    /// A live upgrade carries the count, and a state file written before the
    /// field still loads.
    func testTheJobCountSurvivesATakeoverRecord() throws {
        let status = AgentStatus(report: .working, message: nil, at: Date(timeIntervalSince1970: 1_795_000_000), ownJobs: 2)
        let record = TakeoverState.AgentStatusRecord(status)
        let decoded = try JSONDecoder().decode(
            TakeoverState.AgentStatusRecord.self, from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.status, status)

        let old = try JSONDecoder().decode(
            TakeoverState.AgentStatusRecord.self,
            from: Data(#"{"report":"working","at":1795000000000}"#.utf8)
        )
        XCTAssertEqual(old.status?.ownJobs, 0)
        XCTAssertEqual(old.status?.waitsOnOwnJob, false)
    }
}
