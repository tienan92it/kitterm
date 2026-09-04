import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `POST /api/sessions/<id>/input?enter=1` presses Enter with the key the
/// session's foreground reads: a line feed for the shell, a settled carriage
/// return for a program that took the terminal. Same real-loop harness as
/// `SessionSpawnRouteTests` — the registry is an actor.
final class InputEnterKeyTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var serverChannel: Channel!
    private var registry: SessionRegistry!
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: InputEnterKeyTests.self)
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

    override func tearDown() async throws {
        await registry.terminateAll()
        try? serverChannel.close().wait()
        try? await group.shutdownGracefully()
    }

    // MARK: - helpers

    private func request(
        _ method: String, _ path: String, raw body: Data? = nil
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func json(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    /// Spawn a shell through the API and return its session.
    private func spawn() async throws -> (id: String, session: PtySession) {
        let response = try await request(
            "POST", "/api/sessions",
            raw: try JSONSerialization.data(withJSONObject: ["cwd": NSTemporaryDirectory()])
        )
        XCTAssertEqual(response.status, 201, response.body)
        let id = try XCTUnwrap(json(response.body)["id"] as? String)
        let registered = await registry.session(try XCTUnwrap(UUID(uuidString: id)))
        return (id, try XCTUnwrap(registered))
    }

    private func output(of session: PtySession) -> String {
        String(decoding: session.outputRange(from: 0, to: .max, maxBytes: 1 << 20).data, as: UTF8.self)
    }

    private func wait(
        _ what: String, file: StaticString = #filePath, line: UInt = #line,
        until condition: () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    // MARK: - tests

    /// The shell case keeps its contract: Enter is a line feed, the line
    /// runs, and the command it creates is named from the submission.
    func testEnterOnAShellIsALineFeedThatRunsTheCommand() async throws {
        let (id, session) = try await spawn()
        XCTAssertTrue(session.foregroundIsShell)

        let marker = "kitterm-enter-\(UInt32.random(in: 0..<UInt32.max))"
        let response = try await request(
            "POST", "/api/sessions/\(id)/input?enter=1", raw: Data("echo \(marker)".utf8)
        )
        XCTAssertEqual(response.status, 200, response.body)
        XCTAssertEqual(try json(response.body)["bytes"] as? Int, "echo \(marker)".utf8.count + 1)
        // The echo of the typed line, then the command's own output.
        try await wait("the command to run") {
            output(of: session).components(separatedBy: marker).count >= 3
        }
    }

    /// A program in the foreground reads raw keys, so Enter is a carriage
    /// return — and the tty still hands a cooked-mode reader a newline.
    func testEnterOnAForegroundProgramIsACarriageReturn() async throws {
        let (id, session) = try await spawn()
        _ = try await request("POST", "/api/sessions/\(id)/input", raw: Data("cat\n".utf8))
        try await wait("cat to take the foreground") { !session.foregroundIsShell }

        let marker = "kitterm-cr-\(UInt32.random(in: 0..<UInt32.max))"
        let response = try await request(
            "POST", "/api/sessions/\(id)/input?enter=1", raw: Data(marker.utf8)
        )
        XCTAssertEqual(response.status, 200, response.body)
        XCTAssertEqual(try json(response.body)["bytes"] as? Int, marker.utf8.count + 1)
        // cat reads the line (ICRNL turned the \r into \n) and echoes it back.
        try await wait("cat to echo the line") {
            output(of: session).components(separatedBy: marker).count >= 3
        }

        _ = try await request("POST", "/api/sessions/\(id)/input", raw: Data("\u{04}".utf8))
        try await wait("the shell to take the foreground back") { session.foregroundIsShell }
    }

    /// Enter alone is a legitimate keystroke — it answers a dialog — so the
    /// empty-body guard yields to it.
    func testEnterAloneIsAccepted() async throws {
        let (id, _) = try await spawn()
        let bare = try await request("POST", "/api/sessions/\(id)/input", raw: Data())
        XCTAssertEqual(bare.status, 400, bare.body)
        let enter = try await request("POST", "/api/sessions/\(id)/input?enter=1", raw: Data())
        XCTAssertEqual(enter.status, 200, enter.body)
        XCTAssertEqual(try json(enter.body)["bytes"] as? Int, 1)
    }
}
