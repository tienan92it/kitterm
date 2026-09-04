import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// Archiving a session: its evidence lands on disk, it leaves the live
/// registry, and the archive reads back — while kitterm never pretends to
/// restore the process.
final class ArchiveRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var session: PtySession!
    private var port: Int!
    private var stateDir: URL!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: ArchiveRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        // A scratch state dir so the archive lands somewhere disposable.
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)

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
        session?.terminate()
        try? channel.close().wait()
        try? await group.shutdownGracefully()
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func registerSession() async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        self.session = session
        let id = await registry.register(session)
        return try XCTUnwrap(id)
    }

    private func request(_ method: String, _ path: String) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Archive a session: 200, it leaves the registry, and it reads back from
    /// the archive list and detail.
    func testArchiveRemovesFromRegistryAndPersists() async throws {
        let id = try await registerSession()
        // Feed a finished command so there is evidence worth keeping.
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeString("\u{1b}]633;E;make\u{07}\u{1b}]133;C\u{07}out\u{1b}]133;D;0\u{07}")
        session.handleRead(&buffer)

        let (status, body) = try await request("POST", "/api/sessions/\(id.uuidString)/archive")
        XCTAssertEqual(status, 200, String(decoding: body, as: UTF8.self))
        XCTAssertEqual(try json(body)["id"] as? String, id.uuidString)

        // Gone from the live registry.
        let live = await registry.session(id)
        XCTAssertNil(live, "an archived session leaves the registry")

        // Present in the archive listing.
        let (listStatus, listBody) = try await request("GET", "/api/archives")
        XCTAssertEqual(listStatus, 200)
        let archives = try XCTUnwrap(try json(listBody)["archives"] as? [[String: Any]])
        XCTAssertTrue(archives.contains { ($0["id"] as? String) == id.uuidString })

        // Detail carries the command evidence.
        let (detailStatus, detailBody) = try await request("GET", "/api/archives/\(id.uuidString)")
        XCTAssertEqual(detailStatus, 200)
        let detail = try json(detailBody)
        XCTAssertEqual(detail["version"] as? Int, SessionArchive.formatVersion)
        let commands = try XCTUnwrap(detail["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.first?["command"] as? String, "make")
    }

    /// Archiving is destructive, so it needs `--agent-control` like DELETE.
    func testArchiveRefusedWithoutAgentControl() async throws {
        let readOnly = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [registry] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry!, policy: .loopbackOnly,
                            agentControl: false, staticRoot: nil
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? readOnly.close().wait() }
        let roPort = try XCTUnwrap(readOnly.localAddress?.port)
        let id = try await registerSession()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(roPort)/api/sessions/\(id.uuidString)/archive")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)

        // And the session is still live.
        let live = await registry.session(id)
        XCTAssertNotNil(live)
    }

    func testArchiveOfUnknownSessionIs404() async throws {
        let (status, _) = try await request("POST", "/api/sessions/\(UUID().uuidString)/archive")
        XCTAssertEqual(status, 404)
    }

    func testDeleteArchiveRemovesIt() async throws {
        let id = try await registerSession()
        _ = try await request("POST", "/api/sessions/\(id.uuidString)/archive")

        let (delStatus, _) = try await request("DELETE", "/api/archives/\(id.uuidString)")
        XCTAssertEqual(delStatus, 200)
        let (detailStatus, _) = try await request("GET", "/api/archives/\(id.uuidString)")
        XCTAssertEqual(detailStatus, 404, "a deleted archive is gone")
    }
}
