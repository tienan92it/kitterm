import Darwin
import Foundation
import XCTest

@testable import KittermDaemon

/// The `Last login:` banner. Formatting and the timestamp rotation are pure
/// enough to assert exactly; the banner is written into a real pty by
/// `PtySession.spawn`, which the end-to-end test there covers.
final class LastLoginTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-lastlogin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Formatting

    func testMatchesTheNativeLoginFormat() {
        // 2026-07-22 18:04:25 UTC, a Wednesday.
        let date = Date(timeIntervalSince1970: 1_784_743_465)
        let line = LastLogin.formatted(date, tty: "ttys073", calendar: utcCalendar())
        XCTAssertEqual(line, "Last login: Wed Jul 22 18:04:25 on ttys073\r\n")
    }

    func testPadsSingleDigitDaysLikeLogin() {
        // 2026-07-02 09:05:03 UTC — login(1) uses %e, so the day is space-padded.
        let date = Date(timeIntervalSince1970: 1_782_983_103)
        let line = LastLogin.formatted(date, tty: "ttys001", calendar: utcCalendar())
        XCTAssertEqual(line, "Last login: Thu Jul  2 09:05:03 on ttys001\r\n")
    }

    func testTerminatesWithCRLFSoThePromptStartsAtColumnZero() {
        let line = LastLogin.formatted(Date(), tty: "ttys000", calendar: utcCalendar())
        XCTAssertTrue(line.hasSuffix("\r\n"))
    }

    // MARK: TTY naming

    func testStripsDevPrefixFromTheTtyName() throws {
        var primary: Int32 = -1
        var replica: Int32 = -1
        guard openpty(&primary, &replica, nil, nil, nil) == 0 else {
            throw XCTSkip("openpty unavailable")
        }
        defer {
            close(primary)
            close(replica)
        }
        let name = try XCTUnwrap(LastLogin.ttyName(forSlave: replica))
        XCTAssertFalse(name.hasPrefix("/dev/"), "expected a bare name, got \(name)")
        XCTAssertTrue(name.hasPrefix("tty"), "expected a tty name, got \(name)")
    }

    func testReturnsNilForANonTtyDescriptor() {
        // A pipe is not a terminal, so there is no name to report.
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        XCTAssertNil(LastLogin.ttyName(forSlave: fds[0]))
    }

    // MARK: Rotation

    func testFirstSessionHasNoPreviousLoginToReport() {
        let file = tempDir.appendingPathComponent("lastlogin")
        XCTAssertNil(LastLogin.rotate(file: file))
    }

    func testSecondSessionReportsTheFirst() {
        let file = tempDir.appendingPathComponent("lastlogin")
        let first = Date(timeIntervalSince1970: 1_784_743_465)

        XCTAssertNil(LastLogin.rotate(now: first, file: file))
        let previous = LastLogin.rotate(now: first.addingTimeInterval(3600), file: file)

        XCTAssertEqual(previous?.timeIntervalSince1970 ?? 0, first.timeIntervalSince1970, accuracy: 1)
    }

    func testEachSessionRotatesForward() {
        let file = tempDir.appendingPathComponent("lastlogin")
        let base = Date(timeIntervalSince1970: 1_784_743_465)

        _ = LastLogin.rotate(now: base, file: file)
        _ = LastLogin.rotate(now: base.addingTimeInterval(60), file: file)
        let third = LastLogin.rotate(now: base.addingTimeInterval(120), file: file)

        // The second session's time, not the first.
        XCTAssertEqual(
            third?.timeIntervalSince1970 ?? 0,
            base.addingTimeInterval(60).timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testCorruptTimestampIsTreatedAsNoPreviousSession() throws {
        let file = tempDir.appendingPathComponent("lastlogin")
        try "not a number".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(LastLogin.rotate(file: file))
    }

    func testCreatesTheStateDirectoryIfMissing() {
        let file = tempDir
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("lastlogin")
        _ = LastLogin.rotate(file: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: hushlogin

    func testHushloginSuppressesTheBanner() throws {
        XCTAssertFalse(LastLogin.isHushed(home: tempDir))
        try Data().write(to: tempDir.appendingPathComponent(".hushlogin"))
        XCTAssertTrue(LastLogin.isHushed(home: tempDir))
    }
}
