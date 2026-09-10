import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// Corpus request 02 of the `foreman-harness` goal, over the API: a session
/// whose cwd is a git checkout under a registered parent belongs to the
/// checkout, and the parent keeps the session that no checkout owns.
final class NestedCheckoutTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var sessions: [PtySession] = []
    private var port: Int!
    private var stateDir: URL!
    private var work: String!
    private var app: String!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: NestedCheckoutTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        // Created first, then made real: the kernel reports a shell's cwd as
        // `/private/var/…`, and the rows must compare equal to it.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-nested-checkout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.path), isDirectory: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        work = try dir("work")
        app = try dir("work/app")
        _ = try dir("work/app/.git")
        try ProjectStore.save([Project(id: "work", name: "Work", root: work)])

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

    func testACheckoutUnderARegisteredParentIsItsOwnProject() async throws {
        let inApp = try await spawn(cwd: app)
        let inWork = try await spawn(cwd: work)

        let sessionRows = try await rows("/api/sessions", key: "sessions")
        let appProject = try XCTUnwrap(try row(inApp, in: sessionRows)["project"] as? [String: Any])
        XCTAssertEqual(appProject["id"] as? String, "app")
        XCTAssertEqual(appProject["root"] as? String, app)
        XCTAssertEqual(appProject["registered"] as? Bool, false)

        let workProject = try XCTUnwrap(try row(inWork, in: sessionRows)["project"] as? [String: Any])
        XCTAssertEqual(workProject["id"] as? String, "work")
        XCTAssertEqual(workProject["name"] as? String, "Work")
        XCTAssertEqual(workProject["registered"] as? Bool, true)

        let projects = try await rows("/api/projects", key: "projects")
        XCTAssertEqual(projects.compactMap { $0["id"] as? String }, ["app", "work"], "both projects are listed")

        // The registration is a name for one root; nothing writes the file.
        XCTAssertEqual(
            ProjectStore.load(from: DaemonPaths.projectsFile),
            [Project(id: "work", name: "Work", root: work)]
        )
    }

    // MARK: - helpers

    private func dir(_ path: String) throws -> String {
        let url = stateDir.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func spawn(cwd: String) async throws -> UUID {
        let session = try PtySession.spawn(cwd: cwd, labels: SessionLabels([:]))
        sessions.append(session)
        let id = await registry.register(session)
        // Until the shell holds the terminal: before that the kernel reports
        // the spawn helper, whose cwd is still this process's.
        try await wait("the shell to start in \(cwd)") {
            guard let leader = session.foregroundLeader, leader.group == session.pid, let name = leader.name
            else { return false }
            return name != SpawnHelperPath.name && session.liveCwd == cwd
        }
        return try XCTUnwrap(id)
    }

    private func rows(_ path: String, key: String) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(body[key] as? [[String: Any]])
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
}
