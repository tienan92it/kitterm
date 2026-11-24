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
/// reads `completed`, exactly as a turn with no job does. The report and its
/// feed event carry the count of those jobs (`ownJobs`), and the one change
/// of behaviour is that the idle notice which follows such a turn is dropped:
/// no `needs-input`, no feed event, no push.
///
/// The payloads are the shapes Claude Code 2.1.330 sent on 2026-11-22: `Stop`
/// carries `background_tasks`, and the idle notice carries
/// `notification_type: "idle_prompt"`. Two task types were measured, `shell`
/// (a Bash call with `run_in_background`) and `monitor`. Driven over a real
/// loop with a real session.
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

    private func registerPane() async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse("run:x"))
        self.session = session
        // Input reaches the shell only through the reader channel the spawn
        // service would have made.
        try await session.makeReader(group: group, eventLoop: group.next()).get()
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

    // MARK: - the rule

    /// `Stop` with a job gives `completed` with the count, on the row and on
    /// the one feed event. The idle notice a minute later is dropped: the
    /// state stays `completed`, the feed gains no event, the phone hears
    /// nothing.
    func testStopWithAJobIsCompletedWithTheCountAndTheIdleNoticeIsDropped() async throws {
        let id = try await registerPane()

        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
        XCTAssertEqual(ownJobs(row), 1)
        XCTAssertEqual(statusEvents(id), [["status": "working"], ["status": "completed", "ownJobs": "1"]])

        try await hook(id, Self.idleNotice)
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
        XCTAssertEqual(ownJobs(row), 1)
        XCTAssertNil((row["agent"] as? [String: Any])?["message"], "the idle notice is not recorded")

        XCTAssertEqual(statusEvents(id), [["status": "working"], ["status": "completed", "ownJobs": "1"]])
        let sent = try await pushes()
        XCTAssertEqual(sent, 0)
    }

    /// The idle notice is dropped each time it comes while that report
    /// stands. No time limit ends the rule.
    func testEveryIdleNoticeIsDroppedWhileTheReportStands() async throws {
        let id = try await registerPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)

        for _ in 0..<3 { try await hook(id, Self.idleNotice) }
        let row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
        XCTAssertEqual(statusEvents(id).count, 2)
        let sent = try await pushes()
        XCTAssertEqual(sent, 0)
    }

    /// `Stop` with an empty list, then the idle notice: `completed`, then
    /// `needs-input` with one push, as on main.
    func testStopThenIdleNoticeWithNoJobGivesCompletedThenNeedsInput() async throws {
        let id = try await registerPane()

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

    /// A `Stop` payload without `background_tasks` (an older Claude Code)
    /// acts as on main: `completed` with no count, and the idle notice then
    /// gives `needs-input`.
    func testAStopWithoutTheFieldActsAsOnMain() async throws {
        let id = try await registerPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, #"{"hook_event_name":"Stop"}"#)
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
        XCTAssertNil(ownJobs(row))

        try await hook(id, Self.idleNotice)
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")
        XCTAssertEqual(statusEvents(id).map { $0["status"] }, ["working", "completed", "needs-input"])
        XCTAssertNil(statusEvents(id)[1]["ownJobs"])
    }

    /// A tool call held for a human after a turn that left a job running is
    /// `needs-approval`, and the phone hears it.
    func testAPermissionRequestAfterAStopWithAJobGivesNeedsApproval() async throws {
        let id = try await registerPane()
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
        XCTAssertNil(ownJobs(row), "the count belongs to a completed row")
        let sent = try await pushes()
        XCTAssertEqual(sent, 1)

        _ = try await post("/api/approvals/\(approvalID)", #"{"decision":"allow"}"#)
        let status = try await held.value
        XCTAssertEqual(status, 200)
    }

    /// A permission notice and a question are not the idle notice: after a
    /// `Stop` with a job each still gives `needs-input`, an event and a push.
    func testANoticeThatIsNotTheIdleNoticeStillGivesNeedsInput() async throws {
        let id = try await registerPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)

        try await hook(
            id,
            #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#
        )
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")
        XCTAssertNil(ownJobs(row), "the count belongs to a completed row")
        XCTAssertEqual(statusEvents(id).last, [
            "status": "needs-input", "message": "Claude needs your permission to use Bash",
        ])
        let sent = try await pushes()
        XCTAssertEqual(sent, 1)

        // A layout with no `notification_type` is not the idle notice.
        try await hook(id, Self.stopWithAShell)
        try await hook(id, #"{"hook_event_name":"Notification","message":"Which branch do you want?"}"#)
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")
        XCTAssertEqual((row["agent"] as? [String: Any])?["message"] as? String, "Which branch do you want?")
    }

    /// The job's end wakes the agent, and its next `Stop` names no job. The
    /// count leaves the row, and the idle notice then counts again.
    func testWhenTheJobEndsTheIdleNoticeCountsAgain() async throws {
        let id = try await registerPane()
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
        // The second `completed` is the `Stop` that named no job any more.
        XCTAssertEqual(
            statusEvents(id).map { $0["status"] }, ["working", "completed", "completed", "needs-input"]
        )
    }

    /// The job ends and the agent answers with text only, so no `PreToolUse`
    /// comes before its `Stop` with an empty list. On main the idle notice
    /// stood between the two `Stop`s and the second one reached the feed.
    /// The notice is dropped now, so the change of the count is the
    /// transition: the feed gets `completed` again and a watcher wakes.
    func testTheStopAfterTheJobEndsReachesTheFeedWithNoToolCallBetween() async throws {
        let id = try await registerPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stop([("shell", "running"), ("monitor", "running")]))
        try await hook(id, Self.idleNotice)

        // One of the two jobs ends: the count changes, the feed says so.
        try await hook(id, Self.stopWithAShell)
        try await hook(id, Self.stopWithNoJob)
        let row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
        XCTAssertNil(ownJobs(row))
        XCTAssertEqual(statusEvents(id), [
            ["status": "working"],
            ["status": "completed", "ownJobs": "2"],
            ["status": "completed", "ownJobs": "1"],
            ["status": "completed"],
        ])

        // With no job on either side the second `Stop` is silent, as on main.
        try await hook(id, Self.stopWithNoJob)
        XCTAssertEqual(statusEvents(id).count, 4)
        let sent = try await pushes()
        XCTAssertEqual(sent, 0)
    }

    /// A new turn replaces the report, so the idle notice of the earlier
    /// turn is read as on main.
    func testAfterANewTurnStartsTheIdleNoticeIsNotDropped() async throws {
        let id = try await registerPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)
        try await hook(id, Self.preToolUse)

        try await hook(id, Self.idleNotice)
        let row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "needs-input")
    }

    // MARK: - what counts as a job

    /// Only `status` is read. `shell` and `monitor` are the measured types;
    /// a type nobody has seen is still a job. A task that is not `running`
    /// is not counted. The state is `completed` each time.
    func testOnlyRunningTasksCountAndAnUnknownTypeIsAJob() async throws {
        let id = try await registerPane()
        try await hook(id, Self.preToolUse)

        try await hook(id, Self.stop([("shell", "running"), ("monitor", "running"), ("shell", "completed")]))
        var row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
        XCTAssertEqual(ownJobs(row), 2)
        XCTAssertEqual(statusEvents(id).last, ["status": "completed", "ownJobs": "2"])

        try await hook(id, Self.stop([("a-type-of-next-year", "running")]))
        row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "completed")
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

    /// The merged state is what main computes: the count on a report never
    /// changes what the merge returns.
    func testTheCountNeverChangesTheMergedState() {
        let now = Date()
        func merged(_ agent: AgentStatus, _ derived: DerivedSessionState) -> MergedSessionState {
            MergedSessionState.merge(derived: derived, agent: agent, pendingApproval: false, exited: false)
        }
        let older = DerivedSessionState(
            state: .running, lastCommand: "claude", lastExit: nil, lastMarkAt: now.addingTimeInterval(-60)
        )
        let newer = DerivedSessionState(
            state: .idle, lastCommand: "claude", lastExit: 1, lastMarkAt: now.addingTimeInterval(60)
        )
        for derived in [older, newer] {
            XCTAssertEqual(
                merged(AgentStatus(report: .completed, message: nil, at: now, ownJobs: 2), derived),
                merged(AgentStatus(report: .completed, message: nil, at: now), derived)
            )
        }
        XCTAssertEqual(merged(AgentStatus(report: .completed, message: nil, at: now, ownJobs: 2), older), .completed)
    }

    // MARK: - the count is on the row only while the report is the evidence

    /// Until the session's marks derive `state` (from a mark the shell sent).
    private func waitForMarks(_ state: SessionState) async throws {
        let deadline = SuspendingClock.now + .seconds(10)
        while SuspendingClock.now < deadline {
            if DerivedSessionState.derive(from: session.marksSnapshot()).state == state { return }
            try await Task.sleep(for: .milliseconds(50), clock: .suspending)
        }
        XCTFail("the marks never derived \(state)")
    }

    /// The human exits the agent and runs a long command in the same pane.
    /// The command's mark is newer than the report, so the marks give
    /// `working`, and the row carries no count.
    func testACommandNewerThanTheReportIsWorkingWithNoJobCount() async throws {
        let id = try await registerPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)
        let before = try await sessionRow(id)
        XCTAssertEqual(ownJobs(before), 1)

        // A preExec mark (OSC 133;C), as a shell with integration sends
        // before each command.
        try session.write(Data(#"printf '\033]133;C\007'; sleep 500"#.utf8 + [0x0A]))
        try await waitForMarks(.running)

        let row = try await sessionRow(id)
        XCTAssertEqual(row["state"] as? String, "running")
        XCTAssertEqual(row["mergedState"] as? String, "working")
        XCTAssertNil(ownJobs(row), "the marks made this row working, not the report")
    }

    /// The same guard for a command that ended after the report: the marks
    /// give `failed`, and the row carries no count.
    func testACommandThatEndedAfterTheReportCarriesNoJobCount() async throws {
        let id = try await registerPane()
        try await hook(id, Self.preToolUse)
        try await hook(id, Self.stopWithAShell)

        // A preExec mark, then a commandEnd mark with exit 1 (OSC 133;D;1).
        try session.write(Data(#"printf '\033]133;C\007'; printf '\033]133;D;1\007'"#.utf8 + [0x0A]))
        try await waitForMarks(.idle)

        let row = try await sessionRow(id)
        XCTAssertEqual(row["mergedState"] as? String, "failed")
        XCTAssertNil(ownJobs(row), "the marks made this row failed, not the report")
    }

    // MARK: - takeover

    /// A live upgrade carries the count, and a state file written before the
    /// field still loads.
    func testTheJobCountSurvivesATakeoverRecord() throws {
        let status = AgentStatus(
            report: .completed, message: nil, at: Date(timeIntervalSince1970: 1_795_000_000), ownJobs: 2
        )
        let record = TakeoverState.AgentStatusRecord(status)
        let decoded = try JSONDecoder().decode(
            TakeoverState.AgentStatusRecord.self, from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.status, status)
        XCTAssertEqual(decoded.status?.endedWithOwnJob, true)

        let old = try JSONDecoder().decode(
            TakeoverState.AgentStatusRecord.self,
            from: Data(#"{"report":"completed","at":1795000000000}"#.utf8)
        )
        XCTAssertEqual(old.status?.ownJobs, 0)
        XCTAssertEqual(old.status?.endedWithOwnJob, false)
    }
}
