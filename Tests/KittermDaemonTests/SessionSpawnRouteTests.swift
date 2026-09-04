import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `POST /api/sessions`, `GET /api/sessions/<id>`, `PATCH /api/sessions/<id>`
/// — sessions as API objects, the foreman substrate. Same real-loop harness as
/// `HTTPRoutesIntegrationTests`: the registry is an actor, so its promises
/// cannot live on an `EmbeddedEventLoop`.
final class SessionSpawnRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var serverChannel: Channel!
    private var registry: SessionRegistry!
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: SessionSpawnRouteTests.self)
            .bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        registry = SessionRegistry()
        serverChannel = try makeServer(agentControl: true)
        port = serverChannel.localAddress?.port
    }

    private func makeServer(agentControl: Bool) throws -> Channel {
        let registry = self.registry!
        return try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
                            policy: .loopbackOnly,
                            agentControl: agentControl,
                            staticRoot: nil
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    override func tearDown() async throws {
        // Spawned sessions live in the registry, not a local list.
        await registry.terminateAll()
        try? serverChannel.close().wait()
        try? await group.shutdownGracefully()
    }

    // MARK: - HTTP helpers

    private func request(
        _ method: String,
        _ path: String,
        json body: [String: Any]? = nil,
        port overridePort: Int? = nil
    ) async throws -> (status: Int, body: String) {
        let target = overridePort ?? port!
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(target)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
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

    // MARK: - spawn

    /// The core contract: a program creates a named, labelled session and gets
    /// back an id plus the paths a person needs to join it. The session starts
    /// detached so the first browser join becomes its controller.
    func testSpawnCreatesADetachedNamedSession() async throws {
        let response = try await request("POST", "/api/sessions", json: [
            "name": "payments-retry-bug",
            "note": "crew: fixing the retry storm",
            "labels": ["crew": "alpha"],
            "cwd": NSTemporaryDirectory(),
        ])
        XCTAssertEqual(response.status, 201, response.body)
        let created = try json(response.body)
        XCTAssertEqual(created["ok"] as? Bool, true)
        let id = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(created["name"] as? String, "payments-retry-bug")
        XCTAssertEqual(created["wsPath"] as? String, "/ws?session=\(id)")
        XCTAssertEqual(created["pagePath"] as? String, "/?session=\(id)")

        let detail = try await request("GET", "/api/sessions/\(id)")
        XCTAssertEqual(detail.status, 200, detail.body)
        let row = try json(detail.body)
        XCTAssertEqual(row["name"] as? String, "payments-retry-bug")
        XCTAssertEqual(row["note"] as? String, "crew: fixing the retry storm")
        XCTAssertEqual((row["labels"] as? [String: String])?["crew"], "alpha")
        XCTAssertEqual(row["attached"] as? Bool, false)
        XCTAssertNil(row["exited"], "a fresh shell is not exited")
    }

    /// Spawning a shell from a request body is strictly more powerful than
    /// typing into an existing one, so it sits behind the same flag as input.
    func testSpawnIsRefusedWithoutAgentControl() async throws {
        let readOnly = try makeServer(agentControl: false)
        defer { try? readOnly.close().wait() }
        let readOnlyPort = try XCTUnwrap(readOnly.localAddress?.port)

        let response = try await request(
            "POST", "/api/sessions", json: [:], port: readOnlyPort
        )
        XCTAssertEqual(response.status, 403, response.body)
        XCTAssertTrue(response.body.contains("agent-control"))
        let count = await registry.count
        XCTAssertEqual(count, 0, "no shell may be spawned through a refused route")
    }

    /// A program that misnames something hears so — no silent fallbacks.
    func testSpawnRejectsInvalidFields() async throws {
        let cases: [[String: Any]] = [
            ["cwd": "/no/such/directory/kitterm-test"],
            ["profile": "kitterm-test-no-such-profile"],
            ["name": String(repeating: "a", count: KittermConstants.maxSessionNameLength + 1)],
            ["name": "bell\u{07}name"],
            ["labels": ["UPPER CASE KEY!": "x"]],
            ["labels": ["run": ["nested": "object"]]],
            ["input": ""],
        ]
        for body in cases {
            let response = try await request("POST", "/api/sessions", json: body)
            XCTAssertEqual(response.status, 400, "\(body) should be rejected: \(response.body)")
        }
        let count = await registry.count
        XCTAssertEqual(count, 0, "a rejected spawn must not leave a shell behind")
    }

    /// `input` is typed into the shell at its first read, so one call spawns
    /// a working session. The echo through the PTY proves it arrived.
    func testSpawnDeliversInitialInput() async throws {
        let marker = "kitterm-spawn-\(UInt32.random(in: 0..<UInt32.max))"
        let response = try await request("POST", "/api/sessions", json: [
            "input": "echo \(marker)\n",
        ])
        XCTAssertEqual(response.status, 201, response.body)
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(json(response.body)["id"] as? String)))
        let registered = await registry.session(id)
        let session = try XCTUnwrap(registered)

        var seen = ""
        for _ in 0..<100 {
            let range = session.outputRange(from: 0, to: .max, maxBytes: 1 << 20)
            seen = String(decoding: range.data, as: UTF8.self)
            if seen.contains(marker) { break }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        XCTAssertTrue(seen.contains(marker), "initial input should reach the shell; saw: \(seen)")
    }

    /// The shell exits, the session stays: an API session is orchestrated by
    /// construction, and `exited`/`exitCode` stay reportable through the
    /// detached-exit wiring.
    func testSpawnedSessionSurvivesItsShellExit() async throws {
        let response = try await request("POST", "/api/sessions", json: [
            "input": "exit 3\n",
        ])
        XCTAssertEqual(response.status, 201, response.body)
        let id = try XCTUnwrap(json(response.body)["id"] as? String)

        var row: [String: Any] = [:]
        for _ in 0..<100 {
            let detail = try await request("GET", "/api/sessions/\(id)")
            guard detail.status == 200 else {
                return XCTFail("session vanished instead of surviving exit: \(detail.status)")
            }
            row = try json(detail.body)
            if row["exited"] as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        XCTAssertEqual(row["exited"] as? Bool, true, "exit should be reportable: \(row)")
        XCTAssertEqual(row["exitCode"] as? Int, 3)
    }

    /// A shell that dies before the exit handler is installed used to be an
    /// exit nobody heard: `deliverExit` fires once, and the API path installs
    /// its handler only after the registry hop. `detach(onExitWhileDetached:)`
    /// now fires at once for an already-exited shell, so the row still reads
    /// `exited` with the code. Reproduced with a shell that cannot start.
    func testSpawnWhoseShellDiesAtOnceStillReportsExit() async throws {
        // A SHELL that exits immediately with a known code.
        let previous = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", "/usr/bin/false", 1)
        defer { setenv("SHELL", previous ?? "/bin/sh", 1) }

        let response = try await request("POST", "/api/sessions", json: [:])
        XCTAssertEqual(response.status, 201, response.body)
        let id = try XCTUnwrap(json(response.body)["id"] as? String)

        var row: [String: Any] = [:]
        for _ in 0..<100 {
            let detail = try await request("GET", "/api/sessions/\(id)")
            guard detail.status == 200 else { return XCTFail("session vanished: \(detail.status)") }
            row = try json(detail.body)
            if row["exited"] as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(row["exited"] as? Bool, true, "an immediate exit must still be reported: \(row)")
        XCTAssertNotNil(row["exitCode"])
    }

    /// Past the registry ceiling the route answers 503 and the extra shell is
    /// gone — the cap check spawns first to stay atomic, so it must clean up.
    func testSpawnAtCapacityIs503() async throws {
        var filler: [PtySession] = []
        defer { for session in filler { session.terminate() } }
        for _ in 0..<KittermConstants.maxConcurrentSessions {
            let session = try PtySession.spawn(cwd: NSTemporaryDirectory())
            filler.append(session)
            let id = await registry.register(session)
            XCTAssertNotNil(id)
        }

        let response = try await request("POST", "/api/sessions", json: [:])
        XCTAssertEqual(response.status, 503, response.body)
        XCTAssertTrue(response.body.contains("too many sessions"))
        let count = await registry.count
        XCTAssertEqual(count, KittermConstants.maxConcurrentSessions)
    }

    // MARK: - detail

    func testDetailOfAnUnknownSessionIs404() async throws {
        let response = try await request("GET", "/api/sessions/\(UUID().uuidString)")
        XCTAssertEqual(response.status, 404, response.body)
    }

    // MARK: - patch

    /// Rename, note, and label updates land in the listing; an empty name
    /// clears. Metadata only, so no `--agent-control` needed.
    func testPatchUpdatesNameNoteAndLabels() async throws {
        let created = try await request("POST", "/api/sessions", json: ["name": "before"])
        XCTAssertEqual(created.status, 201, created.body)
        let id = try XCTUnwrap(json(created.body)["id"] as? String)

        let patch = try await request("PATCH", "/api/sessions/\(id)", json: [
            "name": "after",
            "note": "review round two",
            "labels": ["crew": "beta", "task": "retry-bug"],
        ])
        XCTAssertEqual(patch.status, 200, patch.body)

        var row = try json(try await request("GET", "/api/sessions/\(id)").body)
        XCTAssertEqual(row["name"] as? String, "after")
        XCTAssertEqual(row["note"] as? String, "review round two")
        XCTAssertEqual((row["labels"] as? [String: String])?["task"], "retry-bug")

        // An empty name clears it; the untouched note stays.
        let clear = try await request("PATCH", "/api/sessions/\(id)", json: ["name": ""])
        XCTAssertEqual(clear.status, 200, clear.body)
        row = try json(try await request("GET", "/api/sessions/\(id)").body)
        XCTAssertNil(row["name"])
        XCTAssertEqual(row["note"] as? String, "review round two")
    }

    /// PATCH works without `--agent-control` — metadata does not drive a
    /// shell, same reasoning that keeps approval decisions outside the flag.
    func testPatchWorksWithoutAgentControl() async throws {
        let created = try await request("POST", "/api/sessions", json: [:])
        XCTAssertEqual(created.status, 201, created.body)
        let id = try XCTUnwrap(json(created.body)["id"] as? String)

        let readOnly = try makeServer(agentControl: false)
        defer { try? readOnly.close().wait() }
        let readOnlyPort = try XCTUnwrap(readOnly.localAddress?.port)

        let patch = try await request(
            "PATCH", "/api/sessions/\(id)",
            json: ["name": "named-anyway"],
            port: readOnlyPort
        )
        XCTAssertEqual(patch.status, 200, patch.body)
        let row = try json(try await request("GET", "/api/sessions/\(id)").body)
        XCTAssertEqual(row["name"] as? String, "named-anyway")
    }

    func testPatchRejectsInvalidFieldsAndUnknownSession() async throws {
        let missing = try await request(
            "PATCH", "/api/sessions/\(UUID().uuidString)", json: ["name": "x"]
        )
        XCTAssertEqual(missing.status, 404, missing.body)

        let created = try await request("POST", "/api/sessions", json: [:])
        let id = try XCTUnwrap(json(created.body)["id"] as? String)
        let bad = try await request("PATCH", "/api/sessions/\(id)", json: [
            "note": String(repeating: "n", count: KittermConstants.maxSessionNoteLength + 1),
        ])
        XCTAssertEqual(bad.status, 400, bad.body)
    }
}
