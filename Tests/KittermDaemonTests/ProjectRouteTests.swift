import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// The project on the API: the `project` and `orchestrated` row fields, the
/// `?project=` filters, `GET /api/projects`, and the cwd poll resolving the
/// project again after a `cd`.
final class ProjectRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var sessions: [PtySession] = []
    private var port: Int!
    private var stateDir: URL!
    private var alpha: String!
    private var repo: String!
    private var plain: String!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: ProjectRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        // Created first, then made real: the kernel reports a shell's cwd
        // as `/private/var/…`, and the rows must compare equal to it.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-project-routes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.path), isDirectory: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        alpha = try dir("alpha")
        repo = try dir("repo")
        _ = try dir("repo/.git")
        plain = try dir("plain")
        try ProjectStore.save([Project(id: "alpha", name: "Alpha", root: alpha)])

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        registry = SessionRegistry()
        let registry = self.registry!
        channel = try ServerBootstrap(group: group)
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
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        for session in sessions { session.terminate() }
        try? channel.close().wait()
        try? await group.shutdownGracefully()
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
    }

    // MARK: - helpers

    private func dir(_ path: String) throws -> String {
        let url = stateDir.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// A browser-like session: no labels, not spawned over the API.
    private func spawnDirect(cwd: String, labels: [String: String] = [:]) async throws -> UUID {
        let session = try PtySession.spawn(cwd: cwd, labels: SessionLabels(labels))
        sessions.append(session)
        let id = await registry.register(session)
        try await settle(session, in: cwd)
        return try XCTUnwrap(id)
    }

    /// Until the shell holds the terminal in `cwd`: before that the kernel
    /// reports the spawn helper, whose cwd is still this process's.
    private func settle(_ session: PtySession, in cwd: String) async throws {
        try await wait("the shell to start in \(cwd)") {
            guard let leader = session.foregroundLeader, leader.group == session.pid, let name = leader.name
            else { return false }
            return name != SpawnHelperPath.name && session.liveCwd == cwd
        }
    }

    /// An orchestrated session with a reader, through `POST /api/sessions`.
    private func spawnOverAPI(cwd: String, labels: [String: String] = [:]) async throws -> UUID {
        let body: [String: Any] = ["cwd": cwd, "labels": labels]
        let (status, data) = try await request("POST", "/api/sessions", body: try JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(status, 201, String(decoding: data, as: UTF8.self))
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(try json(data)["id"] as? String)))
        let registered = await registry.session(id)
        let session = try XCTUnwrap(registered)
        sessions.append(session)
        try await settle(session, in: cwd)
        return id
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func rows(_ path: String, key: String) async throws -> [[String: Any]] {
        let (status, data) = try await request("GET", path)
        XCTAssertEqual(status, 200, String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(try json(data)[key] as? [[String: Any]])
    }

    private func row(_ id: UUID, in rows: [[String: Any]]) throws -> [String: Any] {
        try XCTUnwrap(rows.first { ($0["id"] as? String) == id.uuidString })
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

    // MARK: - row fields

    func testRowsCarryTheProjectAndOrchestrated() async throws {
        let registered = try await spawnDirect(cwd: alpha)
        let discovered = try await spawnOverAPI(cwd: repo)
        let none = try await spawnDirect(cwd: plain)

        let sessions = try await rows("/api/sessions", key: "sessions")

        let registeredRow = try row(registered, in: sessions)
        XCTAssertEqual(registeredRow["orchestrated"] as? Bool, false)
        let registeredProject = try XCTUnwrap(registeredRow["project"] as? [String: Any])
        XCTAssertEqual(registeredProject["id"] as? String, "alpha")
        XCTAssertEqual(registeredProject["name"] as? String, "Alpha")
        XCTAssertEqual(registeredProject["root"] as? String, alpha)
        XCTAssertEqual(registeredProject["registered"] as? Bool, true)

        let discoveredRow = try row(discovered, in: sessions)
        XCTAssertEqual(discoveredRow["orchestrated"] as? Bool, true, "an API-spawned session is orchestrated")
        let discoveredProject = try XCTUnwrap(discoveredRow["project"] as? [String: Any])
        XCTAssertEqual(discoveredProject["id"] as? String, "repo")
        XCTAssertEqual(discoveredProject["root"] as? String, repo)
        XCTAssertEqual(discoveredProject["registered"] as? Bool, false)

        let noneRow = try row(none, in: sessions)
        XCTAssertNil(noneRow["project"], "outside every project the field is absent")
        XCTAssertEqual(noneRow["orchestrated"] as? Bool, false)

        // The single-session route shares the row builder.
        let (status, data) = try await request("GET", "/api/sessions/\(registered.uuidString)")
        XCTAssertEqual(status, 200)
        XCTAssertEqual((try json(data)["project"] as? [String: Any])?["id"] as? String, "alpha")
    }

    func testProjectLabelOverridesTheResolution() async throws {
        let labelled = try await spawnDirect(cwd: alpha, labels: ["project": "other"])
        let sessions = try await rows("/api/sessions", key: "sessions")
        let row = try row(labelled, in: sessions)
        XCTAssertEqual(row["orchestrated"] as? Bool, true, "a labelled session is orchestrated")
        let project = try XCTUnwrap(row["project"] as? [String: Any])
        XCTAssertEqual(project["id"] as? String, "other")
        XCTAssertEqual(project["registered"] as? Bool, false)
        XCTAssertEqual(project["root"] as? String, alpha, "the resolved root is kept")
    }

    // MARK: - filters

    func testSessionsFilterByProject() async throws {
        let inAlpha = try await spawnDirect(cwd: alpha)
        let inRepo = try await spawnDirect(cwd: repo)
        let labelled = try await spawnDirect(cwd: plain, labels: ["project": "alpha"])

        let alphaRows = try await rows("/api/sessions?project=alpha", key: "sessions")
        XCTAssertEqual(
            Set(alphaRows.compactMap { $0["id"] as? String }),
            [inAlpha.uuidString, labelled.uuidString],
            "the cwd resolution and the label both select alpha"
        )
        let repoRows = try await rows("/api/sessions?project=repo", key: "sessions")
        XCTAssertEqual(repoRows.compactMap { $0["id"] as? String }, [inRepo.uuidString])

        let unknown = try await rows("/api/sessions?project=nothing-here", key: "sessions")
        XCTAssertEqual(unknown.count, 0)

        let (status, data) = try await request("GET", "/api/sessions?project=Not%20An%20Id")
        XCTAssertEqual(status, 400, String(decoding: data, as: UTF8.self))
        XCTAssertEqual(try json(data)["ok"] as? Bool, false)
    }

    func testArchivesFilterByProjectAndCarryIt() async throws {
        let inAlpha = try await spawnDirect(cwd: alpha)
        let inRepo = try await spawnDirect(cwd: repo)
        for id in [inAlpha, inRepo] {
            let (status, _) = try await request("POST", "/api/sessions/\(id.uuidString)/archive")
            XCTAssertEqual(status, 200)
        }

        let all = try await rows("/api/archives", key: "archives")
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual((try row(inAlpha, in: all)["project"] as? [String: Any])?["id"] as? String, "alpha")
        XCTAssertEqual((try row(inRepo, in: all)["project"] as? [String: Any])?["registered"] as? Bool, false)

        let alphaOnly = try await rows("/api/archives?project=alpha", key: "archives")
        XCTAssertEqual(alphaOnly.compactMap { $0["id"] as? String }, [inAlpha.uuidString])
        let unknown = try await rows("/api/archives?project=nothing-here", key: "archives")
        XCTAssertEqual(unknown.count, 0)

        let (status, _) = try await request("GET", "/api/archives?project=bad/id")
        XCTAssertEqual(status, 400)
    }

    // MARK: - the project list

    /// Identity only: the page counts what it shows from the rows. The
    /// pinned fields are `id`, `name`, `root`, `registered`, `knowledge`.
    func testProjectsAggregate() async throws {
        _ = try await spawnDirect(cwd: alpha)
        _ = try await spawnOverAPI(cwd: alpha)
        _ = try await spawnDirect(cwd: repo)
        _ = try await spawnDirect(cwd: plain)
        let archived = try await spawnDirect(cwd: alpha)
        let (archiveStatus, _) = try await request("POST", "/api/sessions/\(archived.uuidString)/archive")
        XCTAssertEqual(archiveStatus, 200)

        let projects = try await rows("/api/projects", key: "projects")
        XCTAssertEqual(projects.compactMap { $0["id"] as? String }, ["alpha", "repo"], "sorted by name; no card for the plain directory")

        let alphaCard = try XCTUnwrap(projects.first { ($0["id"] as? String) == "alpha" })
        XCTAssertEqual(alphaCard["name"] as? String, "Alpha")
        XCTAssertEqual(alphaCard["root"] as? String, alpha)
        XCTAssertEqual(alphaCard["registered"] as? Bool, true)
        XCTAssertEqual(alphaCard["knowledge"] as? String, "docs/goals")
        XCTAssertEqual(Set(alphaCard.keys), ["id", "name", "root", "registered", "knowledge"], "identity only")

        let repoCard = try XCTUnwrap(projects.first { ($0["id"] as? String) == "repo" })
        XCTAssertEqual(repoCard["registered"] as? Bool, false)
        XCTAssertEqual(repoCard["root"] as? String, repo)
    }

    /// A registered project with nothing running still has a card.
    func testRegisteredProjectWithNoSessionsIsListed() async throws {
        let projects = try await rows("/api/projects", key: "projects")
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?["id"] as? String, "alpha")
    }

    // MARK: - the event loop

    /// No route and no poll takes the store's lock on an event loop: the
    /// rows carry their project from the actor, the registered list rides
    /// the actor hop, the archive walk runs on the archive queue, and the
    /// poll's resolution runs on the project queue. The store counts every
    /// lock take made on a NIO loop thread; the count must not move.
    func testTheEventLoopNeverCallsIntoTheProjectStore() async throws {
        let before = ProjectStore.shared.eventLoopCalls
        let labelled = try await spawnDirect(cwd: repo, labels: ["project": "alpha"])
        let moving = try await spawnOverAPI(cwd: plain)
        let live = await registry.session(moving)
        let session = try XCTUnwrap(live)
        session.attach(onOutput: { _ in }, onExit: { _ in }, onCwd: { _ in })
        try session.write(Data("cd \(alpha!)\n".utf8))
        try await wait("the poll to resolve the project") { session.project?.id == "alpha" }

        _ = try await rows("/api/sessions", key: "sessions")
        _ = try await rows("/api/sessions?project=alpha", key: "sessions")
        let (status, _) = try await request("GET", "/api/sessions/\(labelled.uuidString)")
        XCTAssertEqual(status, 200)
        _ = try await rows("/api/projects", key: "projects")
        let (archiveStatus, _) = try await request("POST", "/api/sessions/\(labelled.uuidString)/archive")
        XCTAssertEqual(archiveStatus, 200)
        _ = try await rows("/api/archives", key: "archives")
        _ = try await rows("/api/archives?project=alpha", key: "archives")
        _ = try await rows("/api/projects", key: "projects")

        XCTAssertEqual(ProjectStore.shared.eventLoopCalls, before, "a ProjectStore lock take ran on an event loop")
    }

    // MARK: - the cwd poll

    /// A `cd` into a project moves the session's project on the poll's next
    /// tick, with no listing in between.
    func testTheCwdPollResolvesTheProjectAgain() async throws {
        let id = try await spawnOverAPI(cwd: plain)
        let live = await registry.session(id)
        let session = try XCTUnwrap(live)
        XCTAssertNil(session.project, "nothing resolved before the first poll or listing")

        // A controller with a cwd callback is what starts the poll.
        session.attach(onOutput: { _ in }, onExit: { _ in }, onCwd: { _ in })
        try session.write(Data("cd \(alpha!)\n".utf8))
        try await wait("the poll to resolve the project") { session.project?.id == "alpha" }
        XCTAssertEqual(session.project?.registered, true)
    }
}
