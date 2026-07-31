import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// Routes that only exist once a real event loop, a real registry and a real
/// session are wired together — the wait timeout schedules a task and races it
/// against a waiter, and label filtering runs over live summaries. An
/// `EmbeddedChannel` cannot host either: the registry is an actor, so its
/// promises complete from a Swift-concurrency thread, which `EmbeddedEventLoop`
/// rejects. So this binds a real server on an ephemeral port.
final class HTTPRoutesIntegrationTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var serverChannel: Channel!
    private var registry: SessionRegistry!
    private var sessions: [PtySession] = []
    private var port: Int!

    override class func setUp() {
        super.setUp()
        // The spawn helper sits beside the test bundle, not on the inherited
        // PATH — the same setup `CommandWaitTests` needs to fork a shell.
        let buildDir = Bundle(for: HTTPRoutesIntegrationTests.self)
            .bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        registry = SessionRegistry()
        let registry = self.registry!
        serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
                            policy: .loopbackOnly,
                            agentControl: true,
                            staticRoot: nil
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = serverChannel.localAddress?.port
    }

    override func tearDownWithError() throws {
        for session in sessions { session.terminate() }
        sessions = []
        try? serverChannel.close().wait()
        try? group.syncShutdownGracefully()
    }

    /// Register a session, optionally labelled, and return its id.
    private func makeSession(labels: String? = nil) async throws -> UUID {
        let session = try PtySession.spawn(
            cwd: NSTemporaryDirectory(),
            labels: SessionLabels.parse(labels)
        )
        sessions.append(session)
        let id = await registry.register(session)
        return try XCTUnwrap(id, "registry refused the session")
    }

    @discardableResult
    private func get(
        _ path: String,
        timeout: TimeInterval = 30
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        return (
            (response as? HTTPURLResponse)?.statusCode ?? 0,
            String(decoding: data, as: UTF8.self)
        )
    }

    private func json(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
    }

    // MARK: - wait

    /// The timeout arm of the wait route: a command that started and never
    /// ended must come back as still running rather than as a failure, so a
    /// slow node does not look like a broken one.
    func testWaitTimesOutWithoutFailingTheCommand() async throws {
        let id = try await makeSession()
        let session = sessions[0]
        // A start with no end: command 1 exists and is running.
        var buffer = ByteBufferAllocator().buffer(capacity: 32)
        buffer.writeString("\u{1b}]133;C\u{07}working…")
        session.handleRead(&buffer)

        let started = Date()
        let response = try await get("/api/sessions/\(id.uuidString)/commands/1/wait?timeout=1")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(response.status, 200, "a timeout is not an error: \(response.body)")
        let body = try json(response.body)
        XCTAssertEqual(body["timedOut"] as? Bool, true)
        XCTAssertEqual(body["running"] as? Bool, true)
        XCTAssertNil(body["exit"], "a command that has not ended has no exit code")
        XCTAssertGreaterThan(elapsed, 0.8, "it must actually wait, not answer instantly")
        XCTAssertLessThan(elapsed, 5, "and it must give up near its deadline")
    }

    /// The other arm: the closing mark arrives while the caller is blocked.
    func testWaitReturnsWhenTheCommandFinishes() async throws {
        let id = try await makeSession()
        let session = sessions[0]
        var start = ByteBufferAllocator().buffer(capacity: 32)
        start.writeString("\u{1b}]633;E;make test\u{07}\u{1b}]133;C\u{07}out")
        session.handleRead(&start)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            var end = ByteBufferAllocator().buffer(capacity: 16)
            end.writeString("\u{1b}]133;D;7\u{07}")
            session.handleRead(&end)
        }

        let response = try await get("/api/sessions/\(id.uuidString)/commands/1/wait?timeout=20")
        XCTAssertEqual(response.status, 200)
        let body = try json(response.body)
        XCTAssertEqual(body["exit"] as? Int, 7, "the real exit code, not a timeout")
        XCTAssertEqual(body["running"] as? Bool, false)
        XCTAssertEqual(body["command"] as? String, "make test")
        XCTAssertNotNil(body["durationMs"])
    }

    /// An index below the retained window ran and aged out. Saying "gone" keeps
    /// a caller from reading it as "that command never existed" — and, before
    /// numbering was made stable, this is where a stale index silently resolved
    /// to a different command.
    func testAgedOutCommandIsReportedAsGoneNotMissing() async throws {
        let id = try await makeSession()
        let session = sessions[0]
        // Push more commands through than the mark window holds.
        let perCommand = "\u{1b}]133;C\u{07}x\u{1b}]133;D;0\u{07}"
        for _ in 0..<(KittermConstants.sessionMarkCap) {
            var buffer = ByteBufferAllocator().buffer(capacity: perCommand.utf8.count)
            buffer.writeString(perCommand)
            session.handleRead(&buffer)
        }
        XCTAssertGreaterThan(
            session.firstRetainedCommandIndex, 1,
            "the window must actually have slid for this to test anything"
        )

        let response = try await get("/api/sessions/\(id.uuidString)/commands/1/wait?timeout=1")
        XCTAssertEqual(response.status, 410, "expected Gone, got \(response.status): \(response.body)")
        XCTAssertTrue(response.body.contains("aged out"))
    }

    // MARK: - label filtering

    func testLabelFilterNarrowsTheListing() async throws {
        _ = try await makeSession(labels: "run:alpha,node:build")
        _ = try await makeSession(labels: "run:beta,node:build")
        _ = try await makeSession()  // unlabelled

        let all = try json(try await get("/api/sessions").body)
        XCTAssertEqual((all["sessions"] as? [[String: Any]])?.count, 3)

        let filtered = try json(try await get("/api/sessions?label=run:alpha").body)
        let matched = try XCTUnwrap(filtered["sessions"] as? [[String: Any]])
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual((matched[0]["labels"] as? [String: String])?["run"], "alpha")

        let byNode = try json(try await get("/api/sessions?label=node:build").body)
        XCTAssertEqual((byNode["sessions"] as? [[String: Any]])?.count, 2)

        let noMatch = try json(try await get("/api/sessions?label=run:nothing").body)
        XCTAssertEqual((noMatch["sessions"] as? [[String: Any]])?.count, 0)
    }

    /// A filter with no `key:value` shape is a caller mistake. Answering it
    /// with an empty list is indistinguishable from "that run has no sessions".
    func testMalformedLabelFilterIsRejected() async throws {
        _ = try await makeSession(labels: "run:alpha")
        // `?label=` with no value reads as "unset", not as a malformed
        // filter, so it is not in this list.
        for bad in ["run", ":alpha", "run:", "run=alpha"] {
            let response = try await get("/api/sessions?label=\(bad.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? bad)")
            XCTAssertEqual(response.status, 400, "\"\(bad)\" should be rejected, got \(response.status)")
        }
    }
}
