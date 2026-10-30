import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// A client that joins a running session gets the foreground program's own
/// repaint (ADR 0006, `observer-repaint` round 1): after the replay, the
/// daemon writes the window size one row short and then restores it, so
/// the program gets two `SIGWINCH` and paints its full screen twice, the
/// second time at the size the controller holds. A shell at its prompt gets
/// no nudge: its replay holds the scrollback, and a prompt needs no repaint.
///
/// The program here is `perl`, which prints `WINCH <rows> <cols>` on each
/// signal: the mechanism is proven by what the program saw, with no screen
/// model and no real `claude`. The whole daemon runs in process on port 0
/// under a scratch state directory, and the second client is a plain
/// WebSocket, so the attach path is the real one.
final class RepaintNudgeTests: XCTestCase {
    private var stateDir: URL!
    private var server: DaemonServer!
    private var port = 0

    override class func setUp() {
        super.setUp()
        // The spawn helper is built beside the test bundle, not on PATH.
        let buildDir = Bundle(for: RepaintNudgeTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-repaint-nudge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        server = DaemonServer(config: DaemonConfig(port: 0, agentControl: true))
        try server.start()
        port = try XCTUnwrap(server.boundPort)
    }

    override func tearDownWithError() throws {
        try? server?.stop()
        server = nil
        unsetenv("KITTERM_STATE_DIR")
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    // MARK: - Cases

    /// The reported case: a full-screen program holds the terminal, and a
    /// fresh client joins. The program sees the shrunk size, then the held
    /// size, and the session's own size never moves.
    func testAttachToAProgramNudgesTheSizeAndRestoresIt() async throws {
        let id = try await spawn(input: Self.perlReporter)
        try await wait("perl to take the terminal") {
            try await self.row(id)["foregroundProgram"] as? String == "perl"
        }
        let before = try await output(id)
        XCTAssertEqual(Self.winchReports(in: before), [], "no nudge before a client attaches")

        let client = PaneClient(port: port)
        defer { client.close() }
        client.connect(session: id, fresh: true)

        try await wait("the program to report the shrunk size and the restored size") {
            try await self.output(id).contains("WINCH 32 120")
        }
        let after = try await output(id)
        let reports = Self.winchReports(in: after)
        XCTAssertEqual(reports, ["31 120", "32 120"], "one row short, then the held size: \(after)")

        let row = try await row(id)
        XCTAssertEqual(row["cols"] as? Int, 120, "the held size never moved")
        XCTAssertEqual(row["rows"] as? Int, 32, "the held size never moved")
    }

    /// Completion condition 3: a shell at its prompt keeps its replay and
    /// gets no `SIGWINCH`. The shell's own `WINCH` trap would print if one
    /// arrived (`/bin/sh` runs a trap at its prompt; measured 2026-10-30).
    func testAttachToAShellAtItsPromptDoesNotNudge() async throws {
        let id = try await spawn(input: "trap 'echo WINCH' WINCH; echo armed\n")
        try await wait("the trap to be armed") { try await self.output(id).contains("armed\r\n") }
        try await wait("the shell to take the terminal back") {
            try await self.row(id)["foregroundProgram"] == nil
        }

        let client = PaneClient(port: port)
        defer { client.close() }
        client.connect(session: id, fresh: true)
        try await wait("the replay to reach the client") { client.received.contains("armed") }

        // The nudge, had it run, would print within the restore delay; a
        // whole second is twenty times that.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let after = try await output(id)
        XCTAssertFalse(
            after.replacingOccurrences(of: "trap 'echo WINCH' WINCH", with: "").contains("WINCH"),
            "a shell at its prompt got a SIGWINCH: \(after)"
        )
    }

    /// Two clients joining in one window: the second shrink lands on a
    /// window already a row short, so the program sees one size, then the
    /// held size, and the held size is what stands at the end.
    func testTwoAttachesInOneWindowStillEndAtTheHeldSize() async throws {
        let id = try await spawn(input: Self.perlReporter)
        try await wait("perl to take the terminal") {
            try await self.row(id)["foregroundProgram"] as? String == "perl"
        }

        let first = PaneClient(port: port)
        let second = PaneClient(port: port)
        defer {
            first.close()
            second.close()
        }
        first.connect(session: id, fresh: true)
        second.connect(session: id, fresh: true)

        try await wait("both restores to land") {
            Self.winchReports(in: try await self.output(id)).last == "32 120"
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let reports = Self.winchReports(in: try await output(id))
        XCTAssertEqual(reports.last, "32 120", "the held size stands: \(reports)")
        XCTAssertFalse(reports.dropLast().isEmpty, "at least one shrink was reported: \(reports)")
        XCTAssertTrue(reports.allSatisfy { $0 == "31 120" || $0 == "32 120" }, reports.description)
    }

    // MARK: - Helpers

    /// `exec` keeps the shell's pid; the name is what `foregroundProgram`
    /// reads (ADR 0004). `stty size` reads the pty, so each line is the
    /// size the kernel held when the signal arrived.
    private static let perlReporter =
        "exec perl -e '$| = 1; $SIG{WINCH} = sub { print \"WINCH \", scalar(`stty size`) }; sleep 1 while 1'\n"

    private static func winchReports(in output: String) -> [String] {
        output.components(separatedBy: "WINCH ").dropFirst().compactMap { piece in
            // `\r\n` is one Character in Swift; `isNewline` covers it.
            let line = piece.prefix { !$0.isNewline }
            let words = line.split(separator: " ")
            guard words.count == 2, UInt16(words[0]) != nil, UInt16(words[1]) != nil else { return nil }
            return "\(words[0]) \(words[1])"
        }
    }

    private func request(
        _ method: String, _ path: String, body: Data? = nil
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func spawn(input: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "cwd": NSTemporaryDirectory(), "cols": 120, "rows": 32, "input": input,
        ])
        let response = try await request("POST", "/api/sessions", body: body)
        XCTAssertEqual(response.status, 201, String(decoding: response.body, as: UTF8.self))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return try XCTUnwrap(fields["id"] as? String)
    }

    private func row(_ id: String) async throws -> [String: Any] {
        let response = try await request("GET", "/api/sessions/\(id)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func output(_ id: String) async throws -> String {
        let response = try await request("GET", "/api/sessions/\(id)/output?tail=65536")
        return String(decoding: response.body, as: UTF8.self)
    }

    private func wait(
        _ what: String, seconds: Int = 10, file: StaticString = #filePath, line: UInt = #line,
        until condition: () async throws -> Bool
    ) async throws {
        for _ in 0..<(seconds * 20) {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }
}

/// A pane: one WebSocket on `/ws`, keeping the output it was sent.
private final class PaneClient: @unchecked Sendable {
    private let port: Int
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var buffer = Data()

    init(port: Int) {
        self.port = port
    }

    var received: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }

    func connect(session id: String, fresh: Bool) {
        let query = "session=\(id)" + (fresh ? "&fresh=1" : "")
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws?\(query)")!)
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receiveNext(task)
    }

    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, case .success(let message) = result else { return }
            if case .data(let data) = message, let frame = try? ServerFrame.decode(data),
               case .output(let bytes) = frame
            {
                self.lock.withLock { self.buffer.append(bytes) }
            }
            self.receiveNext(task)
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }
}
