import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// `SessionRegistry.summaries()` — the data behind `/api/sessions`.
final class SessionRegistryTests: XCTestCase {
    override class func setUp() {
        super.setUp()

        // Same environment pinning as PtySessionTests: find the spawn helper
        // next to the test bundle, and keep shell startup fast and identical
        // everywhere.
        let buildDir = Bundle(for: SessionRegistryTests.self).bundleURL.deletingLastPathComponent()
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", buildDir.path + ":" + path, 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    func testSummariesReflectSessionState() async throws {
        let registry = SessionRegistry()
        let tmp = NSTemporaryDirectory()
        let session = try PtySession.spawn(cols: 80, rows: 24, cwd: tmp)
        defer { session.terminate() }
        let id = await registry.register(session)!

        session.appendMark(SessionMark(offset: 0, kind: .preExec, exit: nil, command: "ls"))
        session.appendMark(SessionMark(offset: 1, kind: .commandEnd, exit: 0, command: nil))

        let first = await registry.summaries()
        let summary = try XCTUnwrap(first.first)
        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.shell, session.shellPath)
        XCTAssertEqual(summary.pid, session.pid)
        XCTAssertTrue(summary.attached)
        XCTAssertEqual(summary.observerCount, 0)
        XCTAssertEqual(summary.marks.count, 2)

        // The cwd is a live kernel read, not the attach-gated poll — a never-
        // attached session must still report where its shell actually is.
        // Resolve symlinks on both sides: the kernel reports the real path
        // (/private/var/…) where NSTemporaryDirectory says /var/…. Poll for the
        // shell to settle: the spawn helper chdir's to the requested cwd after
        // posix_spawn, so `liveCwd` reads the inherited dir for the first
        // moments after spawn.
        let expected = URL(fileURLWithPath: tmp).resolvingSymlinksInPath().path
        var reported = ""
        for _ in 0..<50 {
            let polled = await registry.summaries()
            reported = URL(fileURLWithPath: try XCTUnwrap(polled.first).cwd)
                .resolvingSymlinksInPath().path
            if reported == expected { break }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
        XCTAssertEqual(reported, expected, "shell should settle into its spawn cwd")

        await registry.markDetached(id)
        let afterDetach = await registry.summaries()
        XCTAssertFalse(try XCTUnwrap(afterDetach.first).attached)

        await registry.remove(id)
        let empty = await registry.summaries()
        XCTAssertTrue(empty.isEmpty)
    }

    /// Control-handoff bookkeeping: after a promoted observer claims control,
    /// the session counts as attached again (a later joiner becomes an
    /// observer, not a second controller) and any linger clock stops.
    func testClaimControlReattachesADetachedSession() async throws {
        let registry = SessionRegistry()
        let session = try PtySession.spawn(cols: 80, rows: 24, cwd: NSTemporaryDirectory())
        defer { session.terminate() }
        let id = await registry.register(session)!

        await registry.markDetached(id)
        let detached = await registry.summaries()
        XCTAssertFalse(try XCTUnwrap(detached.first).attached)

        await registry.claimControl(id)
        let claimed = await registry.summaries()
        XCTAssertTrue(try XCTUnwrap(claimed.first).attached)

        // The next connection resolves as observer — the claim holds.
        guard case .observer = await registry.resolve(id) else {
            return XCTFail("expected .observer after claimControl")
        }
    }

    func testClaimControlOnUnknownSessionIsANoOp() async {
        let registry = SessionRegistry()
        await registry.claimControl(UUID())
        let count = await registry.count
        XCTAssertEqual(count, 0)
    }

    /// The ceiling is the only thing standing between a crash-looping caller
    /// and an unbounded pile of shells — program-created sessions are now held
    /// for an hour after their client goes away.
    func testRegistrationStopsAtTheSessionCeiling() async throws {
        let registry = SessionRegistry()
        var spawned: [PtySession] = []
        defer { for session in spawned { session.terminate() } }

        for _ in 0..<KittermConstants.maxConcurrentSessions {
            let session = try PtySession.spawn(cwd: NSTemporaryDirectory())
            spawned.append(session)
            let id = await registry.register(session)
            XCTAssertNotNil(id, "under the ceiling every session is admitted")
        }
        let overflow = try PtySession.spawn(cwd: NSTemporaryDirectory())
        spawned.append(overflow)
        let refused = await registry.register(overflow)
        XCTAssertNil(refused, "past the ceiling the registry must refuse")

        // Freeing one makes room again, so the cap is a ceiling and not a
        // one-way latch.
        let count = await registry.count
        XCTAssertEqual(count, KittermConstants.maxConcurrentSessions)
    }

    /// An API-spawned session starts detached with its linger clock running:
    /// if no client ever joins, it must still be reaped, not leak forever.
    func testRegisterDetachedReapsAnUnjoinedSession() async throws {
        let registry = SessionRegistry(orchestratedLingerSeconds: 1)
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        defer { session.terminate() }
        let id = await registry.registerDetached(session)
        XCTAssertNotNil(id)

        let listed = await registry.summaries()
        XCTAssertFalse(try XCTUnwrap(listed.first).attached)

        // Past the window with nobody attached, the session is reaped.
        try await Task.sleep(for: .seconds(2), clock: .suspending)
        let count = await registry.count
        XCTAssertEqual(count, 0, "an unjoined API session must not outlive its linger window")
    }

    /// The first browser to open an API-spawned session's link becomes its
    /// controller — `register` would have marked it attached at birth and
    /// demoted that first join to observer.
    func testFirstJoinOfADetachedSessionIsController() async throws {
        let registry = SessionRegistry()
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        defer { session.terminate() }
        let registered = await registry.registerDetached(session)
        let id = try XCTUnwrap(registered)

        guard case .controller = await registry.resolve(id) else {
            return XCTFail("expected the first join to resolve as controller")
        }
        guard case .observer = await registry.resolve(id) else {
            return XCTFail("expected the second join to resolve as observer")
        }
    }

    /// Labels are PATCH-replaceable, and the linger window follows them. A
    /// browser session (5 min clock armed) that a program adopts by adding
    /// labels must get the orchestrated hour, not die on the tab's clock.
    func testLabelChangeReArmsTheLingerClock() async throws {
        // 1s browser-style window would be `sessionDetachLingerSeconds`; use a
        // tiny orchestrated window instead and prove the *other* direction:
        // removing labels from a detached orchestrated session re-arms it
        // with the short window, so it is reaped when the labels say tab.
        let registry = SessionRegistry(orchestratedLingerSeconds: 30)
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse("run:x"))
        defer { session.terminate() }
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered)
        await registry.markDetached(id)  // arms the 30s orchestrated window

        // Adopt-the-other-way: the program releases it. Clear labels, notify.
        session.updateLabels(SessionLabels())
        await registry.labelsChanged(id)
        // Re-armed with the browser window (300s) — still present well within
        // the old 30s, and still present at all: the point is the re-arm ran
        // without reaping, and the session remains resolvable.
        let count = await registry.count
        XCTAssertEqual(count, 1)
        guard case .controller = await registry.resolve(id) else {
            return XCTFail("a re-armed detached session is still attachable")
        }
    }

    /// `spawnedByAPI` grants orchestrated semantics without labels: the shell's
    /// exit keeps the session readable instead of reaping it like a browser
    /// tab's.
    func testAPISpawnedSessionSurvivesShellExit() async throws {
        let registry = SessionRegistry()
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        defer { session.terminate() }
        let registered = await registry.registerDetached(session)
        let id = try XCTUnwrap(registered)

        await registry.sessionDidExit(id)
        let count = await registry.count
        XCTAssertEqual(count, 1, "an API session outlives its shell for the linger window")
    }
}
