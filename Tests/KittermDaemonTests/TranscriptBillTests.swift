import Foundation
import XCTest

@testable import KittermDaemon

/// The reader over three real transcript tails checked in under
/// `Tests/Fixtures/transcripts/`: the last lines of two Claude Code
/// transcripts from this repository, numbers untouched, and the first of them
/// cut mid-line. They sit outside the test target's directory because this
/// target declares no resources, and SwiftPM warns on every build about a
/// file it does not handle; the tests find them by path.
///
/// - `bill.jsonl`: session `e89e7ec8…`, the transcript `corpus/data-sources.md`
///   quotes. Two models, $2.64, 5 m 48 s.
/// - `zeroed.jsonl`: session `dc95adb5…`, 6113 lines in the original, no
///   billable turn: `totalCostUSD: 0`, `modelUsage: {}`, nine hours of
///   wall-clock.
/// - `truncated.jsonl`: `bill.jsonl` cut inside `modelUsage`, the state of a
///   file whose writer is mid-line.
final class TranscriptBillTests: XCTestCase {
    /// `Tests/Fixtures/transcripts/`, two levels up from this file.
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
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

    // The records Claude Code appends after a bill, the shapes of 2026-09-21:
    // the two `queue-operation` lines of session `37052c8b…` (`cost-state`
    // at line 350 of 352), the `system`, `ai-title` and `agent-name` lines
    // three other sessions carried, and the `user` line with its
    // `attachment` of a resume the human typed into and no turn answered.
    static let queueEnqueue = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-21T10:28:21.151Z","sessionId":"e89e7ec8-9e61-4900-800f-aa72ed555d63","content":"<task-notification>done</task-notification>"}"#
    static let queueDequeue = #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-09-21T10:28:21.161Z","sessionId":"e89e7ec8-9e61-4900-800f-aa72ed555d63"}"#
    static let system = #"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"informational","content":"agents-md: AGENTS.md loaded","uuid":"s","timestamp":"2026-09-21T10:28:22.000Z"}"#
    static let aiTitle = #"{"type":"ai-title","aiTitle":"a title","sessionId":"e89e7ec8-9e61-4900-800f-aa72ed555d63"}"#
    static let agentName = #"{"type":"agent-name","agentName":"a name","sessionId":"e89e7ec8-9e61-4900-800f-aa72ed555d63"}"#
    static let user = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"continue"},"uuid":"u","timestamp":"2026-09-21T10:28:23.000Z","cwd":"/x","sessionId":"e89e7ec8-9e61-4900-800f-aa72ed555d63"}"#
    static let attachment = #"{"parentUuid":"u","isSidechain":false,"type":"attachment","attachment":{"type":"queued_command","prompt":"continue"},"uuid":"t","timestamp":"2026-09-21T10:28:23.100Z"}"#
    /// One turn after the bill: the resume that makes the bill stale.
    static let turn = #"{"parentUuid":"u","isSidechain":false,"requestId":"req_1","type":"assistant","message":{"model":"claude-fable-5-1","id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"…"}],"usage":{"input_tokens":1,"output_tokens":1}},"uuid":"a","timestamp":"2026-09-21T10:28:24.000Z","cwd":"/x","sessionId":"e89e7ec8-9e61-4900-800f-aa72ed555d63"}"#
    /// A tool result whose object carries the assistant type key below the
    /// top level: the gate hits, the parse says `user`.
    static let quotingUser = #"{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"…"}]},"toolUseResult":{"type":"assistant","note":"a transcript line the tool read"},"uuid":"q","timestamp":"2026-09-21T10:28:25.000Z"}"#

    private func write(_ lines: [String], as name: String) throws -> String {
        let path = scratch.appendingPathComponent(name)
        try lines.joined(separator: "\n").appending("\n").write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func billLines() throws -> [String] {
        try String(contentsOfFile: Self.fixture("bill.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// A transcript that is still running ends in a turn, not a bill. The
    /// same holds for a session resumed after its `cost-state` line: an
    /// `assistant` line after the bill says the bill is stale, whatever
    /// records follow the turn, and the reader does not go looking for it.
    /// (Round 19 of `agent-dashboard` replaced this test's resume case: it
    /// appended a `system` line after the bill, which is a record, not a
    /// turn, and reads as the bill now.)
    func testALastLineThatIsNotCostStateIsNoBillYet() throws {
        let bill = try billLines()
        let resumed = try write(bill + [Self.user, Self.turn], as: "resumed.jsonl")
        XCTAssertEqual(TranscriptBill.read(path: resumed), .noBill(.noCostStateLine))
        let resumedThenRecords = try write(bill + [Self.turn, Self.queueEnqueue, Self.queueDequeue], as: "resumed-records.jsonl")
        XCTAssertEqual(TranscriptBill.read(path: resumedThenRecords), .noBill(.noCostStateLine))

        let empty = scratch.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        XCTAssertEqual(TranscriptBill.read(path: empty.path), .noBill(.noCostStateLine))

        let notJSON = scratch.appendingPathComponent("prose.jsonl")
        try "not a transcript\n".write(to: notJSON, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptBill.read(path: notJSON.path), .noBill(.noCostStateLine))
        // Records with no bill before them, walked to the file's start.
        let recordsOnly = try write([Self.system, Self.queueEnqueue], as: "records-only.jsonl")
        XCTAssertEqual(TranscriptBill.read(path: recordsOnly), .noBill(.noCostStateLine))
    }

    /// Claude Code appends records after the bill at exit and on a resume
    /// the human typed into: none is a turn, so the bill behind them stands.
    /// Session `37052c8b…` of 2026-09-21 ended `cost-state`,
    /// `queue-operation`, `queue-operation` and read as unbilled.
    func testRecordsAfterTheBillDoNotHideIt() throws {
        let bill = try billLines()
        let trailing: [(String, [String])] = [
            ("queue", [Self.queueEnqueue, Self.queueDequeue]),
            ("exit", [Self.system, Self.aiTitle, Self.agentName]),
            ("typed", [Self.user, Self.attachment]),
            ("quoting", [Self.quotingUser]),
        ]
        for (name, records) in trailing {
            let path = try write(bill + records, as: "\(name).jsonl")
            guard case .bill(let read) = TranscriptBill.read(path: path) else {
                return XCTFail("\(name): expected the bill behind \(records.count) records, got \(TranscriptBill.read(path: path))")
            }
            XCTAssertEqual(read.totalCostUSD, 2.6361237500000003, name)
            XCTAssertEqual(read.sessionId, "e89e7ec8-9e61-4900-800f-aa72ed555d63", name)
        }
        // A bill alone at the end still reads as today.
        guard case .bill(let plain) = TranscriptBill.read(path: try write(bill, as: "plain.jsonl")) else {
            return XCTFail("expected the bill")
        }
        XCTAssertEqual(plain.totalCostUSD, 2.6361237500000003)
        // The walk stops at the first bill it meets: an older bill above a
        // newer one is never the answer.
        let twice = try write(bill + [Self.turn] + [bill.last!.replacingOccurrences(of: "2.6361237500000003", with: "9.5")] + [Self.queueDequeue], as: "twice.jsonl")
        guard case .bill(let newer) = TranscriptBill.read(path: twice) else { return XCTFail("expected the newer bill") }
        XCTAssertEqual(newer.totalCostUSD, 9.5)
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
