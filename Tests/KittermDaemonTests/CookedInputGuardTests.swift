import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `POST /api/sessions/<id>/input` refuses a body over
/// `PtySession.canonicalLineBytes` while the terminal is in canonical mode
/// (ADR 0003). The kernel cuts a cooked line there, so a `sleep`, a program
/// still starting, or a shell in a here-doc would lose the rest and the
/// daemon could not see it. The same body types whole once the program
/// takes raw mode, a short body always types, and `?force=1` overrides the
/// guard. Same real-loop harness as `PacedInputTests`.
final class CookedInputGuardTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var serverChannel: Channel!
    private var registry: SessionRegistry!
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: CookedInputGuardTests.self)
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
        _ method: String, _ path: String, raw body: Data
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func json(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

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
        _ what: String, seconds: Int = 10, file: StaticString = #filePath, line: UInt = #line,
        until condition: () -> Bool
    ) async throws {
        for _ in 0..<(seconds * 20) {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// The spawned pid under a shell's name holds the terminal: not the
    /// helper that is about to exec it, and not no group yet (see
    /// `InputEnterKeyTests.spawn`).
    private func waitForShell(_ session: PtySession) async throws {
        try await wait("the shell to take the terminal") {
            guard let leader = session.foregroundLeader, leader.group == session.pid,
                  let name = leader.name
            else { return false }
            return name != SpawnHelperPath.name
        }
    }

    /// Numbered words, so a lost or reordered piece is visible.
    private static func body(bytes: Int) -> String {
        var text = ""
        var i = 0
        while text.utf8.count < bytes {
            text += "w\(i) "
            i += 1
        }
        return String(decoding: Data(text.utf8).prefix(bytes), as: UTF8.self)
    }

    /// Twice what a cooked line keeps: over the guard on either platform.
    private static var largeBody: String { body(bytes: 2 * PtySession.canonicalLineBytes) }

    /// A shell at its prompt, then `sleep` in the foreground: a cooked reader
    /// that reads nothing.
    private func spawnWithSleep() async throws -> (id: String, session: PtySession) {
        let (id, session) = try await spawn()
        try await waitForShell(session)
        _ = try await request("POST", "/api/sessions/\(id)/input", raw: Data("sleep 5\n".utf8))
        try await wait("sleep to take the foreground") { session.foregroundProgram == "sleep" }
        XCTAssertEqual(session.inputIsCanonical, true, "a sleep leaves the shell's cooked mode in place")
        return (id, session)
    }

    // MARK: - tests

    /// A body over the limit into `sleep` answers 409 with the reason, and
    /// the daemon writes nothing to the pty.
    func testLargeBodyIntoACookedReaderIsRefusedAndNothingIsTyped() async throws {
        let (id, session) = try await spawnWithSleep()
        let body = Self.largeBody
        let before = session.inputWrites

        let response = try await request(
            "POST", "/api/sessions/\(id)/input?enter=1", raw: Data(body.utf8)
        )
        XCTAssertEqual(response.status, 409, response.body)
        let fields = try json(response.body)
        XCTAssertEqual(fields["ok"] as? Bool, false)
        XCTAssertEqual(fields["reason"] as? String, "cooked")
        XCTAssertEqual(fields["foregroundProgram"] as? String, "sleep")
        XCTAssertEqual(fields["limit"] as? Int, PtySession.canonicalLineBytes)
        XCTAssertEqual(fields["bytes"] as? Int, body.utf8.count)
        let error = try XCTUnwrap(fields["error"] as? String)
        XCTAssertTrue(error.contains("cooked reader"), error)
        XCTAssertTrue(error.contains("`sleep`"), error)
        XCTAssertTrue(error.contains("\(PtySession.canonicalLineBytes) bytes"), error)
        XCTAssertTrue(error.contains("force"), error)
        XCTAssertEqual(session.inputWrites, before, "nothing typed")

        // Without Enter the verdict is the same.
        let keys = try await request("POST", "/api/sessions/\(id)/input", raw: Data(body.utf8))
        XCTAssertEqual(keys.status, 409, keys.body)
        XCTAssertEqual(session.inputWrites, before, "nothing typed")
    }

    /// The same body types whole once the program takes raw mode: `cat -v`
    /// prints every word and the Enter as `^M`.
    func testLargeBodyTypesWholeAfterTheProgramTakesRawMode() async throws {
        let (id, session) = try await spawn()
        try await waitForShell(session)
        _ = try await request(
            "POST", "/api/sessions/\(id)/input",
            raw: Data("stty raw -echo; exec cat -v\n".utf8)
        )
        try await wait("cat to take the foreground in raw mode") {
            session.foregroundProgram == "cat" && session.inputIsCanonical == false
        }

        let body = Self.largeBody
        let response = try await request(
            "POST", "/api/sessions/\(id)/input?enter=1", raw: Data(body.utf8)
        )
        XCTAssertEqual(response.status, 200, response.body)
        XCTAssertEqual(try json(response.body)["bytes"] as? Int, body.utf8.count + 1)
        try await wait("cat to print the whole body", seconds: 20) {
            output(of: session).contains(body + "^M")
        }
    }

    /// A short body into a cooked reader still types: `cat` in cooked mode
    /// gets the line with the Enter as a newline (ICRNL) and prints it.
    func testShortBodyIntoACookedReaderStillTypes() async throws {
        let (id, session) = try await spawn()
        try await waitForShell(session)
        _ = try await request("POST", "/api/sessions/\(id)/input", raw: Data("exec cat\n".utf8))
        try await wait("cat to take the foreground") { session.foregroundProgram == "cat" }
        XCTAssertEqual(session.inputIsCanonical, true)

        let marker = "kitterm-cooked-\(UInt32.random(in: 0..<UInt32.max))"
        let response = try await request(
            "POST", "/api/sessions/\(id)/input?enter=1", raw: Data(marker.utf8)
        )
        XCTAssertEqual(response.status, 200, response.body)
        // The tty echoes the line and cat prints it: two copies.
        try await wait("cat to print the line") {
            output(of: session).components(separatedBy: marker + "\r\n").count >= 3
        }
    }

    /// `?force=1` types the large body into the cooked reader anyway, in
    /// paced pieces like any program.
    func testForceTypesALargeBodyIntoACookedReader() async throws {
        let (id, session) = try await spawnWithSleep()
        let body = Self.largeBody
        let before = session.inputWrites

        let response = try await request(
            "POST", "/api/sessions/\(id)/input?enter=1&force=1", raw: Data(body.utf8)
        )
        XCTAssertEqual(response.status, 200, response.body)
        XCTAssertEqual(try json(response.body)["bytes"] as? Int, body.utf8.count + 1)
        let pieces = (body.utf8.count + PtySession.inputPieceBytes - 1) / PtySession.inputPieceBytes
        XCTAssertEqual(session.inputWrites - before, pieces + 1, "one write per piece, then Enter")
    }

    /// The mode is read from the pty, so a session that has gone answers nil
    /// and the guard stands aside.
    func testCanonicalModeIsUnknownForATerminatedSession() async throws {
        let (_, session) = try await spawn()
        XCTAssertNotNil(session.inputIsCanonical)
        session.terminate()
        XCTAssertNil(session.inputIsCanonical)
    }
}
