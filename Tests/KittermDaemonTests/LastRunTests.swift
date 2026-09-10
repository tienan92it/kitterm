import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// The record a run of the daemon leaves behind (`LastRun`,
/// `~/.kitterm/last-run.json`): the three states a reader must tell apart,
/// and the three paths that write them.
///
/// The third state is the one the goal exists for, and it cannot be faked by
/// calling a function: a run that the kernel kills leaves no `endedAt`
/// precisely because no code of ours runs at that moment. So that case is
/// proved against a real `kitterm serve` process under `KITTERM_STATE_DIR`,
/// killed with `SIGKILL`.
final class LastRunTests: XCTestCase {
    private var stateDir: URL!

    private static var buildDir: URL {
        Bundle(for: LastRunTests.self).bundleURL.deletingLastPathComponent()
    }

    /// The spawn helper sits beside the test bundle, and `PtySession` finds it
    /// on `PATH`. Without this a session spawn answers `errno=2`.
    override class func setUp() {
        super.setUp()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-last-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private var file: URL { stateDir.appendingPathComponent("last-run.json") }

    // MARK: - The record's own states

    func testBeginRunWritesALiveRecordWithNoEnding() throws {
        let store = LastRunStore(file: file)
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        store.beginRun(pid: 4242, sessions: 0, now: now)

        let record = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertEqual(record.version, LastRun.formatVersion)
        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(record.startedAt, 1_757_000_000_000)
        XCTAssertEqual(record.aliveAt, record.startedAt)
        XCTAssertEqual(record.sessions, 0)
        XCTAssertNil(record.endedAt, "a run that is still running has no ending")
        XCTAssertNil(record.reason)
        XCTAssertFalse(record.endedCleanly)
    }

    func testRefreshAdvancesAliveAtAndTheSessionCount() throws {
        let store = LastRunStore(file: file)
        let started = Date(timeIntervalSince1970: 1_757_000_000)
        store.beginRun(pid: 4242, now: started)
        store.refresh(sessions: 3, now: started.addingTimeInterval(90))

        let record = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertEqual(record.sessions, 3)
        XCTAssertEqual(record.aliveAt, 1_757_000_090_000)
        XCTAssertEqual(record.startedAt, 1_757_000_000_000, "the start does not move")
        XCTAssertNil(record.endedAt)
    }

    func testEndRecordsTheReasonAndAnEndedAt() throws {
        let store = LastRunStore(file: file)
        let started = Date(timeIntervalSince1970: 1_757_000_000)
        store.beginRun(pid: 4242, now: started)
        store.end(reason: .stopped, sessions: 2, now: started.addingTimeInterval(5))

        let record = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertEqual(record.reason, .stopped)
        XCTAssertEqual(record.endedAt, 1_757_000_005_000)
        XCTAssertEqual(record.aliveAt, record.endedAt)
        XCTAssertEqual(record.sessions, 2)
        XCTAssertTrue(record.endedCleanly)
    }

    /// The first reason is the true one. A takeover whose `exec` returned runs
    /// a stop path later in the same process, and that stop is not how the run
    /// that handed over ended.
    func testTheFirstReasonWins() throws {
        let store = LastRunStore(file: file)
        store.beginRun(pid: 4242)
        store.end(reason: .takeover)
        store.end(reason: .stopped)

        XCTAssertEqual(try XCTUnwrap(LastRunStore.read(file)).reason, .takeover)
    }

    /// A refresh after the ending must not reopen the record: the run is over,
    /// and a later `aliveAt` would claim it was alive after it ended.
    func testRefreshAfterTheEndingChangesNothing() throws {
        let store = LastRunStore(file: file)
        let started = Date(timeIntervalSince1970: 1_757_000_000)
        store.beginRun(pid: 4242, now: started)
        store.end(reason: .stopped, now: started.addingTimeInterval(5))
        store.refresh(sessions: 9, now: started.addingTimeInterval(60))

        let record = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertEqual(record.endedAt, 1_757_000_005_000)
        XCTAssertEqual(record.aliveAt, 1_757_000_005_000)
        XCTAssertEqual(record.sessions, 0)
    }

    /// `beginRun` is the moment the previous run's record stops existing, so
    /// it is the only chance to read it. Capability 2 reports from this value.
    func testBeginRunReturnsThePreviousRecordThenReplacesIt() throws {
        let first = LastRunStore(file: file)
        let started = Date(timeIntervalSince1970: 1_757_000_000)
        first.beginRun(pid: 111, now: started)
        first.refresh(sessions: 2, now: started.addingTimeInterval(30))

        // A run that was killed: the record stops at its last refresh.
        let second = LastRunStore(file: file)
        let previous = try XCTUnwrap(second.beginRun(pid: 222, now: started.addingTimeInterval(60)))
        XCTAssertEqual(previous.pid, 111)
        XCTAssertEqual(previous.sessions, 2)
        XCTAssertEqual(previous.aliveAt, 1_757_000_030_000)
        XCTAssertNil(previous.endedAt, "the killed run left no ending")

        let current = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertEqual(current.pid, 222)
        XCTAssertEqual(current.startedAt, 1_757_000_060_000)
    }

    func testTheFirstRunOfAllFindsNoPreviousRecord() {
        XCTAssertNil(LastRunStore(file: file).beginRun(pid: 4242))
    }

    /// A version this build does not know reports nothing. A wrong claim about
    /// how the last run ended is worse than no claim.
    func testAReaderRefusesAnUnknownFormatVersion() throws {
        let future = LastRun(
            version: LastRun.formatVersion + 1, pid: 4242,
            startedAt: 1_757_000_000_000, aliveAt: 1_757_000_000_000, sessions: 0
        )
        try JSONEncoder().encode(future).write(to: file)

        XCTAssertNil(LastRunStore.read(file))
        XCTAssertNil(LastRunStore(file: file).beginRun(pid: 5555))
    }

    /// A newer daemon may add a field; an older reader keeps the rest.
    func testAnUnknownFieldDecodesAway() throws {
        let json = """
        {"version":1,"pid":4242,"startedAt":1757000000000,"aliveAt":1757000000000,\
        "sessions":1,"whatIsThis":"a later field"}
        """
        try Data(json.utf8).write(to: file)

        let record = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(record.sessions, 1)
        XCTAssertNil(record.endedAt)
    }

    // MARK: - The paths that write it

    /// Case one: a clean stop. `DaemonServer.stop()` is what the SIGTERM
    /// handler runs, and it counts the sessions before it kills them.
    func testACleanStopWritesStoppedWithAnEndedAtAndTheSessionCount() async throws {
        try withScratchStateDirectory()
        let store = LastRunStore(file: file)
        store.beginRun()

        let server = DaemonServer(config: DaemonConfig(port: 0, agentControl: true), lastRun: store)
        try server.start()
        let port = try XCTUnwrap(server.boundPort)
        let spawned = try await post(port: port, "/api/sessions", body: #"{"name":"crew"}"#)
        XCTAssertEqual(spawned.status, 201, spawned.body)

        try server.stop()

        let record = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertEqual(record.reason, .stopped)
        XCTAssertEqual(record.pid, getpid())
        let endedAt = try XCTUnwrap(record.endedAt)
        XCTAssertGreaterThanOrEqual(endedAt, record.startedAt)
        XCTAssertEqual(record.sessions, 1, "the count is taken before the shells go")
    }

    /// Case two: a live upgrade. The ending is written before the `exec`, so
    /// the successor reads `takeover` and never mistakes it for a death.
    func testATakeoverWritesTakeover() async throws {
        try withScratchStateDirectory()
        let store = LastRunStore(file: file)
        store.beginRun()

        let server = DaemonServer(config: DaemonConfig(port: 0, agentControl: true), lastRun: store)
        try server.start()
        let port = try XCTUnwrap(server.boundPort)
        let spawned = try await post(port: port, "/api/sessions", body: #"{"name":"crew"}"#)
        XCTAssertEqual(spawned.status, 201, spawned.body)

        let directory = stateDir.appendingPathComponent("takeover", isDirectory: true)
        let state = try server.prepareHandoff(into: directory)
        XCTAssertEqual(state.sessions.count, 1)

        let record = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertEqual(record.reason, .takeover)
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(record.sessions, 1)

        // The shells are still ours: serve on from them (rung 2) so stopping
        // that server reaps them, rather than leaking a `cat` per test run.
        let resumed = DaemonServer(
            config: DaemonConfig(port: 0, agentControl: true), carrying: server.carried
        )
        try resumed.start()
        try resumed.stop()
    }

    /// Case three: the kernel killed the run. No code of ours runs at that
    /// moment, so this needs a real process — a scratch daemon on a free port
    /// under its own state directory, killed with `SIGKILL`.
    ///
    /// The wait before the kill is on the condition the assertion needs: a
    /// record on disk that names this daemon's pid. Health alone is not that
    /// condition, and a sleep is not a condition at all.
    func testAKilledRunLeavesNoEndedAt() throws {
        let executable = Bundle(for: LastRunTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("kitterm")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "kitterm binary not built beside the test bundle"
        )
        let port = try freePort()
        let daemon = Process()
        daemon.executableURL = executable
        daemon.arguments = ["serve", "--port", "\(port)"]
        var environment = ProcessInfo.processInfo.environment
        environment["KITTERM_STATE_DIR"] = stateDir.path
        environment["SHELL"] = "/bin/sh"
        daemon.environment = environment
        try daemon.run()
        defer {
            if daemon.isRunning {
                kill(daemon.processIdentifier, SIGKILL)
                daemon.waitUntilExit()
            }
        }

        let pid = daemon.processIdentifier
        try waitFor("last-run.json naming pid \(pid)") {
            LastRunStore.read(self.file)?.pid == pid
        }
        let live = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertNil(live.endedAt, "a running daemon's record has no ending")

        XCTAssertEqual(kill(pid, SIGKILL), 0)
        daemon.waitUntilExit()

        let record = try XCTUnwrap(LastRunStore.read(file))
        XCTAssertEqual(record.pid, pid)
        XCTAssertGreaterThan(record.startedAt, 0)
        XCTAssertGreaterThanOrEqual(record.aliveAt, record.startedAt)
        XCTAssertNil(record.endedAt, "the kill left no ending; that absence is the signal")
        XCTAssertNil(record.reason)
    }

    // MARK: - Helpers

    /// Point `DaemonPaths` at the scratch directory, so a server built here
    /// writes `respawn.json` and the rest beside the record under test
    /// instead of into the developer's live `~/.kitterm`.
    private func withScratchStateDirectory() throws {
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        addTeardownBlock { unsetenv("KITTERM_STATE_DIR") }
        setenv("SHELL", "/bin/sh", 1)
    }

    private func waitFor(
        _ what: String, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        throw CancellationError()
    }

    private func post(
        port: Int, _ path: String, body: String
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
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
