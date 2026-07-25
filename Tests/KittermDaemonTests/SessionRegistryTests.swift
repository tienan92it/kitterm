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
        let id = await registry.register(session)

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
        let id = await registry.register(session)

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
}
