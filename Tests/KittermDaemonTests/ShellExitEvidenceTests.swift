import Foundation
import KittermProtocol
import NIOCore
import XCTest

@testable import KittermDaemon

/// A node that crashed is the one a caller most wants to inspect, so a
/// program-created session outlives its shell: its commands, exit codes and
/// retained output stay readable for the linger window.
///
/// A browser tab's session still goes immediately — nobody wants a corpse in
/// the fleet view.
final class ShellExitEvidenceTests: XCTestCase {
    private var sessions: [PtySession] = []

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: ShellExitEvidenceTests.self)
            .bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func tearDownWithError() throws {
        for session in sessions { session.terminate() }
        sessions = []
    }

    private func makeSession(labels: String? = nil) throws -> PtySession {
        let session = try PtySession.spawn(
            cwd: NSTemporaryDirectory(),
            labels: SessionLabels.parse(labels)
        )
        sessions.append(session)
        return session
    }

    /// One finished command, so there is something to lose.
    private func feedOneCommand(_ session: PtySession, exit code: Int) {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeString("\u{1b}]633;E;make test\u{07}\u{1b}]133;C\u{07}boom\u{1b}]133;D;\(code)\u{07}")
        session.handleRead(&buffer)
    }

    func testLabelledSessionKeepsItsRecordsAfterItsShellExits() async throws {
        let registry = SessionRegistry()
        let session = try makeSession(labels: "run:alpha,node:test")
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered)
        feedOneCommand(session, exit: 1)

        session.terminate()  // the shell dies
        await registry.sessionDidExit(id)

        let kept = await registry.session(id)
        XCTAssertNotNil(kept, "a labelled session must outlive its shell")
        let commands = try XCTUnwrap(kept?.commandsSnapshot())
        XCTAssertEqual(commands.first?.exit, 1, "the failure is still readable")
        XCTAssertEqual(commands.first?.command, "make test")
    }

    /// The fleet view should not fill with dead tabs.
    func testUnlabelledSessionStillGoesImmediately() async throws {
        let registry = SessionRegistry()
        let session = try makeSession()
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered)

        session.terminate()
        await registry.sessionDidExit(id)

        let count = await registry.count
        XCTAssertEqual(count, 0, "a browser session dies with its shell, as before")
    }

    /// Reading a dead session must not reap it — `resolve` used to remove any
    /// session whose shell had gone, which would delete the records on the
    /// first look.
    func testResolvingADeadSessionDoesNotDestroyIt() async throws {
        let registry = SessionRegistry()
        let session = try makeSession(labels: "run:alpha")
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered)
        feedOneCommand(session, exit: 3)
        session.terminate()
        await registry.sessionDidExit(id)

        let resolution = await registry.resolve(id)
        guard case .notFound = resolution else {
            return XCTFail("a dead session must not be attachable")
        }
        let stillThere = await registry.session(id)
        XCTAssertNotNil(stillThere, "looking at it must not reap it")
        XCTAssertEqual(stillThere?.commandsSnapshot().first?.exit, 3)
    }

    func testSummaryReportsTheExit() async throws {
        let registry = SessionRegistry()
        let session = try makeSession(labels: "run:alpha")
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered)
        session.terminate()
        await registry.sessionDidExit(id)

        let summaries = await registry.summaries()
        let summary = try XCTUnwrap(summaries.first { $0.id == id })
        XCTAssertTrue(summary.exited, "a caller must be able to tell it is dead")
    }

    /// Retained output has to survive the shell too, which means `terminate()`
    /// can no longer be what deletes the file.
    func testRetainedOutputSurvivesTheShell() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-exit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try makeSession(labels: "run:alpha")
        let sessionID = UUID()
        var store: SessionLogStore?
        session.attachLogStore { origin in
            store = SessionLogStore(
                directory: directory, sessionID: sessionID,
                maxBytes: 1024 * 1024, origin: origin
            )
            return store
        }
        let offset = session.logHead
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        buffer.writeString("LAST-WORDS")
        session.handleRead(&buffer)

        session.terminate()

        // `wait(for:)` below is the happens-before the compiler cannot see.
        nonisolated(unsafe) var result: PtySession.OutputRange?
        let done = expectation(description: "read after exit")
        session.outputRange(from: offset, to: offset + 10, maxBytes: 1024) { range in
            result = range
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(String(decoding: try XCTUnwrap(result).data, as: UTF8.self), "LAST-WORDS")

        // And it is gone once the session is actually reaped. Drain through the
        // store itself: the session no longer holds it, so reading through the
        // session would not wait for the delete to land.
        session.discardRetainedOutput()
        let drained = expectation(description: "delete landed")
        try XCTUnwrap(store).read(from: 0, to: 1) { _, _ in drained.fulfill() }
        wait(for: [drained], timeout: 10)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path), [],
            "retained output must not outlive the session itself"
        )
    }
}
