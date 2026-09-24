import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// The three configurations of `docs/goals/proxy-is-a-boundary/goal.md`,
/// measured against a real `kitterm serve` over a real socket.
///
/// A reverse proxy (`tailscale serve`) connects from loopback and forwards
/// the original `Host`. `AccessPolicy.decide` reads the peer as the local
/// human unless the `Host` names a `--trusted-host`, so the flags decide
/// whether the proxy is a boundary or a bypass. Each test starts the daemon
/// with the exact flags of the goal's table and sends `GET /api/sessions`
/// with no token, once with a public `Host` (what the proxy forwards) and
/// once with a loopback `Host` (what the local human sends). The difference
/// between the two requests is what `viaTrustedHost` turns on.
///
/// No `Origin` header is needed to reach any branch: `Host` alone decides.
/// The unsafe configuration gets one extra request with a cross-origin
/// `Origin` because that branch skips the origin check as well.
///
/// The requests are hand-written HTTP/1.1 over a POSIX socket because
/// `URLSession` overwrites the `Host` header. Every assertion pins the
/// status and the exact body, and the grade is read back from two routes
/// that answer by grade: `GET /api/profiles` (403 `watch-only token` below
/// full) and `GET /api/lan` (the control token, to a peer read as loopback).
///
/// This suite has no convention for a test that pins a known defect, so
/// the unsafe test says what it is in its name and in the comment above it.
final class ProxyBoundaryTests: XCTestCase {
    /// The public name the proxy forwards. Not resolved, not connected to.
    private static let publicHost = "mac.tailnet.ts.net"

    private var stateDir: URL!

    private static var buildDir: URL {
        Bundle(for: ProxyBoundaryTests.self).bundleURL.deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-proxy-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    // MARK: - Configuration 1: neither `--lan` nor `--trusted-host`

    /// The default. A loopback peer naming a public host is refused by the
    /// `Host` rule of `LoopbackSecurity`; the reason is `non-loopback Host`,
    /// not `loopback only` (that reason is for a non-loopback peer).
    func testDefaultRefusesAPublicHostFromLoopback() async throws {
        let daemon = try await startServe([])
        defer { stop(daemon) }

        let proxied = try get("/api/sessions", host: Self.publicHost, port: daemon.port)
        XCTAssertEqual(proxied.status, 403)
        XCTAssertEqual(proxied.body, #"{"ok":false,"error":"non-loopback Host"}"#)

        let profiles = try get("/api/profiles", host: Self.publicHost, port: daemon.port)
        XCTAssertEqual(profiles.status, 403, "no grade at all: \(profiles.body)")
        XCTAssertEqual(profiles.body, #"{"ok":false,"error":"non-loopback Host"}"#)

        let local = try get("/api/sessions", host: "127.0.0.1:\(daemon.port)", port: daemon.port)
        XCTAssertEqual(local.status, 200, local.body)
        try assertEmptySessionList(local.body)
        try assertFullGrade(daemon, host: "127.0.0.1:\(daemon.port)")
    }

    // MARK: - Configuration 2: `--lan --trusted-host <name>`

    /// The proxy is a boundary. A request naming the trusted host is remote
    /// whatever its peer, so it needs a token; the same daemon, asked with a
    /// loopback `Host`, still trusts the local human.
    func testTrustedHostNeedsATokenFromLoopback() async throws {
        let daemon = try await startServe(["--lan", "--trusted-host", Self.publicHost])
        defer { stop(daemon) }

        let proxied = try get("/api/sessions", host: Self.publicHost, port: daemon.port)
        XCTAssertEqual(proxied.status, 403)
        XCTAssertEqual(proxied.body, #"{"ok":false,"error":"missing or invalid token"}"#)

        let profiles = try get("/api/profiles", host: Self.publicHost, port: daemon.port)
        XCTAssertEqual(profiles.status, 403, "no grade at all: \(profiles.body)")
        XCTAssertEqual(profiles.body, #"{"ok":false,"error":"missing or invalid token"}"#)

        // The 403 is a gate, not a fault: the run's control token opens it.
        let token = try controlToken()
        let withToken = try get("/api/sessions?token=\(token)", host: Self.publicHost, port: daemon.port)
        XCTAssertEqual(withToken.status, 200, withToken.body)
        try assertEmptySessionList(withToken.body)

        let local = try get("/api/sessions", host: "127.0.0.1:\(daemon.port)", port: daemon.port)
        XCTAssertEqual(local.status, 200, local.body)
        try assertFullGrade(daemon, host: "127.0.0.1:\(daemon.port)")
    }

    // MARK: - Configuration 3: `--lan`, no `--trusted-host`

    /// THIS TEST ASSERTS TODAY'S UNSAFE BEHAVIOUR ON PURPOSE. It documents
    /// the hole `agent-push` round 1 measured on 2026-09-11: with `--lan` and
    /// no `--trusted-host`, a request through a loopback proxy naming a
    /// public host is read as the local human and gets full grade with no
    /// token, the control token included. Behind `tailscale serve` that is
    /// every device on the tailnet.
    ///
    /// Capability 2 of `proxy-is-a-boundary` flips this test: the daemon
    /// then refuses to start on this combination, and the assertions below
    /// change to the refusal. Until then, a green suite with this test
    /// passing is NOT a safe daemon; it is a daemon whose hole is on the
    /// record. Do not "fix" this test by weakening it.
    func testLanWithoutTrustedHostGrantsFullAccessToAProxiedRequest() async throws {
        let daemon = try await startServe(["--lan"])
        defer { stop(daemon) }

        let proxied = try get("/api/sessions", host: Self.publicHost, port: daemon.port)
        XCTAssertEqual(proxied.status, 200, "the bypass: \(proxied.body)")
        try assertEmptySessionList(proxied.body)

        // Full grade, not watch: the profiles route answers, and the lan
        // route hands the proxied request the run's own control token.
        try assertFullGrade(daemon, host: Self.publicHost)

        // The branch skips the origin check as well: a cross-origin page on
        // the tailnet is admitted like everything else.
        let crossOrigin = try get(
            "/api/sessions", host: Self.publicHost, port: daemon.port,
            extraHeaders: ["Origin: https://evil.example"]
        )
        XCTAssertEqual(crossOrigin.status, 200, crossOrigin.body)
        try assertEmptySessionList(crossOrigin.body)

        let local = try get("/api/sessions", host: "127.0.0.1:\(daemon.port)", port: daemon.port)
        XCTAssertEqual(local.status, 200, local.body)
        try assertEmptySessionList(local.body)
    }

    // MARK: - A `--trusted-host` that never matches

    /// A misspelt `--trusted-host` is accepted and protects nothing: the
    /// real name misses the allowlist, so the request falls into
    /// configuration 3. Recorded, not fixed, this round; the daemon cannot
    /// know the name is wrong without a source of truth it does not have.
    func testAMisspeltTrustedHostLeavesTheBypassOpen() async throws {
        let daemon = try await startServe(["--lan", "--trusted-host", "mac.tailnet.ts.nett"])
        defer { stop(daemon) }

        let proxied = try get("/api/sessions", host: Self.publicHost, port: daemon.port)
        XCTAssertEqual(proxied.status, 200, "the typo is not a boundary: \(proxied.body)")
        try assertEmptySessionList(proxied.body)
        try assertFullGrade(daemon, host: Self.publicHost)
    }

    // MARK: - Helpers

    private struct Daemon {
        let process: Process
        let pid: Int32
        let port: Int
    }

    private var executable: URL { Self.buildDir.appendingPathComponent("kitterm") }

    private var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["KITTERM_STATE_DIR"] = stateDir.path
        environment["SHELL"] = "/bin/sh"
        return environment
    }

    /// A real `kitterm serve` on a free port under the test's own state
    /// directory, with `flags` after `--port`, returned once it is healthy.
    private func startServe(_ flags: [String]) async throws -> Daemon {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "kitterm binary not built beside the test bundle"
        )
        let port = try freePort()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--port", "\(port)"] + flags
        process.environment = environment
        try process.run()
        let daemon = Daemon(process: process, pid: process.processIdentifier, port: port)
        do {
            try await waitFor("the daemon to be healthy") { await self.isHealthy(port: port) }
        } catch {
            stop(daemon)
            throw error
        }
        return daemon
    }

    private func stop(_ daemon: Daemon) {
        guard daemon.process.isRunning else { return }
        kill(daemon.pid, SIGTERM)
        waitForExit(of: daemon.process)
    }

    /// The control token the `--lan` run wrote, from the scratch state dir.
    private func controlToken() throws -> String {
        try String(contentsOf: stateDir.appendingPathComponent("token"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What full grade looks like from the outside, on a request naming
    /// `host` with no token: the profiles route answers with a list, and the
    /// lan route hands over the run's control token (only a `--lan` run has
    /// one; the default run reports `enabled: false`).
    private func assertFullGrade(
        _ daemon: Daemon, host: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let profiles = try get("/api/profiles", host: host, port: daemon.port)
        XCTAssertEqual(profiles.status, 200, "profiles is full grade only: \(profiles.body)", file: file, line: line)
        XCTAssertTrue(profiles.body.contains(#""ok":true"#), profiles.body, file: file, line: line)
        XCTAssertTrue(profiles.body.contains(#""profiles":"#), profiles.body, file: file, line: line)

        // The lan route names a LAN IP only on a machine that has one, so the
        // token assertion is conditional on `enabled`; the profiles route
        // above is the grade assertion that holds everywhere.
        let lan = try get("/api/lan", host: host, port: daemon.port)
        XCTAssertEqual(lan.status, 200, lan.body, file: file, line: line)
        if let token = try? controlToken(), lan.body.contains(#""enabled":true"#) {
            XCTAssertTrue(
                lan.body.contains(#""token":"\#(token)""#),
                "a peer read as loopback is handed the control token: \(lan.body)",
                file: file, line: line
            )
        } else {
            XCTAssertEqual(lan.body, #"{"ok":true,"enabled":false}"#, file: file, line: line)
        }
    }

    /// The full-grade answer to `GET /api/sessions` on a daemon with no
    /// shell: `{"ok":true,"sessions":[]}`, compared as JSON because the
    /// daemon serializes the keys in no fixed order.
    private func assertEmptySessionList(
        _ body: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let parsed = try XCTUnwrap(object, "not a JSON object: \(body)", file: file, line: line)
        XCTAssertEqual(parsed["ok"] as? Bool, true, body, file: file, line: line)
        XCTAssertEqual((parsed["sessions"] as? [Any])?.count, 0, body, file: file, line: line)
        XCTAssertEqual(parsed.count, 2, body, file: file, line: line)
    }

    /// One HTTP/1.1 request over a fresh POSIX socket to 127.0.0.1, with the
    /// `Host` header the caller chose, read to EOF (`Connection: close`).
    private func get(
        _ path: String, host: String, port: Int, extraHeaders: [String] = []
    ) throws -> (status: Int, body: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CancellationError() }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw CancellationError() }

        var request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nAccept: application/json\r\n"
        for header in extraHeaders { request += "\(header)\r\n" }
        request += "Connection: close\r\n\r\n"
        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw CancellationError() }
            sent += n
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            response.append(contentsOf: buffer[0..<n])
        }
        let text = String(decoding: response, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") else {
            XCTFail("no header terminator in response: \(text)")
            throw CancellationError()
        }
        let statusLine = text[..<split.lowerBound].split(separator: "\r\n").first ?? ""
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? -1
        return (status, String(text[split.upperBound...]))
    }

    private func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func waitFor(
        _ what: String, timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = SuspendingClock.now + .seconds(timeout)
        while SuspendingClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50), clock: .suspending)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        throw CancellationError()
    }

    private func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw CancellationError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw CancellationError() }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
