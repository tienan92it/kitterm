import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// The reading half of `LastRun`: what a run says about the run before it, on
/// `server.log` and on the event feed (`PreviousRun`, `EventLog.markStarted`).
///
/// Four cases, and each one is asserted twice — once on the line a human
/// reads and once on the keys a program branches on — because the whole point
/// of the goal is that the two must never disagree.
///
/// The two cases that matter cannot be faked by calling a function: a run the
/// kernel kills leaves no ending precisely because no code of ours runs then,
/// and a clean stop is written by the `SIGTERM` handler of a real `serve`
/// process. So both are proved the way `LastRunTests` proves its own third
/// case — a scratch daemon on a free port under `KITTERM_STATE_DIR`, started,
/// ended, and started again on the same directory.
final class PreviousRunReportTests: XCTestCase {
    private var stateDir: URL!

    private static var buildDir: URL {
        Bundle(for: PreviousRunReportTests.self).bundleURL.deletingLastPathComponent()
    }

    /// The spawn helper sits beside the test bundle, and `PtySession` finds it
    /// on `PATH`. Without this a session spawn answers `errno=2`.
    override class func setUp() {
        super.setUp()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-previous-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private var recordFile: URL { stateDir.appendingPathComponent("last-run.json") }

    // MARK: - The four cases, encoded

    /// The case the goal exists for. The line names the three facts
    /// completion condition 2 asks for: the pid, the time the run was last
    /// alive, and the sessions it held.
    func testAKilledRecordReadsAsUnrecorded() {
        let record = LastRun(
            pid: 4242, startedAt: 1_757_000_000_000, aliveAt: 1_757_000_030_000, sessions: 2
        )
        XCTAssertEqual(record.outcome, .unrecorded)
        XCTAssertEqual(
            PreviousRun.logLine(record),
            "kitterm: previous run (pid 4242) ended with no recorded reason, "
                + "last alive 2025-09-04T15:33:50Z holding 2 session(s)\n"
        )
        XCTAssertEqual(
            PreviousRun.eventData(record),
            [
                "previous": "unrecorded",
                "previousPid": "4242",
                "previousAliveAt": "1757000030000",
                "previousSessions": "2",
            ]
        )
    }

    /// A stop and a restart are one case here: both take every session, so
    /// the reading half never needs the difference. `reason` still names
    /// which, on the line only.
    func testAStopAndARestartBothReadAsClean() {
        for reason in [LastRun.Reason.stopped, .restarted] {
            let record = LastRun(
                pid: 7, startedAt: 1_757_000_000_000, aliveAt: 1_757_000_005_000,
                sessions: 3, endedAt: 1_757_000_005_000, reason: reason
            )
            XCTAssertEqual(record.outcome, .clean)
            XCTAssertEqual(
                PreviousRun.logLine(record),
                "kitterm: previous run (pid 7) ended cleanly (\(reason.rawValue)) "
                    + "at 2025-09-04T15:33:25Z\n"
            )
            XCTAssertEqual(PreviousRun.eventData(record)["previous"], "clean")
            XCTAssertEqual(PreviousRun.eventData(record)["previousEndedAt"], "1757000005000")
            XCTAssertEqual(PreviousRun.eventData(record)["previousSessions"], "3")
        }
    }

    /// A live upgrade keeps every session, so it is a third value and never
    /// `clean`: a consumer that saw `clean` could not tell the upgrade from
    /// the stop, and `goal.md` asks a reader to tell them apart.
    func testATakeoverIsItsOwnValueAndSaysNothingWasLost() {
        let record = LastRun(
            pid: 9, startedAt: 1_757_000_000_000, aliveAt: 1_757_000_005_000,
            sessions: 4, endedAt: 1_757_000_005_000, reason: .takeover
        )
        XCTAssertEqual(record.outcome, .takeover)
        XCTAssertEqual(
            PreviousRun.logLine(record),
            "kitterm: previous run (pid 9) handed over in place at "
                + "2025-09-04T15:33:25Z, 4 session(s) kept\n"
        )
        XCTAssertEqual(PreviousRun.eventData(record)["previous"], "takeover")
    }

    /// A first start on a fresh state directory. The log says so, because a
    /// human diagnosing a kill must tell "no record was there" from "the
    /// reading half never ran". The feed says nothing, because the absent
    /// key is the absent record and a consumer needs no fourth branch.
    func testNoRecordLogsALineAndAddsNoEventKeys() {
        XCTAssertEqual(PreviousRun.logLine(nil), "kitterm: no previous run recorded\n")
        XCTAssertEqual(PreviousRun.eventData(nil), [:])
    }

    /// A record with an end time but no reason, or a reason but no end time,
    /// is half-written. It reads as `unrecorded` rather than as a claim this
    /// build cannot support.
    func testAHalfWrittenRecordReadsAsUnrecorded() {
        let noReason = LastRun(
            pid: 1, startedAt: 1, aliveAt: 2, sessions: 0, endedAt: 2, reason: nil
        )
        let noEnding = LastRun(
            pid: 1, startedAt: 1, aliveAt: 2, sessions: 0, endedAt: nil, reason: .stopped
        )
        XCTAssertEqual(noReason.outcome, .unrecorded)
        XCTAssertEqual(noEnding.outcome, .unrecorded)
        XCTAssertNil(PreviousRun.eventData(noEnding)["previousEndedAt"])
    }

    // MARK: - The event carries it without disturbing what was there

    func testMarkStartedKeepsEveryExistingKeyAndAddsThePreviousRun() throws {
        let record = LastRun(
            pid: 4242, startedAt: 1_757_000_000_000, aliveAt: 1_757_000_030_000, sessions: 2
        )
        let log = EventLog()
        log.markStarted(version: "9.9.9", pid: 1234, takeover: true, previous: record)

        let event = try XCTUnwrap(log.snapshot(since: 0, session: nil).events.first)
        XCTAssertEqual(event.type, "daemon.started")
        XCTAssertEqual(event.data["epoch"], log.epoch, "a client reading only epoch is untouched")
        XCTAssertEqual(event.data["version"], "9.9.9")
        XCTAssertEqual(event.data["pid"], "1234", "pid still means this run")
        XCTAssertEqual(event.data["takeover"], "true")
        XCTAssertEqual(event.data["previous"], "unrecorded")
        XCTAssertEqual(event.data["previousPid"], "4242")
        XCTAssertEqual(event.data["previousAliveAt"], "1757000030000")
        XCTAssertEqual(event.data["previousSessions"], "2")
    }

    func testMarkStartedWithNoPreviousRunCarriesTheOldKeysOnly() throws {
        let log = EventLog()
        log.markStarted(version: "9.9.9", pid: 1234)

        let event = try XCTUnwrap(log.snapshot(since: 0, session: nil).events.first)
        XCTAssertEqual(Set(event.data.keys), ["epoch", "version", "pid"])
    }

    // MARK: - Proved with real processes

    /// Completion condition 2, end to end, against the corpus fixture: a
    /// daemon holding two sessions, killed with `SIGKILL`, then started again
    /// on the same state directory.
    ///
    /// The wait before the kill is on the condition the assertion needs — the
    /// record on disk saying this daemon holds two sessions — not on a sleep.
    /// That condition is what the 30 s `lastRunRefreshSeconds` cadence
    /// writes, so this test pays for that cadence once; it is the only proof
    /// that the refresh, the kill, and the report compose.
    func testAKilledRunIsReportedAsUnrecordedWithItsPidTimeAndSessions() async throws {
        let first = try startDaemon()
        defer { stop(first) }
        try await waitFor("last-run.json naming pid \(first.pid)") {
            LastRunStore.read(self.recordFile)?.pid == first.pid
        }
        for name in ["crew-a", "crew-b"] {
            let spawned = try await post(port: first.port, "/api/sessions", body: #"{"name":"\#(name)"}"#)
            XCTAssertEqual(spawned.status, 201, spawned.body)
        }
        // The refresh cadence is what puts the count in the record; a killed
        // run has no other chance to write one.
        try await waitFor("the record to say two sessions", timeout: 90) {
            LastRunStore.read(self.recordFile)?.sessions == 2
        }
        let killed = try XCTUnwrap(LastRunStore.read(recordFile))

        XCTAssertEqual(kill(first.pid, SIGKILL), 0)
        first.process.waitUntilExit()
        XCTAssertNil(
            try XCTUnwrap(LastRunStore.read(recordFile)).endedAt,
            "the kill left no ending; that absence is what the next run reports"
        )

        let second = try startDaemon()
        defer { stop(second) }
        try await waitFor("the new run to be healthy") { await self.isHealthy(port: second.port) }

        XCTAssertEqual(
            try serverLog().filter { $0.hasPrefix("kitterm: previous run") },
            [
                "kitterm: previous run (pid \(first.pid)) ended with no recorded reason, "
                    + "last alive \(iso(killed.aliveAt)) holding 2 session(s)"
            ]
        )

        let data = try await startedEventData(port: second.port)
        XCTAssertEqual(data["previous"], "unrecorded")
        XCTAssertEqual(data["previousPid"], String(first.pid))
        XCTAssertEqual(data["previousAliveAt"], String(killed.aliveAt))
        XCTAssertEqual(data["previousSessions"], "2")
        XCTAssertNil(data["previousEndedAt"], "there was no ending to name")
        XCTAssertEqual(data["pid"], String(second.pid), "pid still means this run")
        XCTAssertNotNil(data["epoch"])
    }

    /// Completion condition 1: a `kitterm stop` — the `SIGTERM` its CLI sends
    /// — and the start that follows says the previous run ended cleanly. The
    /// session count comes from the stop path, which takes it before the
    /// shells go, so no refresh is involved.
    func testACleanlyStoppedRunIsReportedAsClean() async throws {
        let first = try startDaemon()
        defer { stop(first) }
        try await waitFor("last-run.json naming pid \(first.pid)") {
            LastRunStore.read(self.recordFile)?.pid == first.pid
        }
        let spawned = try await post(port: first.port, "/api/sessions", body: #"{"name":"crew"}"#)
        XCTAssertEqual(spawned.status, 201, spawned.body)

        XCTAssertEqual(kill(first.pid, SIGTERM), 0)
        first.process.waitUntilExit()
        let stopped = try XCTUnwrap(LastRunStore.read(recordFile))
        XCTAssertEqual(stopped.reason, .stopped)

        let second = try startDaemon()
        defer { stop(second) }
        try await waitFor("the new run to be healthy") { await self.isHealthy(port: second.port) }

        XCTAssertEqual(
            try serverLog().filter { $0.hasPrefix("kitterm: previous run") },
            [
                "kitterm: previous run (pid \(first.pid)) ended cleanly (stopped) "
                    + "at \(iso(stopped.aliveAt))"
            ]
        )

        let data = try await startedEventData(port: second.port)
        XCTAssertEqual(data["previous"], "clean")
        XCTAssertEqual(data["previousPid"], String(first.pid))
        XCTAssertEqual(data["previousEndedAt"], String(try XCTUnwrap(stopped.endedAt)))
        XCTAssertEqual(data["previousSessions"], "1")
    }

    /// The third thing to say nothing about: a first start on a state
    /// directory that has never held a daemon.
    func testAFirstRunOnAFreshStateDirectorySaysThereWasNoPreviousRun() async throws {
        let only = try startDaemon()
        defer { stop(only) }
        try await waitFor("the run to be healthy") { await self.isHealthy(port: only.port) }

        XCTAssertTrue(
            try serverLog().contains("kitterm: no previous run recorded"),
            "the log still says it; the reader must tell a missing file from a missing report"
        )
        let data = try await startedEventData(port: only.port)
        XCTAssertNil(data["previous"], "the absent key is the absent record")
        XCTAssertTrue(data.keys.allSatisfy { !$0.hasPrefix("previous") })
    }

    // MARK: - Helpers

    private struct Daemon {
        let process: Process
        let port: Int
        let pid: Int32
    }

    /// A scratch `kitterm serve` on a free port under the test's own state
    /// directory. `serve` redirects its own stdout and stderr into
    /// `<state>/server.log` with `O_APPEND`, so every run of a test writes to
    /// the same file the goal is about and `serverLog()` reads it back.
    private func startDaemon() throws -> Daemon {
        let executable = Self.buildDir.appendingPathComponent("kitterm")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "kitterm binary not built beside the test bundle"
        )
        let port = try freePort()
        let process = Process()
        process.executableURL = executable
        // `--agent-control` because these tests spawn sessions through
        // `POST /api/sessions`, which the daemon refuses without it.
        process.arguments = ["serve", "--port", "\(port)", "--agent-control"]
        var environment = ProcessInfo.processInfo.environment
        environment["KITTERM_STATE_DIR"] = stateDir.path
        environment["SHELL"] = "/bin/sh"
        process.environment = environment
        try process.run()

        return Daemon(process: process, port: port, pid: process.processIdentifier)
    }

    /// Stop a daemon the way `kitterm stop` does, so its shells are reaped
    /// rather than left behind by the test.
    private func stop(_ daemon: Daemon) {
        guard daemon.process.isRunning else { return }
        kill(daemon.pid, SIGTERM)
        daemon.process.waitUntilExit()
    }

    /// The `server.log` every run of this test's daemons appends to.
    private func serverLog() throws -> [String] {
        let text = try String(contentsOf: stateDir.appendingPathComponent("server.log"))
        return text.split(separator: "\n").map(String.init)
    }

    private func iso(_ milliseconds: Int64) -> String {
        ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        )
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

    /// The `data` of the run's own `daemon.started`, which is the first event
    /// of its epoch.
    private func startedEventData(port: Int) async throws -> [String: String] {
        let url = URL(string: "http://127.0.0.1:\(port)/api/events?since=0&timeout=1")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        let started = try XCTUnwrap(events.first { $0["type"] as? String == "daemon.started" })
        return started["data"] as? [String: String] ?? [:]
    }

    /// Wait on the condition the next lines need, never on a sleep. Async and
    /// suspending, because every caller here is an async test: a
    /// `Thread.sleep` in one of those parks a cooperative thread that the
    /// `URLSession` calls below need back.
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
