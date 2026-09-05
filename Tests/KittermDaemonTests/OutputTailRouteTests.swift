import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/sessions/<id>/output` hands a renderer outside the daemon the
/// two things it needs and nothing more: the raw ring tail and the pane's
/// size (ADR 0001). The daemon never interprets the bytes.
final class OutputTailRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var session: PtySession!
    private var id: UUID!
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: OutputTailRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUp() async throws {
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
                            agentControl: false,
                            staticRoot: nil
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
        session = try PtySession.spawn(cols: 100, rows: 30, cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        let registered = await registry.register(session)
        id = try XCTUnwrap(registered)
    }

    override func tearDown() async throws {
        session?.terminate()
        try? channel.close().wait()
        try? await group.shutdownGracefully()
    }

    /// Output as the PTY reader would deliver it, without a shell's timing.
    private func feed(_ text: String) {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        session.handleRead(&buffer)
    }

    private func get(_ path: String) async throws -> (status: Int, headers: [String: String], body: Data) {
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port!)\(path)")!
        )
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return (http.statusCode, headers, data)
    }

    func testTailCarriesTheBytesAndThePaneSize() async throws {
        feed("hello \u{1b}[2mghost\u{1b}[22m\r\n")
        let (status, headers, body) = try await get("/api/sessions/\(id.uuidString)/output")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(headers["content-type"], "application/octet-stream")
        XCTAssertEqual(headers["x-kitterm-cols"], "100")
        XCTAssertEqual(headers["x-kitterm-rows"], "30")
        // Raw: the escape is still there, because the daemon does not render.
        XCTAssertTrue(body.range(of: Data("\u{1b}[2mghost".utf8)) != nil)
        let start = try XCTUnwrap(headers["x-kitterm-start"].flatMap { UInt64($0) })
        let head = try XCTUnwrap(headers["x-kitterm-head"].flatMap { UInt64($0) })
        XCTAssertEqual(head, start + UInt64(body.count))
        XCTAssertEqual(head, session.logHead)
    }

    func testTailIsBoundedAndReportsWhereItStarts() async throws {
        feed(String(repeating: "a", count: 1000))
        feed("END")
        let (status, headers, body) = try await get("/api/sessions/\(id.uuidString)/output?tail=100")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body.count, 100)
        XCTAssertEqual(body.suffix(3), Data("END".utf8))
        XCTAssertEqual(headers["x-kitterm-start"], "\(session.logHead - 100)")
        // Past the cap, the cap wins; below one, one.
        let (capped, _, cappedBody) = try await get("/api/sessions/\(id.uuidString)/output?tail=999999999")
        XCTAssertEqual(capped, 200)
        XCTAssertLessThanOrEqual(cappedBody.count, KittermConstants.apiCommandOutputMaxBytes)
        let (_, _, one) = try await get("/api/sessions/\(id.uuidString)/output?tail=0")
        XCTAssertEqual(one.count, 1)
    }

    func testSizeFollowsAResize() async throws {
        try session.resize(cols: 80, rows: 24)
        let (_, headers, _) = try await get("/api/sessions/\(id.uuidString)/output")
        XCTAssertEqual(headers["x-kitterm-cols"], "80")
        XCTAssertEqual(headers["x-kitterm-rows"], "24")

        let (status, _, row) = try await get("/api/sessions/\(id.uuidString)")
        XCTAssertEqual(status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: row) as? [String: Any])
        XCTAssertEqual(json["cols"] as? Int, 80)
        XCTAssertEqual(json["rows"] as? Int, 24)
    }

    func testUnknownSessionIs404AndTheCommandRouteIsUntouched() async throws {
        let (missing, _, _) = try await get("/api/sessions/\(UUID().uuidString)/output")
        XCTAssertEqual(missing, 404)
        let (malformed, _, _) = try await get("/api/sessions/not-a-uuid/output")
        XCTAssertEqual(malformed, 404)
        // A command with no marks is "no such command", not the session tail.
        let (command, _, _) = try await get("/api/sessions/\(id.uuidString)/commands/1/output")
        XCTAssertEqual(command, 404)
    }
}
