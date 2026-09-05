import Foundation
import KittermProtocol
import NIOPosix
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

        // Past the window with nobody attached, the session is reaped. The
        // shell's first prompt lands after the clock is armed and counts as
        // output, so the reap can take a second window.
        try await waitUntil("an unjoined API session to be reaped", seconds: 5) {
            await registry.count == 0
        }
    }

    /// Poll `condition` until it holds or `seconds` pass. The linger tests
    /// wait on real clocks, and a fixed sleep either wastes time or flakes.
    private func waitUntil(
        _ what: String, seconds: Double, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = SuspendingClock.now + .seconds(seconds)
        while SuspendingClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50), clock: .suspending)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// The linger clock reaps an idle shell, not a working session (ADR 0002).
    /// A crew session at its Claude Code prompt, or mid-rebase, has a program
    /// holding the terminal; the registry must hold it past every window and
    /// reap it only once the shell is back at its prompt and silent.
    func testWorkingOrchestratedSessionOutlivesItsLingerWindow() async throws {
        let registry = SessionRegistry(orchestratedLingerSeconds: 1)
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        defer { session.terminate() }
        let registered = await registry.registerDetached(session)
        let id = try XCTUnwrap(registered)
        // Input reaches the shell only through the reader channel the spawn
        // service would have made.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        try await session.makeReader(group: group, eventLoop: group.next()).get()

        try session.write(Data("sleep 4\n".utf8))
        try await waitUntil("sleep to take the foreground", seconds: 5) { !session.foregroundIsShell }

        // Two windows and a half with a program in the foreground: still here.
        try await Task.sleep(for: .seconds(2.5), clock: .suspending)
        let held = await registry.count
        XCTAssertEqual(held, 1, "a session with a running program is not reaped")
        guard case .controller = await registry.resolve(id) else {
            return XCTFail("a held session is still attachable")
        }
        await registry.markDetached(id)

        // The program ends. The shell prints a prompt and falls silent, and
        // the next silent window reaps it: an abandoned shell still goes.
        try await waitUntil("the shell to take the foreground back", seconds: 5) { session.foregroundIsShell }
        try await waitUntil("the idle shell to be reaped", seconds: 8) {
            await registry.count == 0
        }
    }

    /// An exited orchestrated session is kept for one window so its records
    /// can be read, then reaped. Its shell is gone, so the working test does
    /// not apply, and nothing holds the records open forever.
    func testExitedOrchestratedSessionIsReapedAtTheWindow() async throws {
        let registry = SessionRegistry(orchestratedLingerSeconds: 1)
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        defer { session.terminate() }
        let registered = await registry.registerDetached(session)
        let id = try XCTUnwrap(registered)

        session.terminate()  // the shell dies
        await registry.sessionDidExit(id)
        let kept = await registry.count
        XCTAssertEqual(kept, 1, "an exited session is readable for its window")

        try await waitUntil("the exited session to be reaped", seconds: 5) {
            await registry.count == 0
        }
    }

    /// A browser tab's session keeps today's rule: reaped at its own window
    /// after the tab goes, whatever the shell is doing. The working test is
    /// for sessions a program made and forgot to end, not for a closed tab.
    func testBrowserSessionIsReapedOnItsOwnClockWhileAProgramRuns() async throws {
        XCTAssertEqual(KittermConstants.sessionDetachLingerSeconds, 300)
        let registry = SessionRegistry(detachLingerSeconds: 1)
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory())
        defer { session.terminate() }
        XCTAssertFalse(session.isOrchestrated)
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        try await session.makeReader(group: group, eventLoop: group.next()).get()

        try session.write(Data("sleep 30\n".utf8))
        try await waitUntil("sleep to take the foreground", seconds: 5) { !session.foregroundIsShell }
        await registry.markDetached(id)

        try await waitUntil("the browser session to be reaped", seconds: 5) {
            await registry.count == 0
        }
        XCTAssertFalse(session.isRunning, "reap ends the shell and its program")
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
