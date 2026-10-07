import Foundation
import XCTest

@testable import KittermCLI

/// `ScreenStateLog`, the bounded local log one `screen_state` answer appends
/// a line to (`goal.md` condition 3). Every test points `append`/`line` at a
/// scratch file so the real `~/.kitterm` is never touched.
final class ScreenStateLogTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-screen-state-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("screen-state.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - the line's shape

    func testLineHoldsExactlyTheFiveFields() throws {
        let text = try ScreenStateLog.line(
            at: Self.fixedDate, session: "S1", state: "prompt-empty",
            rule: "prompt-empty: \"❯\" at the cursor, empty or a dim placeholder"
        )
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["at", "session", "state", "rule", "source"])
        XCTAssertEqual(object?["session"] as? String, "S1")
        XCTAssertEqual(object?["state"] as? String, "prompt-empty")
        XCTAssertEqual(object?["source"] as? String, "rules")
        XCTAssertEqual(ScreenStateLog.parseDate(object?["at"] as? String ?? ""), Self.fixedDate)
    }

    /// No screen text and no matched line's text ever land in the log: a
    /// rule's name may describe a marker, but the rendered screen and the
    /// row the rule matched — either of which can hold a user's own typed
    /// input — are never passed to `line`.
    func testTheLineCarriesNoScreenTextAndNoLineText() throws {
        let screenText = "the quick brown fox typed a secret"
        let text = try ScreenStateLog.line(
            at: Self.fixedDate, session: "S1", state: "prompt-has-text",
            rule: "prompt-has-text: \"❯\" at the cursor with typed text"
        )
        XCTAssertFalse(text.contains(screenText))
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertNil(object?["line"])
        XCTAssertNil(object?["text"])
        XCTAssertNil(object?["screen"])
    }

    // MARK: - append

    func testAppendCreatesTheFileAt0600() throws {
        ScreenStateLog.append(session: "S1", state: "working", rule: "r", at: Self.fixedDate, to: fileURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAppendAddsOneLineAndKeepsTheMode() throws {
        ScreenStateLog.append(session: "S1", state: "working", rule: "r1", at: Self.fixedDate, to: fileURL)
        ScreenStateLog.append(session: "S2", state: "unknown", rule: "r2", at: Self.fixedDate, to: fileURL)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertFalse(line.hasSuffix("\n"))
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - rotation

    func testRotatesPast1MiBKeepingOneOldFile() throws {
        // One line padded well past 1 MiB so a single append both exceeds
        // the bound and starts the rotation on its own next call.
        let padding = String(repeating: "x", count: 1200)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(padding.utf8).write(to: fileURL)
        while (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0)
            < ScreenStateLog.maxBytes {
            try Data((padding + "\n").utf8).append(to: fileURL)
        }
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int
        XCTAssertNotNil(sizeBefore)
        XCTAssertGreaterThanOrEqual(sizeBefore!, ScreenStateLog.maxBytes)

        ScreenStateLog.append(session: "S1", state: "working", rule: "r1", at: Self.fixedDate, to: fileURL)

        let rotated = dir.appendingPathComponent("screen-state.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        let rotatedSize = try FileManager.default.attributesOfItem(atPath: rotated.path)[.size] as? Int
        XCTAssertEqual(rotatedSize, sizeBefore)

        let freshContents = try String(contentsOf: fileURL, encoding: .utf8)
        let freshLines = freshContents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(freshLines.count, 1)

        let freshAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((freshAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// One rotated file is the bound: a second rotation drops the first
    /// `.1` rather than keeping two.
    func testASecondRotationKeepsOnlyOneOldFile() throws {
        let big = Data(String(repeating: "a", count: ScreenStateLog.maxBytes + 10).utf8)
        try big.write(to: fileURL)
        ScreenStateLog.append(session: "first", state: "working", rule: "r", at: Self.fixedDate, to: fileURL)
        let rotated = dir.appendingPathComponent("screen-state.log.1")
        let firstRotatedSize = try FileManager.default.attributesOfItem(atPath: rotated.path)[.size] as? Int
        XCTAssertEqual(firstRotatedSize, big.count)

        let secondBig = Data(String(repeating: "b", count: ScreenStateLog.maxBytes + 20).utf8)
        try secondBig.write(to: fileURL)
        ScreenStateLog.append(session: "second", state: "unknown", rule: "r", at: Self.fixedDate, to: fileURL)
        let secondRotatedSize = try FileManager.default.attributesOfItem(atPath: rotated.path)[.size] as? Int
        XCTAssertEqual(secondRotatedSize, secondBig.count)
        XCTAssertNotEqual(secondRotatedSize, firstRotatedSize)
    }

    // MARK: - a failed write never fails the tool

    /// `append` swallows every error: a directory in the log's place makes
    /// every file operation fail, and the call still returns normally.
    func testAppendSwallowsAFailedWrite() throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        ScreenStateLog.append(session: "S1", state: "working", rule: "r", at: Self.fixedDate, to: fileURL)
        // No crash, no thrown error reaches the caller; the path is still a
        // directory, not a log file.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testAppendOrThrowActuallyThrowsOnTheSameFailure() throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try ScreenStateLog.appendOrThrow(
                session: "S1", state: "working", rule: "r", at: Self.fixedDate, to: fileURL
            )
        )
    }
}

extension Data {
    fileprivate func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
