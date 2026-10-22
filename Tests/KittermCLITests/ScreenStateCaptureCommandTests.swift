import Foundation
import XCTest

@testable import KittermCLI
@testable import KittermDaemon

/// `kitterm screen-state capture on|off|status`, `samples [--print N]
/// [--json] [--clear]`, and the samples line `stats` prints, over a scratch
/// `KITTERM_STATE_DIR` with no daemon.
final class ScreenStateCaptureCommandTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-screen-capture-cmd-\(UUID().uuidString)", isDirectory: true)
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

    private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(session: String, offset: TimeInterval, lines: [String] = ["❯ something odd"]) -> ScreenStateCapture.Sample {
        ScreenStateCapture.Sample(
            at: Self.fixedDate.addingTimeInterval(offset), session: session, state: .unknown,
            rule: "unknown: no rule matched", foregroundProgram: "claude", cols: 100, rows: 30, lines: lines
        )
    }

    // MARK: - capture

    func testCaptureOnOffStatusRoundTrip() throws {
        XCTAssertEqual(try run(["capture", "status"]), ["capture: off"])

        let on = try run(["capture", "on"])
        XCTAssertEqual(on.count, 2)
        XCTAssertTrue(on[0].hasPrefix("capture: on ("), on[0])
        XCTAssertTrue(on[0].contains("screen-state.json"), on[0])
        XCTAssertTrue(on[1].contains("never leave this machine"), on[1])
        XCTAssertEqual(try run(["capture", "status"]), ["capture: on"])
        let file = stateDir.appendingPathComponent("screen-state.json")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\"captureUnknown\":true}")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(ScreenStateCapture.Settings.read().captureUnknown)

        let off = try run(["capture", "off"])
        XCTAssertEqual(off.count, 1)
        XCTAssertTrue(off[0].hasPrefix("capture: off ("), off[0])
        XCTAssertEqual(try run(["capture", "status"]), ["capture: off"])
        XCTAssertFalse(ScreenStateCapture.Settings.read().captureUnknown)
    }

    func testCaptureWithoutAWordOrWithAnotherWordIsAUsageError() {
        XCTAssertThrowsError(try run(["capture"]))
        XCTAssertThrowsError(try run(["capture", "maybe"]))
        XCTAssertThrowsError(try run(["capture", "on", "off"]))
    }

    /// The bridge's default paths are the ones the command writes and reads:
    /// a switch turned on by the command makes `capture` write, and the
    /// command then lists that file.
    func testTheCommandAndTheBridgeShareThePaths() throws {
        _ = try run(["capture", "on"])
        ScreenStateCapture.capture(sample(session: "S1", offset: 0))
        let entries = try ScreenStateCapture.samples()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].url.path.hasPrefix(stateDir.appendingPathComponent("screen-unknown").path))
        XCTAssertEqual(try run(["samples"]).count, 1)
    }

    // MARK: - samples

    func testNoSamplesPrintsOneSentence() throws {
        let lines = try run(["samples"])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("No samples in "), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("(capture off)."), lines[0])
    }

    func testSamplesListsNewestFirst() throws {
        try ScreenStateCapture.write(sample(session: "S-OLD", offset: 0), in: DaemonPaths.screenUnknownDirectory)
        try ScreenStateCapture.write(sample(session: "S-NEW", offset: 90), in: DaemonPaths.screenUnknownDirectory)
        let lines = try run(["samples"])
        XCTAssertEqual(lines.count, 2)
        let newest = lines[0].split(separator: "\t").map(String.init)
        XCTAssertEqual(newest[0], "1")
        XCTAssertEqual(newest[1], "2027-01-15T08:01:30.000Z")
        XCTAssertEqual(newest[2], "S-NEW")
        XCTAssertEqual(newest[3], "claude")
        XCTAssertEqual(newest[4], "100x30")
        XCTAssertTrue(newest[5].hasSuffix(" bytes"), newest[5])
        let oldest = lines[1].split(separator: "\t").map(String.init)
        XCTAssertEqual(oldest[0], "2")
        XCTAssertEqual(oldest[2], "S-OLD")
    }

    func testSamplesPrintsTheNthNewestFirst() throws {
        try ScreenStateCapture.write(sample(session: "S-OLD", offset: 0, lines: ["old screen"]), in: DaemonPaths.screenUnknownDirectory)
        try ScreenStateCapture.write(sample(session: "S-NEW", offset: 90, lines: ["new screen"]), in: DaemonPaths.screenUnknownDirectory)
        let first = try run(["samples", "--print", "1"]).joined(separator: "\n")
        XCTAssertTrue(first.hasPrefix("kitterm screen-unknown sample\nat: 2027-01-15T08:01:30.000Z\nsession: S-NEW\n"), first)
        XCTAssertTrue(first.hasSuffix("\n\nnew screen"), first)
        let second = try run(["samples", "--print", "2"]).joined(separator: "\n")
        XCTAssertTrue(second.contains("session: S-OLD\n"), second)
        XCTAssertTrue(second.hasSuffix("\n\nold screen"), second)
    }

    func testPrintPastTheEndOrZeroIsAUsageError() throws {
        try ScreenStateCapture.write(sample(session: "S1", offset: 0), in: DaemonPaths.screenUnknownDirectory)
        XCTAssertThrowsError(try run(["samples", "--print", "2"])) { error in
            XCTAssertTrue("\(error)".contains("no sample 2"), "\(error)")
        }
        XCTAssertThrowsError(try run(["samples", "--print", "0"]))
        XCTAssertThrowsError(try run(["samples", "--print"]))
    }

    func testSamplesJSON() throws {
        try ScreenStateCapture.write(sample(session: "S-OLD", offset: 0), in: DaemonPaths.screenUnknownDirectory)
        try ScreenStateCapture.write(sample(session: "S-NEW", offset: 90), in: DaemonPaths.screenUnknownDirectory)
        let lines = try run(["samples", "--json"])
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        let list = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["index"] as? Int, 1)
        XCTAssertEqual(list[0]["session"] as? String, "S-NEW")
        XCTAssertEqual(list[0]["at"] as? String, "2027-01-15T08:01:30.000Z")
        XCTAssertEqual(list[0]["program"] as? String, "claude")
        XCTAssertEqual(list[0]["size"] as? String, "100x30")
        XCTAssertNotNil(list[0]["bytes"] as? Int)
        XCTAssertTrue((list[0]["file"] as? String ?? "").hasSuffix("-S-NEW.txt"))
        XCTAssertEqual(list[1]["session"] as? String, "S-OLD")
    }

    func testSamplesJSONWithNoneIsAnEmptyList() throws {
        let lines = try run(["samples", "--json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual((object["samples"] as? [Any])?.count, 0)
    }

    func testClearRemovesThem() throws {
        try ScreenStateCapture.write(sample(session: "S1", offset: 0), in: DaemonPaths.screenUnknownDirectory)
        try ScreenStateCapture.write(sample(session: "S2", offset: 1), in: DaemonPaths.screenUnknownDirectory)
        let cleared = try run(["samples", "--clear"])
        XCTAssertEqual(cleared.count, 1)
        XCTAssertTrue(cleared[0].hasPrefix("Removed 2 samples from "), cleared[0])
        XCTAssertEqual(try ScreenStateCapture.samples().count, 0)
        XCTAssertEqual(try run(["samples", "--clear"]), ["Removed 0 samples from \(DaemonPaths.screenUnknownDirectory.path)."])
    }

    func testClearWithPrintOrJSONIsAUsageError() {
        XCTAssertThrowsError(try run(["samples", "--clear", "--json"]))
        XCTAssertThrowsError(try run(["samples", "--clear", "--print", "1"]))
        XCTAssertThrowsError(try run(["samples", "--bogus"]))
    }

    // MARK: - stats

    func testStatsPrintsTheSamplesLine() throws {
        ScreenStateLog.append(session: "S1", state: "unknown", rule: "r", at: Date())
        var lines = try run(["stats"])
        XCTAssertEqual(lines.last, "samples: 0 (capture off)")

        _ = try run(["capture", "on"])
        ScreenStateCapture.capture(sample(session: "S1", offset: 0))
        ScreenStateCapture.capture(sample(session: "S1", offset: 1))
        lines = try run(["stats"])
        XCTAssertEqual(lines.last, "samples: 2 (capture on)")
        // The counts above it are unchanged.
        XCTAssertTrue(lines.joined(separator: "\n").contains("unknown: 1\n"), lines.joined(separator: "\n"))
    }

    func testStatsJSONCarriesTheSamplesFacts() throws {
        ScreenStateLog.append(session: "S1", state: "working", rule: "r", at: Date())
        _ = try run(["capture", "on"])
        ScreenStateCapture.capture(sample(session: "S1", offset: 0))
        let lines = try run(["stats", "--json"])
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["samples"] as? Int, 1)
        XCTAssertEqual(object["captureUnknown"] as? Bool, true)
        XCTAssertEqual(object["total"] as? Int, 1)
    }
}
