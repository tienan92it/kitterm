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

        var summaries = await registry.summaries()
        XCTAssertEqual(summaries.count, 1)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.shell, session.shellPath)
        XCTAssertEqual(summary.pid, session.pid)
        XCTAssertTrue(summary.attached)
        XCTAssertEqual(summary.observerCount, 0)
        XCTAssertEqual(summary.marks.count, 2)

        // The cwd is a live kernel read, not the attach-gated poll — a never-
        // attached session must still report where its shell actually is.
        // Resolve symlinks on both sides: the kernel reports the real path
        // (/private/var/…) where NSTemporaryDirectory says /var/….
        let reported = URL(fileURLWithPath: summary.cwd).resolvingSymlinksInPath().path
        let expected = URL(fileURLWithPath: tmp).resolvingSymlinksInPath().path
        XCTAssertEqual(reported, expected)

        await registry.markDetached(id)
        summaries = await registry.summaries()
        XCTAssertFalse(try XCTUnwrap(summaries.first).attached)

        await registry.remove(id)
        let empty = await registry.summaries()
        XCTAssertTrue(empty.isEmpty)
    }
}
