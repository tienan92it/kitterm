import Foundation
import XCTest

@testable import KittermCLI

/// `ScreenStateStats`: reading `ScreenStateLog`'s two files and summing the
/// states over a window, for `kitterm screen-state stats`.
final class ScreenStateStatsTests: XCTestCase {
    private var dir: URL!
    private var current: URL!
    private var rotated: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-screen-state-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        current = dir.appendingPathComponent("screen-state.log")
        rotated = dir.appendingPathComponent("screen-state.log.1")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ lines: [(at: Date, state: String)], to url: URL) throws {
        let text = try lines.map { entry in
            try ScreenStateLog.line(at: entry.at, session: "S", state: entry.state, rule: "r")
        }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static func daysAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86400) }

    // MARK: - counts, total, share, window

    func testCountsPerStateAndTotalAndUnknownShare() throws {
        try write(
            [
                (Self.daysAgo(1), "prompt-empty"),
                (Self.daysAgo(1), "prompt-empty"),
                (Self.daysAgo(2), "working"),
                (Self.daysAgo(3), "unknown"),
            ],
            to: current
        )
        let entries = ScreenStateStats.entries(current: current, rotated: rotated)
        let summary = ScreenStateStats.summarize(entries, window: ScreenStateStats.window(days: 7, now: Self.now))
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.counts["prompt-empty"], 2)
        XCTAssertEqual(summary.counts["working"], 1)
        XCTAssertEqual(summary.counts["unknown"], 1)
        XCTAssertEqual(summary.unknownSharePercent, 25)
    }

    /// Both files feed the same summary: `screen-state.log.1` holds what
    /// rotated out, and the window alone decides what counts.
    func testReadsBothTheCurrentAndTheRotatedFile() throws {
        try write([(Self.daysAgo(1), "working")], to: current)
        try write([(Self.daysAgo(2), "unknown")], to: rotated)
        let entries = ScreenStateStats.entries(current: current, rotated: rotated)
        let summary = ScreenStateStats.summarize(entries, window: ScreenStateStats.window(days: 7, now: Self.now))
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.counts["working"], 1)
        XCTAssertEqual(summary.counts["unknown"], 1)
    }

    /// An entry older than the window is read but not counted.
    func testTheWindowExcludesOlderEntries() throws {
        try write(
            [(Self.daysAgo(1), "working"), (Self.daysAgo(10), "unknown")],
            to: current
        )
        let entries = ScreenStateStats.entries(current: current, rotated: rotated)
        let summary = ScreenStateStats.summarize(entries, window: ScreenStateStats.window(days: 7, now: Self.now))
        XCTAssertEqual(summary.total, 1)
        XCTAssertNil(summary.counts["unknown"])
    }

    func testZeroTotalGivesZeroShareNotACrash() {
        let summary = ScreenStateStats.summarize([], window: ScreenStateStats.window(days: 7, now: Self.now))
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.unknownSharePercent, 0)
    }

    /// A malformed line is skipped, not a reason to fail the whole read.
    func testAMalformedLineIsSkipped() throws {
        let good = try ScreenStateLog.line(at: Self.daysAgo(1), session: "S", state: "working", rule: "r")
        try Data("not json\n\(good)\n".utf8).write(to: current)
        let entries = ScreenStateStats.entries(current: current, rotated: rotated)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.state, "working")
    }

    // MARK: - rendering

    func testTextListsEveryStateInOrderEvenAtZero() {
        let window = ScreenStateStats.Window(days: 7, from: Self.daysAgo(7), to: Self.now)
        let summary = ScreenStateStats.Summary(window: window, counts: ["working": 2, "unknown": 1], total: 3)
        let text = ScreenStateStats.text(for: summary)
        for state in ScreenStateStats.stateOrder {
            XCTAssertTrue(text.contains("\(state): "), "missing \(state) in:\n\(text)")
        }
        XCTAssertTrue(text.contains("working: 2"))
        XCTAssertTrue(text.contains("prompt-empty: 0"))
        XCTAssertTrue(text.contains("total: 3"))
        XCTAssertTrue(text.contains("unknown share: 33%"))
        XCTAssertTrue(text.contains("last 7 days"))
    }

    func testJSONCarriesTheSameNumbers() throws {
        let window = ScreenStateStats.Window(days: 7, from: Self.daysAgo(7), to: Self.now)
        let summary = ScreenStateStats.Summary(window: window, counts: ["working": 2, "unknown": 1], total: 3)
        let json = ScreenStateStats.json(for: summary)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(object?["total"] as? Int, 3)
        XCTAssertEqual(object?["days"] as? Int, 7)
        XCTAssertEqual(object?["unknownSharePercent"] as? Int, 33)
        let counts = object?["counts"] as? [String: Int]
        XCTAssertEqual(counts?["working"], 2)
        XCTAssertEqual(counts?["unknown"], 1)
    }
}
