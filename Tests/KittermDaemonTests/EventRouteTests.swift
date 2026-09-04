import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/events` and `POST /api/sessions/<id>/events` over a real loop and
/// socket, with the same `EventLog` wired into the registry and the handler so
/// lifecycle events and posted notes share one feed.
final class EventRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var eventLog: EventLog!
    private var session: PtySession!
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: EventRouteTests.self).bundleURL.deletingLastPathComponent()
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
        session?.terminate()
        try? channel.close().wait()
        try? await group.shutdownGracefully()
    }

    private func registerSession() async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        self.session = session
        let registered = await registry.register(session)
        return try XCTUnwrap(registered)
    }

    private func get(_ path: String, timeout: TimeInterval = 30) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func post(_ path: String, _ body: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func events(_ json: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(json["events"] as? [[String: Any]])
    }

    /// A spawn emits `session.created`; a posted note emits `note`; both show
    /// up on the feed in order.
    func testLifecycleAndNoteEvents() async throws {
        let id = try await registerSession()

        let status = try await post(
            "/api/sessions/\(id.uuidString)/events",
            #"{"message":"plan ready for review"}"#
        )
        XCTAssertEqual(status, 200)

        let feed = try await get("/api/events?since=0")
        let items = try events(feed)
        XCTAssertEqual(items.first?["type"] as? String, "session.created")
        let note = try XCTUnwrap(items.first { ($0["type"] as? String) == "note" })
        XCTAssertEqual(note["session"] as? String, id.uuidString)
        XCTAssertEqual((note["data"] as? [String: Any])?["message"] as? String, "plan ready for review")
        XCTAssertEqual(feed["pruned"] as? Bool, false)
    }

    /// A poll for events that do not exist yet parks, then wakes the instant a
    /// note is posted — the one-request-for-a-whole-fleet property.
    func testPollParksThenWakesOnANote() async throws {
        let id = try await registerSession()
        // Drain the created event so the next poll has nothing waiting.
        let cursor = try await get("/api/events?since=0")["next"] as? UInt64 ?? 0

        // Park the poll in a task that captures only the port (Sendable), not
        // `self`, so the concurrency checker is satisfied.
        let p = port!
        let parked = Task { () -> Data in
            let url = URL(string: "http://127.0.0.1:\(p)/api/events?since=\(cursor)&timeout=20")!
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        // Give the poll a moment to actually park before posting.
        try await Task.sleep(nanoseconds: 200_000_000)
        let posted = try await post(
            "/api/sessions/\(id.uuidString)/events",
            #"{"message":"woke you"}"#
        )
        XCTAssertEqual(posted, 200)

        let data = try await parked.value
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try events(json)
        XCTAssertEqual(items.count, 1, "the parked poll returns exactly the new event")
        XCTAssertEqual(items.first?["type"] as? String, "note")
    }

    /// A note for an unknown session is a 404, not a phantom event.
    func testNoteForUnknownSessionIs404() async throws {
        let status = try await post(
            "/api/sessions/\(UUID().uuidString)/events",
            #"{"message":"nobody home"}"#
        )
        XCTAssertEqual(status, 404)
    }

    /// A session filter narrows the feed to one crew member.
    func testSessionFilter() async throws {
        let id = try await registerSession()
        _ = try await post("/api/sessions/\(id.uuidString)/events", #"{"message":"mine"}"#)

        let filtered = try await get("/api/events?since=0&session=\(id.uuidString)")
        let items = try events(filtered)
        // Only this session's events: its created + its note.
        XCTAssertTrue(items.allSatisfy { ($0["session"] as? String) == id.uuidString })
        XCTAssertTrue(items.contains { ($0["type"] as? String) == "note" })
    }
}
