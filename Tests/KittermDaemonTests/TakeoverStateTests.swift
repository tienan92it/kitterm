import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// The handoff format of a live upgrade (`docs/live-upgrade.md`): the old
/// binary writes it, the new one reads it, from every release to the next.
final class TakeoverStateTests: XCTestCase {
    private func sampleState(fd: Int32? = 7) -> TakeoverState {
        let id = UUID()
        return TakeoverState(
            writtenBy: "0.21.1",
            fds: fd.map { [$0] } ?? [],
            eventLog: .init(
                epoch: "abc",
                lastSeq: 12,
                events: [
                    .init(seq: 11, at: 1_700_000_000_000, type: "session.created", session: id, data: ["shell": "/bin/sh"]),
                    .init(seq: 12, at: 1_700_000_000_500, type: "note", session: id, data: ["message": "hi"]),
                ]
            ),
            sessions: [
                .init(
                    fd: fd,
                    sessionID: id,
                    pid: 4242,
                    shellPath: "/bin/sh",
                    initialCwd: "/tmp",
                    profileName: "vm",
                    labels: ["crew": "alpha"],
                    name: "builder",
                    note: "waiting",
                    spawnedByAPI: true,
                    cols: 100,
                    rows: 40,
                    lastPolledCwd: "/tmp/work",
                    submittedCommand: "make",
                    terminated: false,
                    shellExitCode: nil,
                    exitNotified: false,
                    detachOffset: 900,
                    logHead: 1000,
                    ringFile: "\(id.uuidString).bin",
                    marks: [.init(offset: 10, kind: MarkKind.preExec.rawValue, exit: nil, command: "ls", at: 1_700_000_000_000)],
                    droppedCommands: 3,
                    lastOutputAt: 1_700_000_000_900,
                    agentStatus: .init(report: "working", message: nil, at: 1_700_000_000_800),
                    recorder: .init(path: "/tmp/x.cast", startedAt: 1_699_999_999_000),
                    logStore: .init(path: "/tmp/x.log", fileBase: 100, streamEnd: 1000),
                    heldSince: 1_700_000_000_000
                ),
            ]
        )
    }

    func testRoundTripThroughDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = sampleState()
        try state.write(to: directory)
        let loaded = try TakeoverState.load(from: directory)
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.formatVersion, TakeoverState.currentFormatVersion)
        // The file is the user's shell state; nobody else reads it.
        let attributes = try FileManager.default.attributesOfItem(
            atPath: TakeoverState.stateFile(in: directory).path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    /// A newer writer may add fields. This reader must not choke on them.
    func testUnknownFieldsAreIgnored() throws {
        let data = try JSONEncoder().encode(sampleState())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["futureTopLevel"] = "x"
        var sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        sessions[0]["futurePerSession"] = 42
        json["sessions"] = sessions
        let decoded = try TakeoverState.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, sampleState().withSameIDs(as: decoded))
    }

    /// A layout this build does not know is refused, but the fds it named
    /// are still handed back so the successor can close them.
    func testUnknownMajorVersionIsRefusedWithItsFDs() throws {
        var state = sampleState(fd: 9)
        state.formatVersion = 2
        let data = try JSONEncoder().encode(state)
        XCTAssertThrowsError(try TakeoverState.decode(data)) { error in
            XCTAssertEqual(
                error as? TakeoverState.LoadError,
                .unsupportedFormat(found: 2, fds: [9])
            )
        }
    }

    func testGarbageIsUnreadable() {
        XCTAssertThrowsError(try TakeoverState.decode(Data("not json".utf8))) { error in
            guard case .unreadable = error as? TakeoverState.LoadError else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    // MARK: - Restore paths

    /// The ring comes across whole, so `snapshot(from:)` answers exactly for
    /// an offset a client counted before the handoff.
    func testSessionLogRestoreKeepsOffsetsExact() {
        var original = SessionLog(capacity: 64)
        for i in 0..<20 {
            original.append(Data("chunk\(i)|".utf8))
        }
        let retained = original.retainedBytes()
        XCTAssertEqual(retained.count, 64)

        let restored = SessionLog(restoring: retained, head: original.head, capacity: 64)
        XCTAssertEqual(restored.head, original.head)
        XCTAssertEqual(restored.base, original.base)
        XCTAssertEqual(restored.retainedBytes(), retained)

        let probe = original.head - 17
        let before = original.snapshot(from: probe)
        let after = restored.snapshot(from: probe)
        XCTAssertFalse(after.pruned)
        XCTAssertEqual(after.data, before.data)
        XCTAssertEqual(after.start, before.start)

        // Appends continue the stream from the same head.
        var continued = restored
        continued.append(Data("more".utf8))
        XCTAssertEqual(continued.head, original.head + 4)
        XCTAssertEqual(continued.snapshot(from: original.head).data, Data("more".utf8))
    }

    /// A ring larger than this build's capacity keeps its newest bytes.
    func testSessionLogRestoreIntoSmallerRingKeepsTheTail() {
        let bytes = Data((0..<100).map { UInt8($0) })
        let restored = SessionLog(restoring: bytes, head: 500, capacity: 32)
        XCTAssertEqual(restored.head, 500)
        XCTAssertEqual(restored.base, 468)
        XCTAssertEqual(restored.retainedBytes(), bytes.suffix(32))
    }

    /// The feed continues: same epoch, seq carries on, an old cursor is not
    /// pruned, and `daemon.started` for the takeover sits inside the epoch.
    func testEventLogRestoreContinuesTheEpoch() {
        let original = EventLog()
        original.markStarted(version: "1", pid: 1)
        let id = UUID()
        original.append(type: "session.created", session: id)
        let cursor = original.snapshot(since: 0, session: nil).next

        let restored = EventLog(restoring: original.handoffState())
        restored.markStarted(version: "2", pid: 1, takeover: true)
        XCTAssertEqual(restored.epoch, original.epoch)

        let snap = restored.snapshot(since: cursor, epoch: original.epoch, session: nil)
        XCTAssertFalse(snap.pruned)
        XCTAssertEqual(snap.events.map(\.type), ["daemon.started"])
        XCTAssertEqual(snap.events.first?.seq, cursor + 1)
        XCTAssertEqual(snap.events.first?.data["takeover"], "true")
        XCTAssertEqual(snap.events.first?.data["epoch"], original.epoch)

        // Everything from before is still readable from zero.
        let all = restored.snapshot(since: 0, session: nil)
        XCTAssertEqual(all.events.map(\.type), ["daemon.started", "session.created", "daemon.started"])
    }

    /// Command numbering continues from the dropped count.
    func testMarkStoreRestoreKeepsIndexNumbering() {
        let marks = [
            SessionMark(offset: 1, kind: .preExec, exit: nil, command: "a"),
            SessionMark(offset: 5, kind: .commandEnd, exit: 0, command: nil),
        ]
        let store = SessionMarkStore(restoring: marks, droppedCommands: 7)
        XCTAssertEqual(store.firstRetainedIndex, 8)
        XCTAssertEqual(store.marks.count, 2)
        let commands = SessionCommands.pair(from: store.marks, firstIndex: store.firstRetainedIndex)
        XCTAssertEqual(commands.map(\.index), [8])
    }

    /// A session record with no fd (its shell exited before the handoff)
    /// adopts as a terminated session with its records intact.
    func testAdoptingAnExitedSessionKeepsItsRecords() {
        var state = sampleState(fd: nil).sessions[0]
        state.terminated = true
        state.exitNotified = true
        state.shellExitCode = 3
        let session = PtySession(adopting: state, ring: Data("hello".utf8))
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.exitCode, 3)
        XCTAssertEqual(session.name, "builder")
        XCTAssertEqual(session.labels["crew"], "alpha")
        XCTAssertTrue(session.isOrchestrated)
        XCTAssertEqual(session.logHead, 1000)
        XCTAssertEqual(session.commandsSnapshot().first?.index, 4)
        XCTAssertEqual(session.agentStatus?.report, .working)
        let tail = session.outputRange(from: 995, to: 1000, maxBytes: 64)
        XCTAssertEqual(tail.data, Data("hello".utf8))
        XCTAssertFalse(tail.pruned)
    }

    // MARK: - Handoff helpers

    func testSuccessorArgumentsReplaceAnEarlierTakeoverPair() {
        let directory = URL(fileURLWithPath: "/tmp/new")
        XCTAssertEqual(
            TakeoverHandoff.successorArguments(
                from: ["serve", "--port", "1", "--takeover", "/tmp/old", "--agent-control"],
                directory: directory
            ),
            ["serve", "--port", "1", "--agent-control", "--takeover", "/tmp/new"]
        )
        XCTAssertEqual(
            TakeoverHandoff.successorArguments(from: ["serve", "--takeover=/tmp/old"], directory: directory),
            ["serve", "--takeover", "/tmp/new"]
        )
    }

    func testValidateRefusesABinaryThatCannotRun() {
        XCTAssertNotNil(TakeoverHandoff.validate(executable: "/nonexistent/kitterm"))
        XCTAssertNotNil(TakeoverHandoff.validate(executable: "/usr/bin/false"))
        XCTAssertNil(TakeoverHandoff.validate(executable: "/usr/bin/true"))
    }
}

private extension TakeoverState {
    /// The sample mints a fresh id per call; align it for an equality check.
    func withSameIDs(as other: TakeoverState) -> TakeoverState {
        var copy = self
        for index in copy.sessions.indices where index < other.sessions.count {
            copy.sessions[index].sessionID = other.sessions[index].sessionID
            copy.sessions[index].ringFile = other.sessions[index].ringFile
        }
        copy.eventLog.events = other.eventLog.events
        return copy
    }
}

/// The failure ladder's rung 2 (`docs/live-upgrade.md`): the state is
/// written and the loop is down, but `exec` returned. The same process
/// serves on from the objects it quiesced, and the session is untouched.
final class TakeoverResumeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: TakeoverResumeTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    func testHandoffThenServeOnFromTheSameProcess() async throws {
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        defer {
            unsetenv("KITTERM_STATE_DIR")
            try? FileManager.default.removeItem(at: stateDir)
        }

        let config = DaemonConfig(port: 0, agentControl: true)
        let first = DaemonServer(config: config)
        try first.start()
        let port = try XCTUnwrap(first.boundPort)

        let spawned = try await post(port: port, "/api/sessions", body: #"{"input":"cat\n"}"#)
        XCTAssertEqual(spawned.status, 201, spawned.body)
        let id = try XCTUnwrap(parse(spawned.body)["id"] as? String)
        try await waitFor { try await self.row(port: port, id)["foregroundProgram"] as? String == "cat" }
        let rowBefore = try await row(port: port, id)
        let shellPid = try XCTUnwrap(rowBefore["pid"] as? Int32)
        let feedBefore = parse(try await get(port: port, "/api/events?since=0").body)
        let epoch = try XCTUnwrap(feedBefore["epoch"] as? String)

        // Quiesce and write, as the takeover would, then do not exec.
        let directory = stateDir.appendingPathComponent("takeover", isDirectory: true)
        let state = try first.prepareHandoff(into: directory)
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.sessions.first?.pid, shellPid)
        XCTAssertEqual(state.fds.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TakeoverState.stateFile(in: directory).path))
        XCTAssertEqual(state.eventLog.epoch, epoch)

        // Serve on from the same process. The port is free again; the
        // session is still the registry's; the feed keeps its epoch.
        let second = DaemonServer(config: DaemonConfig(port: port, agentControl: true), carrying: first.carried)
        try second.start()
        defer { try? second.stop() }
        let after = try await row(port: port, id)
        XCTAssertEqual(after["pid"] as? Int32, shellPid)
        XCTAssertEqual(after["foregroundProgram"] as? String, "cat")
        XCTAssertEqual(kill(shellPid, 0), 0)
        let feed = parse(try await get(port: port, "/api/events?since=0").body)
        XCTAssertEqual(feed["epoch"] as? String, epoch)
        let started = (feed["events"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "daemon.started" }
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual((started.last?["data"] as? [String: String])?["takeover"], "true")

        // The shell reads again through the new reader.
        _ = try await post(port: port, "/api/sessions/\(id)/input", body: "resumed\n")
        try await waitFor {
            let output = try await self.get(port: port, "/api/sessions/\(id)/output?tail=4096")
            return output.body.contains("resumed\r\nresumed\r\n")
        }
    }

    private func waitFor(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? await condition()) == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out")
    }

    private func row(port: Int, _ id: String) async throws -> [String: Any] {
        parse(try await get(port: port, "/api/sessions/\(id)").body)
    }

    private func get(port: Int, _ path: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func post(port: Int, _ path: String, body: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func parse(_ body: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
    }
}
