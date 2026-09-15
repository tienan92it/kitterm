import Foundation
import XCTest

@testable import KittermDaemon

/// The reader over three real transcript tails checked in under
/// `Fixtures/transcripts/`: the last lines of two Claude Code transcripts from
/// this repository, numbers untouched, and the first of them cut mid-line.
///
/// - `bill.jsonl`: session `e89e7ec8…`, the transcript `corpus/data-sources.md`
///   quotes. Two models, $2.64, 5 m 48 s.
/// - `zeroed.jsonl`: session `dc95adb5…`, 6113 lines in the original, no
///   billable turn: `totalCostUSD: 0`, `modelUsage: {}`, nine hours of
///   wall-clock.
/// - `truncated.jsonl`: `bill.jsonl` cut inside `modelUsage`, the state of a
///   file whose writer is mid-line.
final class TranscriptBillTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/transcripts", isDirectory: true)

    static func fixture(_ name: String) -> String {
        fixtures.appendingPathComponent(name).path
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-transcript-bill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - The three fixtures

    func testABillReadsEveryFieldUnrounded() throws {
        guard case .bill(let bill) = TranscriptBill.read(path: Self.fixture("bill.jsonl")) else {
            return XCTFail("expected a bill")
        }
        XCTAssertEqual(bill.sessionId, "e89e7ec8-9e61-4900-800f-aa72ed555d63")
        // As written, every digit: the reader rounds nothing.
        XCTAssertEqual(bill.totalCostUSD, 2.6361237500000003)
        XCTAssertEqual(bill.totalDuration, 347686)
        XCTAssertEqual(bill.totalAPIDuration, 244888)
        XCTAssertEqual(bill.totalAPIDurationWithoutRetries, 244867)
        XCTAssertEqual(bill.totalToolDuration, 908)
        XCTAssertEqual(bill.totalLinesAdded, 0)
        XCTAssertEqual(bill.totalLinesRemoved, 0)
        XCTAssertEqual(bill.startTime, 1788922267579)
        XCTAssertEqual(bill.hasUnknownModelCost, false)

        XCTAssertEqual(Set(bill.modelUsage.keys), ["claude-fable-5-1", "claude-haiku-4-5-20251001"])
        let fable = try XCTUnwrap(bill.modelUsage["claude-fable-5-1"])
        XCTAssertEqual(fable.inputTokens, 450)
        XCTAssertEqual(fable.outputTokens, 17680)
        XCTAssertEqual(fable.thinkingTokens, 9245)
        XCTAssertEqual(fable.cacheReadInputTokens, 1022235)
        XCTAssertEqual(fable.cacheCreationInputTokens, 74427)
        XCTAssertEqual(fable.webSearchRequests, 0)
        XCTAssertEqual(fable.costUSD, 2.6325987500000005)
        let haiku = try XCTUnwrap(bill.modelUsage["claude-haiku-4-5-20251001"])
        XCTAssertEqual(haiku.inputTokens, 3390)
        XCTAssertEqual(haiku.outputTokens, 27)
        XCTAssertEqual(haiku.cacheReadInputTokens, 0)
        XCTAssertEqual(haiku.costUSD, 0.0035249999999999995)
    }

    /// A `cost-state` line with no model is a bill of zero, not "no bill":
    /// Claude Code wrote a total, and the wall-clock in it is real.
    func testAZeroedLineIsABillOfZero() throws {
        guard case .bill(let bill) = TranscriptBill.read(path: Self.fixture("zeroed.jsonl")) else {
            return XCTFail("expected a bill")
        }
        XCTAssertEqual(bill.sessionId, "dc95adb5-e73f-4760-b2e8-252cbc18563b")
        XCTAssertEqual(bill.totalCostUSD, 0)
        XCTAssertEqual(bill.totalAPIDuration, 0)
        XCTAssertEqual(bill.totalDuration, 32860487)
        XCTAssertEqual(bill.startTime, 1788758287970)
        XCTAssertTrue(bill.modelUsage.isEmpty)
    }

    /// A file cut mid-line is a writer mid-write, and the answer is "no bill
    /// yet", not an error and not the numbers of the line before.
    func testATruncatedLastLineIsNoBillYet() {
        XCTAssertEqual(
            TranscriptBill.read(path: Self.fixture("truncated.jsonl")),
            .noBill(.lastLineIncomplete)
        )
    }

    // MARK: - The other shapes a tail can have

    /// A transcript that is still running ends in a turn, not a bill. The
    /// same holds for a session resumed after its `cost-state` line: the
    /// line is there, above, and it is stale, so the reader does not go
    /// looking for it.
    func testALastLineThatIsNotCostStateIsNoBillYet() throws {
        let lines = try String(contentsOfFile: Self.fixture("bill.jsonl"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        // The bill with a turn appended after it, the way a resume does.
        let resumed = scratch.appendingPathComponent("resumed.jsonl")
        try (lines[0..<3] + [lines[0]]).joined(separator: "\n").appending("\n")
            .write(to: resumed, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptBill.read(path: resumed.path), .noBill(.noCostStateLine))

        let empty = scratch.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        XCTAssertEqual(TranscriptBill.read(path: empty.path), .noBill(.noCostStateLine))

        let notJSON = scratch.appendingPathComponent("prose.jsonl")
        try "not a transcript\n".write(to: notJSON, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptBill.read(path: notJSON.path), .noBill(.noCostStateLine))
    }

    /// The reader needs the last line and the newline before it, and nothing
    /// else: a turn of 200 KiB right before the bill costs one 64 KiB read.
    func testOnlyTheTailIsRead() throws {
        let bill = try String(contentsOfFile: Self.fixture("bill.jsonl"), encoding: .utf8)
        let lastLine = try XCTUnwrap(bill.split(separator: "\n").last)
        let hugeTurn = #"{"type":"assistant","message":"\#(String(repeating: "x", count: 200_000))"}"#
        let file = scratch.appendingPathComponent("big.jsonl")
        try (hugeTurn + "\n" + lastLine + "\n").write(to: file, atomically: true, encoding: .utf8)

        guard case .bill(let read) = TranscriptBill.read(path: file.path) else {
            return XCTFail("expected a bill through a 64 KiB window")
        }
        XCTAssertEqual(read.totalCostUSD, 2.6361237500000003)

        // A last line longer than the window is reported as such, not
        // guessed at from its tail.
        XCTAssertEqual(
            TranscriptBill.read(path: file.path, window: 256),
            .noBill(.lastLineTooLong)
        )
        // Unless the window reaches the start of the file, where a line
        // with no newline before it is simply the first line.
        let alone = scratch.appendingPathComponent("alone.jsonl")
        try (lastLine + "\n").write(to: alone, atomically: true, encoding: .utf8)
        guard case .bill = TranscriptBill.read(path: alone.path, window: 4096) else {
            return XCTFail("a one-line transcript is its own bill")
        }
    }

    /// A `cost-state` line missing a field the reader needs names that,
    /// rather than reading as "no bill yet" and hiding a format change.
    func testAMalformedCostStateLineSaysSo() throws {
        let file = scratch.appendingPathComponent("malformed.jsonl")
        try #"{"type":"cost-state","sessionId":"x","totalCostUSD":1.5}"#.appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptBill.read(path: file.path), .noBill(.costStateMalformed))
    }

    func testAMissingFileIsUnreadable() {
        let missing = scratch.appendingPathComponent("gone.jsonl").path
        guard case .unreadable(let reason) = TranscriptBill.read(path: missing) else {
            return XCTFail("expected unreadable")
        }
        XCTAssertTrue(reason.contains(missing), reason)
        XCTAssertTrue(reason.contains("No such file"), reason)
    }
}
