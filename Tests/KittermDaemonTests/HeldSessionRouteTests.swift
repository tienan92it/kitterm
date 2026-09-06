import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `heldSince` on the session row and `session.lingered` on the feed, over a
/// real loop and socket: what a foreman reads to find the sessions the linger
/// clock is holding (ADR 0002).
final class HeldSessionRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var eventLog: EventLog!
    private var session: PtySession!
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: HeldSessionRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLog = EventLog()
        registry = SessionRegistry(orchestratedLingerSeconds: 1, eventLog: eventLog)
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
        session?.terminate()
        try? channel.close().wait()
        try? await group.shutdownGracefully()
    }

    private func get(_ path: String) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port!)\(path)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A detached API session with a program in the foreground survives its
    /// window. The row then carries `heldSince` (epoch millis) on both the
    /// list and the detail route, and the feed carries `session.lingered`
    /// naming the program and the same moment.
    func testHeldRowAndLingeredEvent() async throws {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        self.session = session
        let registered = await registry.registerDetached(session)
        let id = try XCTUnwrap(registered)
        try await session.makeReader(group: group, eventLoop: group.next()).get()
        try session.write(Data("sleep 4\n".utf8))

        let before = try await get("/api/sessions/\(id.uuidString)")
        XCTAssertNil(before["heldSince"], "not held before a window expires")

        var detail: [String: Any] = [:]
        let deadline = SuspendingClock.now + .seconds(6)
        while SuspendingClock.now < deadline {
            detail = try await get("/api/sessions/\(id.uuidString)")
            if detail["heldSince"] != nil { break }
            try await Task.sleep(for: .milliseconds(100), clock: .suspending)
        }
        let heldSince = try XCTUnwrap(detail["heldSince"] as? Int, "the detail row carries heldSince")
        XCTAssertGreaterThan(heldSince, 1_700_000_000_000, "epoch millis, like lastOutputAt")

        let list = try await get("/api/sessions")
        let rows = try XCTUnwrap(list["sessions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { ($0["id"] as? String) == id.uuidString })
        XCTAssertEqual(row["heldSince"] as? Int, heldSince, "the list row says the same")

        let feed = try await get("/api/events?since=0&session=\(id.uuidString)")
        let events = try XCTUnwrap(feed["events"] as? [[String: Any]])
        let lingered = try XCTUnwrap(events.first { ($0["type"] as? String) == "session.lingered" })
        let data = try XCTUnwrap(lingered["data"] as? [String: String])
        XCTAssertEqual(data["reason"], "foreground")
        XCTAssertEqual(data["program"], "sleep")
        XCTAssertEqual(data["heldSince"], String(heldSince))
    }
}
