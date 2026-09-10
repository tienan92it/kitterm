import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

@testable import KittermCLI

/// `send_input` presses a named key. A key cannot travel inside `text`: an
/// MCP client is free to strip a control character out of a JSON string
/// argument, and one that does turns the Down arrow into the two bytes `[B`,
/// while a client that leaves the byte raw makes the JSON-RPC line
/// unparseable and the call disappears in `MCPBridge.run`. Both were measured
/// on 2026-09-10 against `.build/debug/kitterm mcp`.
///
/// So these pin two things: the name maps to the bytes, and the bytes reach a
/// real pane.
final class MCPSendKeysTests: XCTestCase {
    private let session = "deadbeef-dead-beef-dead-beefdeadbeef"

    private func call(_ arguments: [String: Any]) throws -> MCPTools.Call {
        try MCPTools.call(named: "send_input", arguments: arguments)
    }

    private func body(_ call: MCPTools.Call) -> [UInt8] {
        Array(call.rawBody ?? Data())
    }

    // MARK: - mapping

    /// The escape sequence a foreman needs is three bytes, and it is the
    /// bridge that names them.
    func testEachKeyMapsToItsBytes() throws {
        let down = try call(["session": session, "keys": ["down"]])
        XCTAssertEqual(down.method, "POST")
        XCTAssertEqual(down.path, "/api/sessions/\(session)/input")
        XCTAssertEqual(body(down), [0x1b, 0x5b, 0x42])

        XCTAssertEqual(body(try call(["session": session, "keys": ["up"]])), [0x1b, 0x5b, 0x41])
        XCTAssertEqual(body(try call(["session": session, "keys": ["right"]])), [0x1b, 0x5b, 0x43])
        XCTAssertEqual(body(try call(["session": session, "keys": ["left"]])), [0x1b, 0x5b, 0x44])
        XCTAssertEqual(body(try call(["session": session, "keys": ["escape"]])), [0x1b])
        XCTAssertEqual(body(try call(["session": session, "keys": ["ctrl-c"]])), [0x03])
    }

    /// `enter` is the daemon's reader-aware press — a line feed for the
    /// shell, a settled carriage return for a program — so it travels as
    /// `?enter=1` and never as a byte the bridge picked.
    func testEnterIsTheDaemonsPressAndClosesTheSequence() throws {
        let enter = try call(["session": session, "keys": ["enter"]])
        XCTAssertEqual(enter.path, "/api/sessions/\(session)/input?enter=1")
        XCTAssertEqual(body(enter), [])

        let both = try call(["session": session, "keys": ["down", "enter"]])
        XCTAssertEqual(both.path, "/api/sessions/\(session)/input?enter=1")
        XCTAssertEqual(body(both), [0x1b, 0x5b, 0x42])

        XCTAssertThrowsError(try call(["session": session, "keys": ["enter", "down"]]))
    }

    func testKeysAreValidated() throws {
        XCTAssertThrowsError(try call(["session": session, "keys": ["pgdn"]]))
        XCTAssertThrowsError(try call(["session": session, "keys": []]))
        XCTAssertThrowsError(try call(["session": session, "keys": "down"]))
        // One or the other: a caller that sends both means one of them.
        XCTAssertThrowsError(try call(["session": session, "keys": ["down"], "text": "y"]))
        XCTAssertThrowsError(try call(["session": session]))
    }

    /// The other arguments keep their meaning: `force` still travels, and an
    /// explicit `enter:true` still presses Enter after the keys.
    func testKeysCarryForceAndAnExplicitEnter() throws {
        let forced = try call(["session": session, "keys": ["ctrl-c"], "force": true])
        XCTAssertEqual(forced.path, "/api/sessions/\(session)/input?force=1")
        let submitted = try call(["session": session, "keys": ["down"], "enter": true])
        XCTAssertEqual(submitted.path, "/api/sessions/\(session)/input?enter=1")
    }

    /// Every existing `text` caller is untouched: same paths, same bodies.
    func testTextIsUnchanged() throws {
        let run = try call(["session": session, "text": "ls"])
        XCTAssertEqual(run.path, "/api/sessions/\(session)/input?enter=1")
        XCTAssertEqual(run.rawBody, Data("ls".utf8))
        let raw = try call(["session": session, "text": "\u{03}", "enter": false])
        XCTAssertEqual(raw.path, "/api/sessions/\(session)/input")
        XCTAssertEqual(raw.rawBody, Data("\u{03}".utf8))
        let confirm = try call(["session": session, "text": ""])
        XCTAssertEqual(confirm.path, "/api/sessions/\(session)/input?enter=1")
        XCTAssertEqual(confirm.rawBody, Data())
    }

    /// The schema tells a foreman the key names and why `text` will not do.
    func testTheSchemaNamesTheKeys() throws {
        let schema = try XCTUnwrap(MCPTools.schemas().first { $0["name"] as? String == "send_input" })
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let keys = try XCTUnwrap((input["properties"] as? [String: Any])?["keys"] as? [String: Any])
        XCTAssertEqual(keys["type"] as? String, "array")
        XCTAssertEqual(
            (keys["items"] as? [String: Any])?["enum"] as? [String],
            ["up", "down", "left", "right", "enter", "escape", "ctrl-c"]
        )
        // `text` is no longer the only way in, so it is no longer required.
        XCTAssertEqual(input["required"] as? [String], ["session"])
        let description = try XCTUnwrap(schema["description"] as? String)
        XCTAssertTrue(description.contains("arrow key"))
        XCTAssertTrue(description.contains("`[B`"))
    }

    // MARK: - the pane

    /// The proof the capability asks for: the three bytes the bridge built
    /// for `keys:["down"]` reach a real pane, over the real route, read back
    /// from the session's own output.
    ///
    /// `cat -v` prints the escape byte as the two characters `^[`, so the
    /// four characters `^[[B` in the output can only come from a pane that
    /// received 0x1b, 0x5b, 0x42. A pane that received the stripped `[B`
    /// shows `[B` with no caret, which is what a foreman measured on
    /// 2026-09-09.
    func testTheDownArrowReachesThePane() async throws {
        let (id, pane) = try await spawn()

        // Wait for the program, not for any program: `foregroundIsShell` is
        // also true before anything has claimed the tty (facts.md, Daemon
        // and API).
        _ = try await post("/api/sessions/\(id)/input", Data("exec cat -v\n".utf8))
        try await wait("cat to take the terminal") { pane.foregroundProgram == "cat" }

        let call = try self.call(["session": id, "keys": ["down", "enter"]])
        XCTAssertEqual(Array(call.rawBody ?? Data()), [0x1b, 0x5b, 0x42])
        let response = try await post(call.path, try XCTUnwrap(call.rawBody))
        XCTAssertEqual(response.status, 200, response.body)

        // Twice: the tty echoes the keystroke, then `cat -v` prints the line
        // it read. Either one alone proves the escape byte arrived.
        try await wait("cat to print the escape sequence") {
            output(of: pane).components(separatedBy: "^[[B").count >= 3
        }
    }

    // MARK: - a real daemon on a real loop

    private var group: MultiThreadedEventLoopGroup!
    private var serverChannel: Channel!
    private var registry: SessionRegistry!
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: MCPSendKeysTests.self).bundleURL.deletingLastPathComponent()
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
        await registry?.terminateAll()
        try? serverChannel?.close().wait()
        try? await group?.shutdownGracefully()
    }

    private func post(_ path: String, _ body: Data) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// Spawn a shell through the API and return it once the shell itself
    /// holds the terminal — the spawn helper holds it first, under its own
    /// name (`InputEnterKeyTests.spawn`).
    private func spawn() async throws -> (id: String, session: PtySession) {
        let response = try await post(
            "/api/sessions", try JSONSerialization.data(withJSONObject: ["cwd": NSTemporaryDirectory()])
        )
        XCTAssertEqual(response.status, 201, response.body)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(json["id"] as? String)
        let registered = await registry.session(try XCTUnwrap(UUID(uuidString: id)))
        let session = try XCTUnwrap(registered)
        try await wait("the shell to take the terminal") {
            guard let leader = session.foregroundLeader, leader.group == session.pid,
                  let name = leader.name
            else { return false }
            return name != SpawnHelperPath.name
        }
        return (id, session)
    }

    private func output(of pane: PtySession) -> String {
        String(decoding: pane.outputRange(from: 0, to: .max, maxBytes: 1 << 20).data, as: UTF8.self)
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
