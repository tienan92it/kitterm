import Foundation
import XCTest

@testable import KittermDaemon

/// The goal's cost on the knowledge summary (`workspace-ledger`, capability
/// 5): the sum of every `- Cost:` line over a goal's round records, as
/// `LOOP.md` defines the line, read by `KnowledgeFile.summaries` from
/// every `rounds/<N>.md` and served beside the goal's other fields.
final class KnowledgeCostTests: XCTestCase {
    // MARK: - one line

    func testParsesTheLineLoopDefines() {
        let cost = KnowledgeSummary.costLine("- Cost: $2.64 · 1101k in (93% cached) · 18k out · 0h 6m")
        XCTAssertEqual(cost, KnowledgeSummary.RecordCost(
            costUSD: 2.64, inTokens: 1_101_000, cachedPercent: 93, outTokens: 18_000, durationMs: 6 * 60_000
        ))
        XCTAssertEqual(cost?.cacheReadTokens, 1_023_930, "in times the percent, so one unit with a transcript")
        XCTAssertEqual(
            KnowledgeSummary.costLine("- Cost: $12 · 0k in (0% cached) · 0k out · 1h 3m\r")?.durationMs, 63 * 60_000,
            "a whole-dollar line with a CR ending"
        )
    }

    func testSkipsNoneRecordedMalformedAndOtherLines() {
        XCTAssertNil(KnowledgeSummary.costLine("- Cost: none recorded (noCostStateLine)"))
        XCTAssertNil(KnowledgeSummary.costLine("- Cost: 2.64 USD"))
        XCTAssertNil(KnowledgeSummary.costLine("- Base: e586688   Result: 259e38e"))
        XCTAssertNil(KnowledgeSummary.costLine("  - Cost: $2.64 · 1101k in (93% cached) · 18k out · 0h 6m"), "not at column 0")
        XCTAssertNil(KnowledgeSummary.costLine(""))
    }

    // MARK: - the records

    private let one = """
        # Round 001: first

        - Goal: g
        - Sessions: A   Archives: the same
        - Cost: $2.64 · 1101k in (93% cached) · 18k out · 0h 6m

        ## Floor
        - Cost: $99.00 · 1k in (0% cached) · 1k out · 0h 1m

        ## Decision
        done
        """
    private let two = """
        # Round 002: second, two sessions

        - Sessions: A, B
        - Cost: $4.74 · 3331k in (97% cached) · 36k out · 0h 10m
        - Cost: none recorded (noCostStateLine)
        - Cost: $0.41 · 0k in (0% cached) · 0k out · 0h 0m
        """
    private let three = """
        # Round 003: before the bill

        - Sessions: C
        """

    func testSumsTheHeaderLinesOfEveryRecordAndNothingUnderAHeading() {
        XCTAssertEqual(KnowledgeSummary.costLines(one).map(\.costUSD), [2.64], "the line under ## Floor is not a bill")
        XCTAssertEqual(KnowledgeSummary.costLines(two).map(\.costUSD), [4.74, 0.41], "none recorded is skipped")
        XCTAssertEqual(KnowledgeSummary.costLines(three), [])

        var summary = KnowledgeSummary()
        summary.sumCosts(records: [one, two, three])
        XCTAssertEqual(summary.costUSD!, 7.79, accuracy: 0.0001)
        XCTAssertEqual(summary.inTokens, 4_432_000)
        XCTAssertEqual(summary.cacheReadTokens, 1_023_930 + 3_231_070)
        XCTAssertEqual(summary.json["costUSD"] as? Double, summary.costUSD)
        XCTAssertEqual(summary.json["inTokens"] as? Int, 4_432_000)
        XCTAssertEqual(summary.json["cacheReadTokens"] as? Int, 4_255_000)
    }

    func testAGoalWithNoCostLineHasNoCostField() {
        var summary = KnowledgeSummary()
        summary.sumCosts(records: [three, "## Decision\n\ndone\n"])
        XCTAssertNil(summary.costUSD)
        XCTAssertNil(summary.inTokens)
        XCTAssertNil(summary.cacheReadTokens)
        XCTAssertTrue(summary.json.isEmpty, "no zero for a goal that predates the bill")
        summary.sumCosts(records: [])
        XCTAssertEqual(summary, KnowledgeSummary())
    }

    // MARK: - the package

    private func makePackage(records: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knowledge-cost-\(UUID().uuidString)", isDirectory: true)
        let goal = root.appendingPathComponent("docs/goals/priced", isDirectory: true)
        try FileManager.default.createDirectory(at: goal.appendingPathComponent("rounds"), withIntermediateDirectories: true)
        try "# STATE: priced\n\n- Status: active\n- Round: 2 of 3\n".write(
            to: goal.appendingPathComponent("STATE.md"), atomically: true, encoding: .utf8
        )
        for (name, text) in records {
            try text.write(to: goal.appendingPathComponent("rounds/\(name)"), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSummariesReadEveryRecordNotOnlyTheLatest() throws {
        let root = try makePackage(records: ["001.md": one, "002.md": two, "003.md": three, "notes.md": one])
        let goals = try XCTUnwrap(KnowledgeFile.summaries(root: root.path, knowledge: "docs/goals"))
        let priced = try XCTUnwrap(goals.first { $0.slug == "priced" })
        XCTAssertEqual(priced.costUSD!, 7.79, accuracy: 0.0001, "rounds 1 and 2 carry lines; 3 and notes.md do not count")
        XCTAssertEqual(priced.inTokens, 4_432_000)
        XCTAssertEqual(priced.lastRound, 3, "the latest record is still the one the link opens")
        XCTAssertEqual(priced.lastRecord, "priced/rounds/003.md")
        XCTAssertEqual(priced.status, "active")
    }

    func testSummariesLeaveTheCostAbsentWithoutRecords() throws {
        let root = try makePackage(records: [:])
        let goals = try XCTUnwrap(KnowledgeFile.summaries(root: root.path, knowledge: "docs/goals"))
        let priced = try XCTUnwrap(goals.first { $0.slug == "priced" })
        XCTAssertNil(priced.costUSD)
        XCTAssertNil(priced.lastRound)
    }

    /// This repository's own package: `cost-per-round` carries the first
    /// real `Cost:` lines, so its sum is positive. A smoke test, not a pin:
    /// the next round record changes the number.
    func testThisRepositoryPricesAGoal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/goals/cost-per-round/STATE.md").path) else {
            throw XCTSkip("no docs/goals/cost-per-round beside the tests")
        }
        let goals = try XCTUnwrap(KnowledgeFile.summaries(root: root.path, knowledge: "docs/goals"))
        let ledger = try XCTUnwrap(goals.first { $0.slug == "cost-per-round" })
        XCTAssertGreaterThan(ledger.costUSD ?? 0, 0)
        XCTAssertGreaterThan(ledger.inTokens ?? 0, 0)
        XCTAssertLessThanOrEqual(ledger.cacheReadTokens ?? 0, ledger.inTokens ?? 0)
    }
}
