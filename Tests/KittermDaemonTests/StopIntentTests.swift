import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// The word the CLI leaves for the signal it is about to send (`StopIntent`,
/// `~/.kitterm/stop-intent.json`), and how the daemon's stop path reads it
/// into `last-run.json`.
///
/// The intent is bound to one signal by the pid it names and by its age, and
/// it is deleted on every read. So a leftover file from a restart the daemon
/// never got to record cannot label a later stop, or a later kill,
/// `restarted`.
final class StopIntentTests: XCTestCase {
    private var stateDir: URL!
    private let now = Date(timeIntervalSince1970: 1_758_800_000)

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-stop-intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private var file: URL { stateDir.appendingPathComponent("stop-intent.json") }
    private var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    // MARK: - The intent alone

    func testAnIntentForThisPidAnswersItsReasonAndIsDeleted() {
        StopIntent.write(.restarted, pid: 4242, to: file, now: now)
        XCTAssertTrue(exists)

        XCTAssertEqual(StopIntent.consume(from: file, pid: 4242, now: now.addingTimeInterval(1)), .restarted)
        XCTAssertFalse(exists, "the read consumes the file")
    }

    func testAnIntentForAnotherPidAnswersNothingAndIsStillDeleted() {
        StopIntent.write(.restarted, pid: 4242, to: file, now: now)

        XCTAssertNil(StopIntent.consume(from: file, pid: 4243, now: now))
        XCTAssertFalse(exists, "a refused intent must not wait for a pid it matches later")
    }

    /// A pid can be reused, so age binds the file too: the signal follows the
    /// write within a second, and a minute is already generous.
    func testAStaleIntentAnswersNothing() {
        StopIntent.write(.restarted, pid: 4242, to: file, now: now)

        let late = now.addingTimeInterval(TimeInterval(StopIntent.maxAgeSeconds) + 1)
        XCTAssertNil(StopIntent.consume(from: file, pid: 4242, now: late))
        XCTAssertFalse(exists)
    }

    func testAnIntentAtTheAgeLimitStillCounts() {
        StopIntent.write(.restarted, pid: 4242, to: file, now: now)

        let edge = now.addingTimeInterval(TimeInterval(StopIntent.maxAgeSeconds))
        XCTAssertEqual(StopIntent.consume(from: file, pid: 4242, now: edge), .restarted)
    }

    /// A clock that went backwards makes a future intent; refuse it rather
    /// than trust a write that has not happened yet.
    func testAnIntentFromTheFutureAnswersNothing() {
        StopIntent.write(.restarted, pid: 4242, to: file, now: now.addingTimeInterval(5))

        XCTAssertNil(StopIntent.consume(from: file, pid: 4242, now: now))
    }

    func testNoFileAnswersNothing() {
        XCTAssertNil(StopIntent.consume(from: file, pid: 4242, now: now))
    }

    func testAConsumedIntentDecidesOnlyOnce() {
        StopIntent.write(.restarted, pid: 4242, to: file, now: now)

        XCTAssertEqual(StopIntent.consume(from: file, pid: 4242, now: now), .restarted)
        XCTAssertNil(StopIntent.consume(from: file, pid: 4242, now: now))
    }

    /// A version this build does not know is refused and removed, like a
    /// `last-run.json` of another version is refused.
    func testAnUnknownFormatVersionAnswersNothing() throws {
        let future = StopIntent(
            version: StopIntent.formatVersion + 1, pid: 4242, reason: .restarted,
            writtenAt: LastRunStore.milliseconds(now)
        )
        try JSONEncoder().encode(future).write(to: file)

        XCTAssertNil(StopIntent.consume(from: file, pid: 4242, now: now))
        XCTAssertFalse(exists)
    }

    func testAFileThatIsNotAnIntentAnswersNothing() throws {
        try Data("restart please".utf8).write(to: file)

        XCTAssertNil(StopIntent.consume(from: file, pid: 4242, now: now))
        XCTAssertFalse(exists)
    }

    func testTheFileIsSortedJsonOfFourFields() throws {
        StopIntent.write(.restarted, pid: 4242, to: file, now: now)

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, #"{"pid":4242,"reason":"restarted","version":1,"writtenAt":1758800000000}"#)
    }

    // MARK: - The stop path

    /// `DaemonServer.stop()` is what the SIGTERM handler runs. With an intent
    /// for this process on disk, the ending reads `restarted`; the intent is
    /// gone afterwards.
    func testTheStopPathRecordsRestartedWhenTheIntentNamesThisPid() throws {
        try withScratchStateDirectory()
        let store = LastRunStore(file: stateDir.appendingPathComponent("last-run.json"))
        store.beginRun()
        StopIntent.write(.restarted, pid: getpid(), to: DaemonPaths.stopIntentFile)

        let server = DaemonServer(config: DaemonConfig(port: 0), lastRun: store)
        try server.start()
        try server.stop()

        let record = try XCTUnwrap(LastRunStore.read(stateDir.appendingPathComponent("last-run.json")))
        XCTAssertEqual(record.reason, .restarted)
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(record.outcome, .clean, "the feed's `previous` stays `clean` for a restart")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: DaemonPaths.stopIntentFile.path),
            "the stop consumed the intent"
        )
    }

    /// An intent left by a restart of some other run — another pid — must not
    /// relabel this stop. It is `stopped`, and the leftover is cleared.
    func testTheStopPathRecordsStoppedWhenTheIntentNamesAnotherPid() throws {
        try withScratchStateDirectory()
        let store = LastRunStore(file: stateDir.appendingPathComponent("last-run.json"))
        store.beginRun()
        // pid 1 is launchd's, never a test's.
        StopIntent.write(.restarted, pid: 1, to: DaemonPaths.stopIntentFile)

        let server = DaemonServer(config: DaemonConfig(port: 0), lastRun: store)
        try server.start()
        try server.stop()

        let record = try XCTUnwrap(LastRunStore.read(stateDir.appendingPathComponent("last-run.json")))
        XCTAssertEqual(record.reason, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DaemonPaths.stopIntentFile.path))
    }

    // MARK: - Helpers

    /// Point `DaemonPaths` at the scratch directory, so the server under test
    /// reads its intent and writes its files there and not in `~/.kitterm`.
    private func withScratchStateDirectory() throws {
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        addTeardownBlock { unsetenv("KITTERM_STATE_DIR") }
        setenv("SHELL", "/bin/sh", 1)
    }
}
