import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `command.failed` on the event feed: a command that ends with a non-zero
/// exit in an orchestrated session (a labelled or API-spawned one) appends one
/// event that names the session, the command's index on `/commands`, the exit
/// code, and the command line when the row has one. A command that exits 0,
/// and a browser session's failure, append nothing.
///
/// Over a real loop, socket and `/bin/sh`: the shell runs the command and
/// prints the marks around it with the real exit code, the way the
/// integration snippet does, so the feed is read the way a foreman reads it.
final class CommandFailedEventTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var eventLog: EventLog!
    private var sessions: [PtySession] = []
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: CommandFailedEventTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLog = EventLog()
        registry = SessionRegistry(eventLog: eventLog)
        let registry = self.registry!
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
        try? channel.close().wait()
        try? await group.shutdownGracefully()
    }

    // MARK: - Harness

    private enum Kind {
        /// `POST /api/sessions`: orchestrated with no label.
        case api
        /// A foreman's crew session.
        case labelled(String)
        /// A browser tab.
        case browser
    }

    /// A real shell, reading its PTY, admitted the way its kind is in the
    /// daemon: an API session detached, the others as a client's.
    private func startShell(_ kind: Kind) async throws -> (id: UUID, session: PtySession) {
        let session: PtySession
        switch kind {
        case .api:
            session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        case .labelled(let labels):
            session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse(labels))
        case .browser:
            session = try PtySession.spawn(cwd: NSTemporaryDirectory())
        }
        sessions.append(session)
        let registered: UUID?
        if case .api = kind {
            registered = await registry.registerDetached(session)
        } else {
            registered = await registry.register(session)
        }
        let id = try XCTUnwrap(registered, "registry refused the session")
        try await session.makeReader(group: group, eventLoop: group.next()).get()
        return (id, session)
    }

    /// Type one command line into the shell, wrapped in the marks the
    /// integration snippet prints: OSC 633;E with the command line when
    /// `named`, OSC 133;C before the command, OSC 133;D with the shell's own
    /// `$?` after it. The echo of the typed line carries `\033` as four plain
    /// characters, so only the shell's `printf` output reaches the scanner.
    private func run(_ command: String, named: Bool, in session: PtySession) throws {
        let start = named
            ? #"printf '\033]633;E;%s\007\033]133;C\007' '\#(command)'"#
            : #"printf '\033]133;C\007'"#
        let line = #"\#(start); \#(command); printf '\033]133;D;%d\007' $?"# + "\n"
        try session.write(Data(line.utf8))
    }

    private func get(_ path: String, timeout: TimeInterval = 30) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The finished command `n` as `/commands` prints it, waited for through
    /// the wait route so the mark has landed before the feed is read.
    private func finishedCommand(_ id: UUID, index: Int) async throws -> [String: Any] {
        let waited = try await get("/api/sessions/\(id.uuidString)/commands/\(index)/wait?timeout=20")
        XCTAssertEqual(waited["running"] as? Bool, false, "the command must have finished: \(waited)")
        let listing = try await get("/api/sessions/\(id.uuidString)/commands")
        let commands = try XCTUnwrap(listing["commands"] as? [[String: Any]])
        return try XCTUnwrap(commands.first { ($0["index"] as? Int) == index }, "command \(index) is listed")
    }

    private func failedEvents(_ id: UUID? = nil) async throws -> [[String: Any]] {
        let query = id.map { "&session=\($0.uuidString)" } ?? ""
        let feed = try await get("/api/events?since=0\(query)")
        let events = try XCTUnwrap(feed["events"] as? [[String: Any]])
        return events.filter { ($0["type"] as? String) == "command.failed" }
    }

    // MARK: - Completion condition 1

    /// An API-spawned session runs `false`: one event, with the index
    /// `/commands` gives the command, exit 1, and the command line.
    func testAFailedCommandInAnAPISessionIsOnTheFeed() async throws {
        let (id, session) = try await startShell(.api)
        try run("false", named: true, in: session)
        let command = try await finishedCommand(id, index: 1)
        XCTAssertEqual(command["exit"] as? Int, 1)
        XCTAssertEqual(command["command"] as? String, "false")

        let events = try await failedEvents()
        XCTAssertEqual(events.count, 1, "one event per failed command: \(events)")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["session"] as? String, id.uuidString)
        let data = try XCTUnwrap(event["data"] as? [String: String])
        XCTAssertEqual(data["index"], String(try XCTUnwrap(command["index"] as? Int)))
        XCTAssertEqual(data["exit"], "1")
        XCTAssertEqual(data["command"], "false")
    }

    /// A labelled session runs a command that exits 3 through a shell that
    /// marks the command but never names it (iTerm2's or p10k's OSC 133):
    /// the event carries the exit and no `command` key, like the row.
    func testTheExitCodeIsTheShellsAndAnUnnamedCommandHasNoLine() async throws {
        let (id, session) = try await startShell(.labelled("crew:alpha,run:one"))
        try run("sh -c 'exit 3'", named: false, in: session)
        let command = try await finishedCommand(id, index: 1)
        XCTAssertEqual(command["exit"] as? Int, 3)
        XCTAssertNil(command["command"], "the shell named nothing")

        let events = try await failedEvents(id)
        XCTAssertEqual(events.count, 1, "\(events)")
        let data = try XCTUnwrap(events.first?["data"] as? [String: String])
        XCTAssertEqual(data["index"], "1")
        XCTAssertEqual(data["exit"], "3")
        XCTAssertNil(data["command"], "no line on the row, no line on the event")
    }

    /// The index is the command's number, not its position in the window: a
    /// second command that fails after a first that passed is index 2.
    func testTheIndexIsTheCommandsNumberOnTheListing() async throws {
        let (id, session) = try await startShell(.api)
        try run("true", named: true, in: session)
        _ = try await finishedCommand(id, index: 1)
        try run("false", named: true, in: session)
        let command = try await finishedCommand(id, index: 2)
        XCTAssertEqual(command["exit"] as? Int, 1)

        let events = try await failedEvents(id)
        XCTAssertEqual(events.count, 1, "the passing command appended nothing: \(events)")
        XCTAssertEqual((events.first?["data"] as? [String: String])?["index"], "2")
    }

    // MARK: - Completion condition 2

    func testACommandThatExitsZeroAppendsNothing() async throws {
        let (id, session) = try await startShell(.api)
        try run("true", named: true, in: session)
        let command = try await finishedCommand(id, index: 1)
        XCTAssertEqual(command["exit"] as? Int, 0)
        let events = try await failedEvents()
        XCTAssertTrue(events.isEmpty, "exit 0 is not a failure: \(events)")
    }

    /// A browser tab's shell fails commands all day; the feed is a
    /// control-plane channel. The row still says `failed`, as before.
    func testABrowserSessionsFailureAppendsNothing() async throws {
        let (id, session) = try await startShell(.browser)
        try run("false", named: true, in: session)
        let command = try await finishedCommand(id, index: 1)
        XCTAssertEqual(command["exit"] as? Int, 1, "the row keeps the exit")
        let events = try await failedEvents()
        XCTAssertTrue(events.isEmpty, "an unorchestrated session is not on the feed: \(events)")
    }

    // MARK: - Completion condition 3

    /// A parked `GET /api/events` wakes on the event within the same poll,
    /// which is what lets a foreman hold one wait for the whole daemon.
    func testAParkedPollWakesOnTheEvent() async throws {
        let (id, session) = try await startShell(.api)
        let head = try await get("/api/events?since=0")
        let next = try XCTUnwrap(head["next"] as? Int)

        let started = Date()
        // Raw bytes cross the task boundary: a JSON object is not Sendable.
        let url = URL(string: "http://127.0.0.1:\(port!)/api/events?since=\(next)&timeout=20")!
        let parked = Task { try await URLSession.shared.data(from: url).0 }
        // Let the poll park before the command runs.
        try await Task.sleep(for: .milliseconds(300), clock: .suspending)
        try run("false", named: true, in: session)

        let body = try await parked.value
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 15, "the poll woke on the event, not at its deadline")
        let events = try XCTUnwrap(answer["events"] as? [[String: Any]])
        let failed = try XCTUnwrap(events.first { ($0["type"] as? String) == "command.failed" }, "\(events)")
        XCTAssertEqual(failed["session"] as? String, id.uuidString)
        XCTAssertEqual((failed["data"] as? [String: String])?["exit"], "1")
    }

    // MARK: - The append is the registry's, on the session's own decision

    /// The session calls its failed handler only for a non-zero exit in an
    /// orchestrated session, with the command as `commandsSnapshot` numbers
    /// it. Fed synthetically so the pairing is exact, including a stray end
    /// (a shell's first prompt) that pairs to no command and fires nothing.
    func testTheSessionFiresItsFailedHandlerOnlyForAPairedNonZeroExit() throws {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        sessions.append(session)
        nonisolated(unsafe) var fired: [SessionCommand] = []
        session.setCommandFailedHandler { fired.append($0) }
        func feed(_ text: String) {
            var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            session.handleRead(&buffer)
        }
        feed("\u{1b}]133;D;1\u{07}")  // the first prompt's end, no start before it
        XCTAssertEqual(fired.count, 0, "an end that pairs to no command is not a failure")
        feed("\u{1b}]633;E;make test\u{07}\u{1b}]133;C\u{07}ok\u{1b}]133;D;0\u{07}")
        XCTAssertEqual(fired.count, 0, "exit 0")
        feed("\u{1b}]633;E;make lint\u{07}\u{1b}]133;C\u{07}boom\u{1b}]133;D;2\u{07}")
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.index, 2)
        XCTAssertEqual(fired.first?.exit, 2)
        XCTAssertEqual(fired.first?.command, "make lint")
        XCTAssertEqual(session.commandsSnapshot().last?.index, 2, "the same number the listing gives")
    }

    func testABrowserSessionNeverFiresItsFailedHandler() throws {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory())
        sessions.append(session)
        nonisolated(unsafe) var fired = 0
        session.setCommandFailedHandler { _ in fired += 1 }
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeString("\u{1b}]133;C\u{07}boom\u{1b}]133;D;1\u{07}")
        session.handleRead(&buffer)
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(session.commandsSnapshot().first?.exit, 1, "the row still records it")
    }
}
