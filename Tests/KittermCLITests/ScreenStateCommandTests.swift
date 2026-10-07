import Foundation
import XCTest

@testable import KittermCLI
@testable import KittermDaemon

/// `kitterm screen-state stats [--days N] [--json]` over a scratch
/// `KITTERM_STATE_DIR`, no daemon.
final class ScreenStateCommandTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-screen-state-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func run(_ args: [String]) throws -> [String] {
        var lines: [String] = []
        try ScreenStateCommand.run(args) { lines.append($0) }
        return lines
    }

    func testNoLogPrintsOneSentence() throws {
        let lines = try run(["stats"])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("No screen-state log"), lines[0])
        XCTAssertTrue(lines[0].contains("screen-state.log"), lines[0])
    }

    func testNoLogPrintsOneSentenceEvenWithJSON() throws {
        // There is nothing to encode, so the sentence wins over --json too.
        let lines = try run(["stats", "--json"])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("No screen-state log"), lines[0])
    }

    private func seed() throws {
        ScreenStateLog.append(session: "S1", state: "prompt-empty", rule: "r", at: Date())
        ScreenStateLog.append(session: "S2", state: "working", rule: "r", at: Date())
        ScreenStateLog.append(session: "S3", state: "unknown", rule: "r", at: Date())
        ScreenStateLog.append(session: "S4", state: "unknown", rule: "r", at: Date())
    }

    func testStatsTextOverTheDefaultWindow() throws {
        try seed()
        let lines = try run(["stats"])
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("last 7 days"), text)
        XCTAssertTrue(text.contains("prompt-empty: 1"), text)
        XCTAssertTrue(text.contains("working: 1"), text)
        XCTAssertTrue(text.contains("unknown: 2"), text)
        XCTAssertTrue(text.contains("total: 4"), text)
        XCTAssertTrue(text.contains("unknown share: 50%"), text)
    }

    func testStatsRespectsDaysFlag() throws {
        try seed()
        let lines = try run(["stats", "--days", "30"])
        XCTAssertTrue(lines.joined(separator: "\n").contains("last 30 days"))
    }

    func testStatsJSON() throws {
        try seed()
        let lines = try run(["stats", "--json"])
        XCTAssertEqual(lines.count, 1)
        let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertEqual(object?["total"] as? Int, 4)
        XCTAssertEqual(object?["unknownSharePercent"] as? Int, 50)
        let counts = object?["counts"] as? [String: Int]
        XCTAssertEqual(counts?["unknown"], 2)
    }

    func testBadDaysValueIsAUsageError() throws {
        XCTAssertThrowsError(try run(["stats", "--days", "0"])) { error in
            XCTAssertTrue("\(error)".contains("usage"))
        }
        XCTAssertThrowsError(try run(["stats", "--days", "nope"]))
    }

    func testUnknownSubcommandIsAUsageError() {
        XCTAssertThrowsError(try run(["bogus"]))
    }

    /// A rotated-only log (the current file just rotated away) still
    /// answers: the command checks both paths before reporting "no log".
    func testARotatedOnlyLogStillAnswers() throws {
        let rotatedURL = DaemonPaths.screenStateLogFile.deletingLastPathComponent()
            .appendingPathComponent("screen-state.log.1")
        let line = try ScreenStateLog.line(at: Date(), session: "S1", state: "working", rule: "r")
        try (line + "\n").write(to: rotatedURL, atomically: true, encoding: .utf8)
        let lines = try run(["stats"])
        XCTAssertFalse(lines.joined(separator: "\n").contains("No screen-state log"))
        XCTAssertTrue(lines.joined(separator: "\n").contains("working: 1"))
    }
}
