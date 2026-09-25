import Foundation
import XCTest
import KittermDaemon

@testable import KittermCLI

/// Round 5 of `cost-per-round`, `the-ledger-prints-api-time`: the ledger
/// prints `totalAPIDuration` in an `api` column beside `wall`, because
/// `totalDuration` counts the time a session was open, not the time it
/// worked (round 4's own `Cost:` line read 16h 53m wall on a round whose
/// API time was near ten minutes). A `Cost:` line carries no API time, so a
/// round whose bill came from one, or that predates the bill, prints the
/// table's dash. These tests exercise `GoalLedger.Row.apiDurationMs` and
/// `GoalLedger.table` directly, without the file and git plumbing
/// `GoalCostTests` needs for the other columns.
final class GoalLedgerAPITimeTests: XCTestCase {
    /// A minimal `cost-state` line's fields, decoded the way
    /// `TranscriptBill.read` decodes a real transcript's last line.
    private func bill(costUSD: Double = 1, durationMs: Int = 600_000, apiDurationMs: Int) -> TranscriptBill {
        let json = """
        {"totalCostUSD": \(costUSD), "totalDuration": \(durationMs), "totalAPIDuration": \(apiDurationMs),
         "totalLinesAdded": 0, "totalLinesRemoved": 0, "modelUsage": {}}
        """
        return try! JSONDecoder().decode(TranscriptBill.self, from: Data(json.utf8))
    }

    private func record(_ number: Int, slug: String, decision: String = "done") -> GoalLedger.Record {
        GoalLedger.Record(
            number: number, slug: slug, sessions: [], archives: [], base: nil, result: nil, pr: nil,
            costLines: [], testsAdded: nil, decision: decision
        )
    }

    private static let noFiles = GoalLedger.FilesChanged.noSha(line: "Base: and Result:")

    // MARK: - The header

    func testHeaderCarriesAPIAfterWall() {
        let lines = GoalLedger.table(GoalLedger.Goal(slug: "g", rows: []))
        XCTAssertEqual(lines.count, 2, "a header and a total row for a goal with no rounds")
        XCTAssertTrue(lines[0].contains("wall   api tests"), lines[0])
    }

    // MARK: - `Row.apiDurationMs`

    /// A round whose one session billed from a transcript carries that
    /// bill's `totalAPIDuration`.
    func testATranscriptSourcedRowHasItsAPIDuration() {
        let row = GoalLedger.Row(
            record: record(1, slug: "one"),
            bills: [GoalLedger.SessionBill(bill: bill(apiDurationMs: 125_000))],
            files: Self.noFiles
        )
        XCTAssertEqual(row.apiDurationMs, 125_000)
    }

    /// Two sessions, both billed from a transcript: the API time sums, the
    /// same rule the wall-clock and the dollars already follow.
    func testTwoTranscriptSourcedSessionsSumTheirAPIDuration() {
        let row = GoalLedger.Row(
            record: record(1, slug: "one"),
            bills: [
                GoalLedger.SessionBill(bill: bill(apiDurationMs: 60_000)),
                GoalLedger.SessionBill(bill: bill(apiDurationMs: 40_000)),
            ],
            files: Self.noFiles
        )
        XCTAssertEqual(row.apiDurationMs, 100_000)
    }

    /// A `Cost:` line carries no API time (`LOOP.md`'s shape has no such
    /// field), so a round read from one has none either.
    func testALineSourcedRowHasNoAPIDuration() {
        let line = GoalLedger.CostLine(costUSD: 1, inTokens: 100, cachedPercent: 50, outTokens: 10, durationMs: 60_000)
        let row = GoalLedger.Row(
            record: record(1, slug: "one"), bills: [GoalLedger.SessionBill(line: line)], files: Self.noFiles
        )
        XCTAssertNil(row.apiDurationMs)
    }

    /// A round with no bill at all: it predates the bill, or its transcript
    /// answered no bill and its record carries no `Cost:` line either.
    func testAnUnbilledRowHasNoAPIDuration() {
        let row = GoalLedger.Row(record: record(1, slug: "one"), bills: [], files: Self.noFiles)
        XCTAssertFalse(row.hasBill)
        XCTAssertNil(row.apiDurationMs)
    }

    /// A round with two sessions, one billed from a transcript and the
    /// other from a `Cost:` line: the round has a bill (the dollars and the
    /// wall-clock sum both sources), but no API time, because the line side
    /// does not know it and a partial sum would misstate it. `--json`'s own
    /// `totalAPIDuration` already withholds itself the same way, on
    /// `sources == [.transcript]`.
    func testAMixedSourceRowHasNoAPIDuration() {
        let line = GoalLedger.CostLine(costUSD: 1, inTokens: 100, cachedPercent: 50, outTokens: 10, durationMs: 60_000)
        let row = GoalLedger.Row(
            record: record(1, slug: "one"),
            bills: [
                GoalLedger.SessionBill(bill: bill(apiDurationMs: 60_000)),
                GoalLedger.SessionBill(line: line),
            ],
            files: Self.noFiles
        )
        XCTAssertTrue(row.hasBill)
        XCTAssertNil(row.apiDurationMs)
    }

    // MARK: - The table

    /// A transcript-billed round's `api` cell holds `wall(totalAPIDuration)`,
    /// in the column right after `wall`.
    func testATranscriptBilledRoundPrintsItsAPITimeInTheTable() {
        let row = GoalLedger.Row(
            record: record(1, slug: "one"),
            bills: [GoalLedger.SessionBill(bill: bill(durationMs: 600_000, apiDurationMs: 125_000))],
            files: Self.noFiles
        )
        let lines = GoalLedger.table(GoalLedger.Goal(slug: "g", rows: [row]))
        XCTAssertEqual(GoalLedger.wall(125_000), "2m05")
        XCTAssertTrue(lines[1].contains(" 10m00  2m05 "), lines[1])
    }

    /// A line-billed round's `api` cell is the table's dash, beside its real
    /// dollars and wall-clock.
    func testALineBilledRoundPrintsADashForAPIInTheTable() {
        let costLine = GoalLedger.CostLine(costUSD: 1, inTokens: 100, cachedPercent: 50, outTokens: 10, durationMs: 60_000)
        let row = GoalLedger.Row(
            record: record(1, slug: "one"), bills: [GoalLedger.SessionBill(line: costLine)], files: Self.noFiles
        )
        let lines = GoalLedger.table(GoalLedger.Goal(slug: "g", rows: [row]))
        XCTAssertTrue(lines[1].contains(" 1m00     — "), lines[1])
    }

    /// The total row sums `apiDurationMs` over only the rounds that have
    /// one: a transcript-billed round counts, a line-billed round and an
    /// unbilled round do not, even though the line-billed round's dollars
    /// and wall-clock still add into their own totals.
    func testTotalSumsOnlyTheRoundsWithAPITime() throws {
        let costLine = GoalLedger.CostLine(costUSD: 1, inTokens: 100, cachedPercent: 50, outTokens: 10, durationMs: 60_000)
        let transcriptRow = GoalLedger.Row(
            record: record(1, slug: "one"),
            bills: [GoalLedger.SessionBill(bill: bill(durationMs: 600_000, apiDurationMs: 125_000))],
            files: Self.noFiles
        )
        let lineRow = GoalLedger.Row(
            record: record(2, slug: "two"), bills: [GoalLedger.SessionBill(line: costLine)], files: Self.noFiles
        )
        let unbilledRow = GoalLedger.Row(record: record(3, slug: "three"), bills: [], files: Self.noFiles)
        let goal = GoalLedger.Goal(slug: "g", rows: [transcriptRow, lineRow, unbilledRow])

        XCTAssertEqual(goal.rows.compactMap(\.apiDurationMs).reduce(0, +), 125_000, "only the transcript row counts")

        let lines = GoalLedger.table(goal)
        let total = try XCTUnwrap(lines.first { $0.hasPrefix("  total") })
        XCTAssertTrue(total.contains(" 11m00  2m05 "), total)
    }
}
