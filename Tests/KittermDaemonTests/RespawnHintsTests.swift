import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// A pane respawned after a daemon restart keeps its name and labels: the
/// registry writes them to disk as they change, and the reattach that finds
/// no session reads them back.
final class RespawnHintsTests: XCTestCase {
    private var file: URL!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: RespawnHintsTests.self).bundleURL.deletingLastPathComponent()
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", buildDir.path + ":" + path, 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-respawn-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("respawn.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testHintsSurviveANewStoreOverTheSameFile() {
        let id = UUID()
        let first = RespawnHintStore(file: file)
        first.record(id: id, name: "payments-retry", labels: SessionLabels(["crew": "alpha"]))

        // A new process: nothing in memory, only the file.
        let second = RespawnHintStore(file: file)
        let hints = second.take(id: id)
        XCTAssertEqual(hints?.name, "payments-retry")
        XCTAssertEqual(hints?.labels["crew"], "alpha")
        XCTAssertNil(second.take(id: id), "a respawn consumes its hints")
        XCTAssertNil(RespawnHintStore(file: file).take(id: id), "and the file agrees")
    }

    func testForgetAndAnEmptyRecordDropTheEntry() {
        let store = RespawnHintStore(file: file)
        let a = UUID()
        let b = UUID()
        store.record(id: a, name: "a", labels: SessionLabels())
        store.record(id: b, name: nil, labels: SessionLabels(["task": "x"]))
        XCTAssertEqual(store.count, 2)
        store.forget(id: a)
        XCTAssertEqual(store.count, 1)
        // Name and labels both cleared: nothing worth keeping.
        store.record(id: b, name: nil, labels: SessionLabels())
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.take(id: b))
    }

    func testAnonymousSessionsAreNotRecorded() {
        let store = RespawnHintStore(file: file)
        store.record(id: UUID(), name: nil, labels: SessionLabels())
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing to persist, no file")
    }

    func testTheFileIsCappedOldestFirst() {
        let store = RespawnHintStore(file: file)
        let oldest = UUID()
        store.record(id: oldest, name: "oldest", labels: SessionLabels())
        for _ in 0..<RespawnHintStore.maxEntries {
            store.record(id: UUID(), name: "n", labels: SessionLabels())
        }
        XCTAssertEqual(store.count, RespawnHintStore.maxEntries)
        XCTAssertNil(store.take(id: oldest), "the oldest entry is the one dropped")
    }

    func testAnUnknownFormatVersionIsIgnored() throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"version":99,"sessions":{"x":{"name":"n","labels":{},"at":1}}}"#.utf8).write(to: file)
        XCTAssertEqual(RespawnHintStore(file: file).count, 0)
    }

    /// The registry records a session as it is named and labelled, and hands
    /// the hints back only once the session is gone — a fresh registry over
    /// the same file is what a restarted daemon has.
    func testRegistryRecordsAndAFreshRegistryHandsBack() async throws {
        let tmp = NSTemporaryDirectory()
        let store = RespawnHintStore(file: file)
        let registry = SessionRegistry(respawnHints: store)
        let session = try PtySession.spawn(cols: 80, rows: 24, cwd: tmp)
        defer { session.terminate() }
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered)

        // Anonymous at spawn, then named and labelled through the PATCH path.
        XCTAssertEqual(store.count, 0)
        session.setName("retry-bug")
        await registry.nameChanged(id)
        session.updateLabels(SessionLabels(["crew": "alpha", "task": "retry-bug"]))
        await registry.labelsChanged(id)
        XCTAssertEqual(store.count, 1)

        // While the session lives, its hints are not for the taking.
        let live = await registry.takeRespawnHints(for: id)
        XCTAssertNil(live)

        // The daemon stops: sessions end, the file stays.
        await registry.terminateAll()
        let restarted = SessionRegistry(respawnHints: RespawnHintStore(file: file))
        let taken = await restarted.takeRespawnHints(for: id)
        let hints = try XCTUnwrap(taken)
        XCTAssertEqual(hints.name, "retry-bug")
        XCTAssertEqual(hints.labels.values, ["crew": "alpha", "task": "retry-bug"])
        let again = await restarted.takeRespawnHints(for: id)
        XCTAssertNil(again)
    }

    /// A session the daemon removes on purpose leaves nothing behind.
    func testRemovalForgetsTheHints() async throws {
        let store = RespawnHintStore(file: file)
        let registry = SessionRegistry(respawnHints: store)
        let session = try PtySession.spawn(
            cols: 80, rows: 24, cwd: NSTemporaryDirectory(), labels: SessionLabels(["crew": "a"])
        )
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered)
        XCTAssertEqual(store.count, 1)
        await registry.remove(id)
        XCTAssertEqual(store.count, 0)
    }

    /// A respawn is announced as one: the created event names the id the
    /// pane held, so a foreman can pair the two without matching heuristics.
    func testRespawnRidesOnTheCreatedEvent() async throws {
        let log = EventLog()
        let registry = SessionRegistry(eventLog: log)
        let session = try PtySession.spawn(cols: 80, rows: 24, cwd: NSTemporaryDirectory())
        defer { session.terminate() }
        let old = UUID()
        _ = await registry.register(session, respawnOf: old)
        let created = log.snapshot(since: 0, session: nil).events.first
        XCTAssertEqual(created?.type, "session.created")
        XCTAssertEqual(created?.data["respawnOf"], old.uuidString)
    }

    /// The merge the WebSocket handler applies: the hinted name always
    /// carries over, the hinted labels only when the request brought none.
    func testSpawnRequestMergesHints() {
        let hints = RespawnHints(name: "retry-bug", labels: SessionLabels(["crew": "alpha"]))
        let plain = WebSocketSessionHandler.spawnRequest(
            cwd: "/tmp", histKey: "h", profileName: nil, labels: SessionLabels(), hints: hints
        )
        XCTAssertEqual(plain.name, "retry-bug")
        XCTAssertEqual(plain.labels["crew"], "alpha")
        XCTAssertEqual(plain.cwd, "/tmp")
        XCTAssertEqual(plain.histKey, "h")

        let own = WebSocketSessionHandler.spawnRequest(
            cwd: nil, histKey: nil, profileName: nil, labels: SessionLabels(["crew": "beta"]), hints: hints
        )
        XCTAssertEqual(own.labels["crew"], "beta", "the request's own labels win")
        XCTAssertEqual(own.name, "retry-bug")

        let none = WebSocketSessionHandler.spawnRequest(
            cwd: nil, histKey: nil, profileName: nil, labels: SessionLabels(), hints: nil
        )
        XCTAssertNil(none.name)
        XCTAssertTrue(none.labels.isEmpty)
    }
}
