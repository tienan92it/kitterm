import Foundation
import XCTest

@testable import KittermDaemon

/// The apportionment from `plan.md` row 4 of `workspace-ledger`, over three
/// fixtures under `Tests/Fixtures/transcripts/` shaped like the real lines
/// `corpus/data-sources.md` quotes, numbers chosen so the shares are exact:
///
/// - `one-day.jsonl`: three requests on 2026-09-10 between 10:00 and 15:00
///   `+07`, one of them written as two lines (a text block and a tool
///   block with the same `requestId`), and a $3.00 bill.
/// - `midnight.jsonl`: two requests at 23:00 and 23:40 `+07` on the 10th,
///   6000 tokens, and one at 00:30 on the 11th, 2000 tokens; a $4.00 bill.
///   In UTC all three fall on the 10th.
/// - `unbilled.jsonl`: two requests on the 12th and no `cost-state` line.
final class TranscriptUsageTests: XCTestCase {
    static let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    static let utc = TimeZone(identifier: "UTC")!

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-transcript-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Days

    func testDayKeyParsesAndPrintsTheSameText() {
        XCTAssertEqual(DayKey("2026-09-16")?.description, "2026-09-16")
        XCTAssertEqual(DayKey("2024-02-29")?.description, "2024-02-29")
        XCTAssertEqual(DayKey("1970-01-01")?.number, 0)
        XCTAssertEqual(DayKey("2026-09-16")?.advanced(by: 15).description, "2026-10-01")
        for bad in ["2026-02-31", "2026-9-1", "20260916", "2026-13-01", "abcd-ef-gh", "", "2026-09-16T00:00:00Z"] {
            XCTAssertNil(DayKey(bad), bad)
        }
    }

    /// The same instant is one day in UTC and the next in `+07`, and one day
    /// in UTC and the day before in Los Angeles: both directions.
    func testTheDayOfAnInstantDependsOnTheZoneInBothDirections() throws {
        let evening = try XCTUnwrap(TranscriptUsage.parseUTC("2026-09-10T17:30:00.000Z"))
        XCTAssertEqual(DayKey(evening, in: Self.utc).description, "2026-09-10")
        XCTAssertEqual(DayKey(evening, in: Self.saigon).description, "2026-09-11")

        let smallHours = try XCTUnwrap(TranscriptUsage.parseUTC("2026-09-11T02:00:00Z"))
        XCTAssertEqual(DayKey(smallHours, in: Self.utc).description, "2026-09-11")
        XCTAssertEqual(DayKey(smallHours, in: TimeZone(identifier: "America/Los_Angeles")!).description, "2026-09-10")
        XCTAssertEqual(DayKey(smallHours, in: Self.saigon).description, "2026-09-11")
    }

    func testParseUTCTakesOnlyTheFormClaudeCodeWrites() {
        XCTAssertEqual(TranscriptUsage.parseUTC("2026-09-04T09:30:31.436Z")?.timeIntervalSince1970 ?? 0, 1788514231.436, accuracy: 0.001)
        XCTAssertEqual(TranscriptUsage.parseUTC("1970-01-01T00:00:00Z")?.timeIntervalSince1970, 0)
        XCTAssertNil(TranscriptUsage.parseUTC("2026-09-04T09:30:31+07:00"))
        XCTAssertNil(TranscriptUsage.parseUTC("2026-09-04 09:30:31Z"))
        XCTAssertNil(TranscriptUsage.parseUTC("2026-09-04T09:30:31.4a6Z"))
        XCTAssertNil(TranscriptUsage.parseUTC(""))
    }

    // MARK: - The three cases

    func testASessionInsideOneDayIsExact() {
        let usage = TranscriptUsage.read(path: TranscriptBillTests.fixture("one-day.jsonl"), zone: Self.saigon)
        XCTAssertEqual(usage.sessionId, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(usage.cwd, "/nonexistent/fixture-project")
        XCTAssertEqual(usage.skippedLines, 0)
        XCTAssertEqual(Array(usage.days.keys), ["2026-09-10"])
        // Four assistant lines, three requests: the duplicated request
        // counts once.
        XCTAssertEqual(usage.days["2026-09-10"], TokenCounts(input: 6, output: 600, cacheCreation: 1500, cacheRead: 18000, requests: 3))
        XCTAssertEqual(usage.totalCostUSD, 3.0)

        let shares = TranscriptUsage.apportion(days: usage.days, totalCostUSD: usage.totalCostUSD)
        XCTAssertEqual(shares.count, 1)
        XCTAssertEqual(shares["2026-09-10"]?.costUSD, 3.0)
        XCTAssertEqual(shares["2026-09-10"]?.apportioned, false)
        XCTAssertEqual(shares["2026-09-10"]?.tokens.total, 20106)
    }

    func testASessionAcrossMidnightIsApportionedByTokenShare() {
        let usage = TranscriptUsage.read(path: TranscriptBillTests.fixture("midnight.jsonl"), zone: Self.saigon)
        XCTAssertEqual(usage.days.keys.sorted(), ["2026-09-10", "2026-09-11"])
        XCTAssertEqual(usage.days["2026-09-10"]?.total, 6000)
        XCTAssertEqual(usage.days["2026-09-11"]?.total, 2000)
        XCTAssertEqual(usage.days["2026-09-10"]?.requests, 2)
        XCTAssertEqual(usage.days["2026-09-11"]?.requests, 1)

        let shares = TranscriptUsage.apportion(days: usage.days, totalCostUSD: usage.totalCostUSD)
        XCTAssertEqual(shares["2026-09-10"]?.costUSD ?? 0, 3.0, accuracy: 1e-12)
        XCTAssertEqual(shares["2026-09-11"]?.costUSD ?? 0, 1.0, accuracy: 1e-12)
        XCTAssertEqual(shares["2026-09-10"]?.apportioned, true)
        XCTAssertEqual(shares["2026-09-11"]?.apportioned, true)
        // The split never changes the total.
        XCTAssertEqual(shares.values.reduce(0) { $0 + $1.costUSD }, 4.0, accuracy: 1e-12)

        // The same file in UTC is one day and exact.
        let utc = TranscriptUsage.read(path: TranscriptBillTests.fixture("midnight.jsonl"), zone: Self.utc)
        XCTAssertEqual(Array(utc.days.keys), ["2026-09-10"])
        let whole = TranscriptUsage.apportion(days: utc.days, totalCostUSD: utc.totalCostUSD)
        XCTAssertEqual(whole["2026-09-10"]?.costUSD, 4.0)
        XCTAssertEqual(whole["2026-09-10"]?.apportioned, false)
    }

    func testASessionWithNoBillKeepsItsTokensAndNoDollars() {
        let usage = TranscriptUsage.read(path: TranscriptBillTests.fixture("unbilled.jsonl"), zone: Self.saigon)
        XCTAssertEqual(usage.bill, .noBill(.noCostStateLine))
        XCTAssertNil(usage.totalCostUSD)
        XCTAssertEqual(usage.days["2026-09-12"], TokenCounts(input: 8, output: 200, cacheCreation: 2000, cacheRead: 2000, requests: 2))

        let shares = TranscriptUsage.apportion(days: usage.days, totalCostUSD: usage.totalCostUSD)
        XCTAssertEqual(shares["2026-09-12"]?.costUSD, 0)
        XCTAssertEqual(shares["2026-09-12"]?.apportioned, false)
        XCTAssertEqual(shares["2026-09-12"]?.tokens.total, 4208)
    }

    // MARK: - The edges

    /// A bill with no turns behind it (a session whose only turns were
    /// unreadable) goes whole to the day the bill says it started, never
    /// nowhere.
    func testABillWithNoTurnsGoesToItsStartDay() {
        let shares = TranscriptUsage.apportion(days: [:], totalCostUSD: 1.5, fallbackDay: "2026-09-01")
        XCTAssertEqual(shares["2026-09-01"]?.costUSD, 1.5)
        XCTAssertEqual(shares["2026-09-01"]?.apportioned, false)
        XCTAssertTrue(TranscriptUsage.apportion(days: [:], totalCostUSD: 0, fallbackDay: "2026-09-01").isEmpty)
        XCTAssertTrue(TranscriptUsage.apportion(days: [:], totalCostUSD: 1.5, fallbackDay: nil).isEmpty)
    }

    /// The real `bill.jsonl` tail has no assistant line: the bill is read
    /// and there are no days to put it on.
    func testATailWithNoTurnsReadsItsBillAndNoDays() {
        let usage = TranscriptUsage.read(path: TranscriptBillTests.fixture("bill.jsonl"), zone: Self.saigon)
        XCTAssertEqual(usage.totalCostUSD, 2.6361237500000003)
        XCTAssertTrue(usage.days.isEmpty)
        XCTAssertEqual(usage.skippedLines, 0)
    }

    /// A subagent's turns are on the parent's bill, so they are read into
    /// the parent, on their own day.
    func testSubagentTurnsCountForTheParent() throws {
        let main = scratch.appendingPathComponent("one-day.jsonl")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: TranscriptBillTests.fixture("one-day.jsonl")), to: main)
        let subagent = scratch.appendingPathComponent("agent-1.jsonl")
        let line = #"{"type":"assistant","requestId":"req_sub_1","timestamp":"2026-09-11T03:00:00.000Z","cwd":"/nonexistent/fixture-project","sessionId":"11111111-1111-4111-8111-111111111111","message":{"role":"assistant","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":900,"output_tokens":99}}}"#
        try (line + "\n").write(to: subagent, atomically: true, encoding: .utf8)

        let usage = TranscriptUsage.read(path: main.path, subagents: [subagent.path], zone: Self.saigon)
        XCTAssertEqual(usage.days.keys.sorted(), ["2026-09-10", "2026-09-11"])
        XCTAssertEqual(usage.days["2026-09-11"], TokenCounts(input: 1, output: 99, cacheCreation: 0, cacheRead: 900, requests: 1))
        XCTAssertEqual(usage.tokens.requests, 4)
    }

    func testAMissingFileReadsAsUnreadableWithNoDays() {
        let usage = TranscriptUsage.read(path: scratch.appendingPathComponent("gone.jsonl").path, zone: Self.saigon)
        XCTAssertTrue(usage.days.isEmpty)
        guard case .unreadable(let why) = usage.bill else { return XCTFail("\(usage.bill)") }
        XCTAssertTrue(why.contains("No such file"), why)
    }
}
