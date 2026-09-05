import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// The regression the foreman hit: typing a prompt into an interactive
/// `claude` with a trailing line feed left it sitting in the input box, never
/// submitted. `?enter=1` presses the key claude reads — a carriage return —
/// and the proof is claude's own transcript gaining a user turn.
///
/// This drives the real `claude` binary in a scratch directory under the
/// repository's `.build/` (a trusted parent, so no trust dialog), so it needs
/// a logged-in Claude Code on PATH and makes one short, real turn. Without
/// `claude` it skips.
final class ClaudePromptSubmitTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var serverChannel: Channel!
    private var registry: SessionRegistry!
    private var port: Int!

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let scratch = repoRoot
        .appendingPathComponent(".build/claude-scratch/prompt-submit").path

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: ClaudePromptSubmitTests.self)
            .bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.claudeOnPath(), "claude is not on PATH")
        try FileManager.default.createDirectory(
            atPath: Self.scratch, withIntermediateDirectories: true
        )
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
        guard registry != nil else { return }
        await registry.terminateAll()
        try? serverChannel.close().wait()
        try? await group.shutdownGracefully()
    }

    // MARK: - helpers

    private static func claudeOnPath() -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { dir in
            FileManager.default.isExecutableFile(atPath: "\(dir)/claude")
        }
    }

    /// Where claude writes this scratch directory's transcripts: one file per
    /// session under `<config>/projects/<cwd with every non-alphanumeric
    /// character as "-">`.
    private static var transcriptDir: String {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let slug = String(scratch.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return "\(config)/projects/\(slug)"
    }

    private static func transcripts() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: transcriptDir)) ?? []
        return Set(files.filter { $0.hasSuffix(".jsonl") }.map { "\(transcriptDir)/\($0)" })
    }

    /// The user turns in a transcript, as their text content.
    private static func userTurns(in file: String) -> [String] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any]
            else { return nil }
            if let content = message["content"] as? String { return content }
            // A tool result is also a user turn; keep its shape out of the way.
            return (message["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.joined()
        }
    }

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

    private func output(of session: PtySession) -> String {
        String(decoding: session.outputRange(from: 0, to: .max, maxBytes: 4 << 20).data, as: UTF8.self)
    }

    /// Poll for up to `seconds`; nil when the condition never held.
    private func wait<T>(seconds: Int, for read: () -> T?) async throws -> T? {
        for _ in 0..<(seconds * 10) {
            if let value = read() { return value }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return nil
    }

    // MARK: - the test

    func testEnterSubmitsAPromptToAnInteractiveClaude() async throws {
        let before = Self.transcripts()
        // Leave no trace of this run in the user's transcripts, whatever the
        // outcome: end claude, let it finish writing on its SIGHUP, then drop
        // the files it wrote.
        let registry = self.registry!
        nonisolated(unsafe) var shellPid: pid_t = 0
        addTeardownBlock {
            await registry.terminateAll()
            for _ in 0..<50 where shellPid > 0 && kill(shellPid, 0) == 0 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            for file in Self.transcripts().subtracting(before) {
                try? FileManager.default.removeItem(atPath: file)
            }
        }

        // The shell strips the marks a parent Claude Code leaves in the
        // environment (a child session saves no transcript), then becomes
        // claude in place — the pid stays the shell's, which is exactly the
        // case a pid comparison would get wrong.
        let launch = "for v in $(env | sed -n 's/^\\(CLAUDE[A-Z_]*\\)=.*/\\1/p'); do unset \"$v\"; done; "
            + "exec claude\n"
        let spawned = try await request(
            "POST", "/api/sessions",
            raw: try JSONSerialization.data(withJSONObject: ["cwd": Self.scratch, "input": launch])
        )
        XCTAssertEqual(spawned.status, 201, spawned.body)
        let created = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(spawned.body.utf8)) as? [String: Any]
        )
        let id = try XCTUnwrap(created["id"] as? String)
        let registered = await registry.session(try XCTUnwrap(UUID(uuidString: id)))
        let session = try XCTUnwrap(registered)
        shellPid = session.pid

        // Claude has the terminal once its prompt marker is on screen and the
        // shell is no longer the reader; a short settle lets its first paint
        // finish before anything is typed.
        let ready = try await wait(seconds: 45) { () -> Bool? in
            let screen = output(of: session)
            if screen.contains("trust this folder") { return false }
            if screen.contains("Not logged in") { return false }
            return screen.contains("\u{276F}") && !session.foregroundIsShell ? true : nil
        }
        if ready == true { try await Task.sleep(nanoseconds: 2_000_000_000) }
        guard ready == true else {
            let screen = output(of: session)
            if screen.contains("trust this folder") {
                throw XCTSkip("claude asks to trust \(Self.scratch); run claude in the repository once")
            }
            if screen.contains("Not logged in") {
                throw XCTSkip("claude is not logged in")
            }
            return XCTFail("claude never reached its prompt; screen: \(screen.suffix(2000))")
        }
        XCTAssertFalse(session.foregroundIsShell, "claude, not the shell, is reading the terminal")

        let marker = "kitterm-submit-\(UInt32.random(in: 0..<UInt32.max))"
        let prompt = "Reply with only the word ok. Do not use any tool. Reference: \(marker)"
        let typed = try await request("POST", "/api/sessions/\(id)/input?enter=1", raw: Data(prompt.utf8))
        XCTAssertEqual(typed.status, 200, typed.body)

        // The proof: claude's own transcript records the prompt as a user turn.
        let turn = try await wait(seconds: 45) { () -> String? in
            for file in Self.transcripts().subtracting(before) {
                if let hit = Self.userTurns(in: file).first(where: { $0.contains(marker) }) {
                    return hit
                }
            }
            return nil
        }
        XCTAssertEqual(
            turn, prompt,
            "the prompt was never submitted; screen: \(output(of: session).suffix(2000))"
        )
    }
}
