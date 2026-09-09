import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// A large body reaches a program in the foreground whole. The daemon writes
/// it in pieces of `PtySession.inputPieceBytes` with a pause between them,
/// because Claude Code drops every full read but the last of a paste that
/// arrives as fast as it can read it. The shell keeps its one-write contract,
/// which names the command a submitted line creates.
final class PacedInputTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var serverChannel: Channel!
    private var registry: SessionRegistry!
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: PacedInputTests.self)
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

    /// 8 KiB of numbered words, so a lost or reordered piece is visible.
    private static func body(bytes: Int) -> String {
        var text = ""
        var i = 0
        while text.utf8.count < bytes {
            text += "w\(i) "
            i += 1
        }
        return String(decoding: Data(text.utf8).prefix(bytes), as: UTF8.self)
    }

    // MARK: - tests

    /// 8 KiB through `typeLine` into a raw-mode reader that sleeps before its
    /// first read: every byte arrives, in order, in pieces.
    func testLargeBodyReachesASlowRawReaderWholeAndInOrder() async throws {
        let (id, session) = try await spawn()
        try await wait("the shell to hold the tty") { session.foregroundIsShell }
        // Raw mode with no echo, like an interactive claude; `cat -v` prints
        // what it reads, so the output ring is the proof of what arrived.
        _ = try await request(
            "POST", "/api/sessions/\(id)/input",
            raw: Data("stty raw -echo; sleep 2; exec cat -v\n".utf8)
        )
        // Wait for the condition the route checks, not for a proxy. A gate of
        // "some program other than the shell holds the terminal" opens while
        // `stty` is still running, or while any cooked program holds the tty,
        // and the route then refuses the body with 409 (measured on CI,
        // 2026-09-09: `"foregroundProgram":"stty"`; reproduced here by putting
        // a `sleep` before `stty`, which fails the old gate every time).
        try await wait("the reader to put the terminal in raw mode") {
            session.inputIsCanonical == false
        }

        let body = Self.body(bytes: 8192)
        let before = session.inputWrites
        let response = try await request(
            "POST", "/api/sessions/\(id)/input?enter=1", raw: Data(body.utf8)
        )
        XCTAssertEqual(response.status, 200, response.body)
        XCTAssertEqual(try json(response.body)["bytes"] as? Int, body.utf8.count + 1)
        let pieces = (body.utf8.count + PtySession.inputPieceBytes - 1) / PtySession.inputPieceBytes
        XCTAssertEqual(session.inputWrites - before, pieces + 1, "one write per piece, then Enter")

        // cat -v shows the carriage return as ^M after the last word.
        try await wait("cat to print the whole body", seconds: 20) {
            output(of: session).contains(body + "^M")
        }
    }

    /// A short shell command still goes in one write with its line feed, so
    /// the command it creates is named from the submission.
    func testShortShellCommandIsOneWrite() async throws {
        let (id, session) = try await spawn()
        try await wait("the shell to hold the tty") { session.foregroundIsShell }

        let marker = "kitterm-one-write-\(UInt32.random(in: 0..<UInt32.max))"
        let before = session.inputWrites
        let response = try await request(
            "POST", "/api/sessions/\(id)/input?enter=1", raw: Data("echo \(marker)".utf8)
        )
        XCTAssertEqual(response.status, 200, response.body)
        XCTAssertEqual(session.inputWrites - before, 1)
        try await wait("the command to run") {
            output(of: session).components(separatedBy: marker).count >= 3
        }
    }
}
