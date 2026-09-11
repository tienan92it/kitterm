import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// `serve` claims `pid` and `port` only once it holds the port.
///
/// A second `serve` on a state directory whose daemon is already serving
/// must lose the bind and leave both files exactly as the live daemon wrote
/// them. Written the other way round, the loser overwrote `pid` with its own
/// and exited, `livePid()` then found a dead process and deleted the file,
/// and `kitterm stop` answered "not running" while the daemon served on.
///
/// Proved with real processes, like `PreviousRunReportTests`: two `kitterm
/// serve` on one port under `KITTERM_STATE_DIR`, then the real `kitterm
/// stop` against the same directory.
final class PidAfterBindTests: XCTestCase {
    private var stateDir: URL!

    private static var buildDir: URL {
        Bundle(for: PidAfterBindTests.self).bundleURL.deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-pid-after-bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private var pidFile: URL { stateDir.appendingPathComponent("pid") }
    private var portFile: URL { stateDir.appendingPathComponent("port") }

    func testASecondServeOnAHeldPortLeavesThePidAndPortFilesToTheLiveDaemon() async throws {
        let port = try freePort()
        let first = try startServe(port: port)
        defer { stop(first) }
        try await waitFor("the first daemon to be healthy") { await self.isHealthy(port: port) }
        try await waitFor("pid naming the first daemon") { self.read(self.pidFile) == "\(first.pid)" }
        XCTAssertEqual(read(portFile), "\(port)")

        let second = try startServe(port: port)
        defer { stop(second) }
        try await waitFor("the second serve to exit") { !second.process.isRunning }
        XCTAssertNotEqual(second.process.terminationStatus, 0, "the loser must exit non-zero")
        let log = try serverLog()
        XCTAssertTrue(
            log.contains {
                $0.contains("failed to bind 127.0.0.1:\(port)") && $0.contains("Address already in use")
            },
            "the loser says the port is taken: \(log)"
        )

        XCTAssertEqual(read(pidFile), "\(first.pid)", "pid still names the live daemon")
        XCTAssertEqual(read(portFile), "\(port)", "port is still the live daemon's")
        XCTAssertEqual(kill(first.pid, 0), 0, "the first daemon is still alive")
        let healthy = await isHealthy(port: port)
        XCTAssertTrue(healthy, "the first daemon still serves")

        // The consequence that mattered: `kitterm stop` finds the daemon.
        let stopped = try runCLI(["stop"])
        XCTAssertEqual(stopped.status, 0, stopped.output)
        XCTAssertTrue(
            stopped.output.contains("kitterm stopped (was pid \(first.pid))"),
            "stop must name the live daemon: \(stopped.output)"
        )
        try await waitFor("the first daemon to exit after stop") { !first.process.isRunning }
    }

    // MARK: - Helpers

    private struct Daemon {
        let process: Process
        let pid: Int32
    }

    private var executable: URL { Self.buildDir.appendingPathComponent("kitterm") }

    private var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["KITTERM_STATE_DIR"] = stateDir.path
        environment["SHELL"] = "/bin/sh"
        return environment
    }

    /// A `kitterm serve` on `port` under the test's own state directory. Its
    /// stdout and stderr land in `<state>/server.log`, which `serverLog()`
    /// reads back.
    private func startServe(port: Int) throws -> Daemon {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "kitterm binary not built beside the test bundle"
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--port", "\(port)"]
        process.environment = environment
        try process.run()
        return Daemon(process: process, pid: process.processIdentifier)
    }

    /// The real CLI against the same state directory, output captured.
    private func runCLI(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func stop(_ daemon: Daemon) {
        guard daemon.process.isRunning else { return }
        kill(daemon.pid, SIGTERM)
        daemon.process.waitUntilExit()
    }

    private func read(_ file: URL) -> String? {
        (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func serverLog() throws -> [String] {
        let text = try String(contentsOf: stateDir.appendingPathComponent("server.log"))
        return text.split(separator: "\n").map(String.init)
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
