import Foundation
import XCTest
import KittermDaemon

@testable import KittermCLI

/// Two parsers read the same round-record header (`LOOP.md`, "The round
/// record"): `KnowledgeSummary.roundRecord`, for the knowledge route and the
/// fleet view, and `GoalLedger.parse` (`GoalLedger.parseHeaderLine`), for
/// `kitterm goal cost`. Nothing stops them drifting apart — PR #162 fixed one
/// such drift (`agent-dashboard` round 22: the ledger read a `Result:` value
/// riding the `- Base:` line, the route did not) and this chore fixed the
/// opposite one (the route already read a standalone `- Result:` bullet, the
/// eleven-record shape `agent-dashboard` rounds 1-9 and `workspace-ledger`
/// rounds 5-6 still use; the ledger did not, until `GoalLedger.parse` learned
/// the same bullet-wins rule). This file runs both over every real round
/// record in this checkout so the next drift shows up here instead of on the
/// page.
///
/// Compared: the PR (`RoundRecord.pr` vs `GoalLedger.Record.pr`, both
/// `Int?`) and the summed dollars of the header's `- Cost:` lines
/// (`RoundRecord.costUSD` vs the sum of `GoalLedger.Record.costLines`, both
/// built from the one shared `KnowledgeSummary.costLine`). **Not compared**:
/// the round's started day. `KnowledgeSummary.roundRecord` reads it from the
/// `- Started:` line; `GoalLedger.parseHeaderLine` has no case for that
/// prefix at all; `GoalLedger.Record` carries no `started` field to compare
/// it against. The date is not a field both parsers expose, so this file
/// does not assert on it.
final class RecordParsersAgreeTests: XCTestCase {
    /// One disagreement between the two parsers on one record.
    struct Disagreement: CustomStringConvertible, Equatable {
        var path: String
        var field: String
        var route: String
        var ledger: String

        var description: String { "\(path): \(field) — route=\(route) ledger=\(ledger)" }
    }

    /// Run both parsers over one record's text and report where they
    /// disagree on the fields both expose. `path` is only for the message.
    static func disagreements(path: String, number: Int, text: String) -> [Disagreement] {
        let route = KnowledgeSummary.roundRecord(number: number, text: text)
        let ledger = GoalLedger.parse(text, number: number)
        var found: [Disagreement] = []

        if route.pr != ledger.pr {
            found.append(Disagreement(
                path: path, field: "pr",
                route: route.pr.map(String.init) ?? "nil", ledger: ledger.pr.map(String.init) ?? "nil"
            ))
        }

        let routeCost = route.costUSD ?? 0
        let ledgerCost = ledger.costLines.compactMap { $0 }.reduce(0.0) { $0 + $1.costUSD }
        if abs(routeCost - ledgerCost) > 0.0001 {
            found.append(Disagreement(
                path: path, field: "summed cost",
                route: String(format: "%.4f", routeCost), ledger: String(format: "%.4f", ledgerCost)
            ))
        }

        return found
    }

    // MARK: - every real record in this checkout

    /// `docs/goals/<slug>/rounds/<digits>.md`, every goal folder, sorted so a
    /// failure message reads in a stable order.
    private func realRecordFiles() throws -> [URL] {
        let goals = CLIFixture.repositoryRoot.appendingPathComponent("docs/goals", isDirectory: true)
        guard let slugs = try? FileManager.default.contentsOfDirectory(atPath: goals.path) else { return [] }
        var files: [URL] = []
        for slug in slugs.sorted() {
            let rounds = goals.appendingPathComponent(slug).appendingPathComponent("rounds", isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: rounds.path) else { continue }
            for name in names.sorted() where KnowledgeSummary.roundNumber(name) != nil {
                files.append(rounds.appendingPathComponent(name))
            }
        }
        return files
    }

    /// The two parsers over every `docs/goals/*/rounds/*.md` in this
    /// checkout: they must agree on the fields both expose. A failure here
    /// is a real finding, not a fixture — see `LOOP.md`'s note in
    /// `agent-dashboard` round 22 for the shape of the last one.
    func testBothParsersAgreeOnEveryRealRecord() throws {
        let files = try realRecordFiles()
        XCTAssertGreaterThan(files.count, 0, "expected to find round records under docs/goals/*/rounds/")

        var all: [Disagreement] = []
        for file in files {
            guard let number = KnowledgeSummary.roundNumber(file.lastPathComponent) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: CLIFixture.repositoryRoot.path + "/", with: "")
            all.append(contentsOf: Self.disagreements(path: relative, number: number, text: text))
        }

        XCTAssertTrue(all.isEmpty, "the route and the ledger disagree on \(all.count) field(s):\n"
            + all.map(\.description).joined(separator: "\n"))
    }

    // MARK: - the shapes both parsers now read alike

    /// The shape `agent-dashboard` rounds 1-9 and `workspace-ledger` rounds
    /// 5-6 still carry: a standalone `- Result:` bullet, no `Result:` on the
    /// `- Base:` line. Before this chore's fix, `GoalLedger.parseHeaderLine`
    /// had no case for a line starting `- Result:` at all, so it returned
    /// `pr: nil` for all eleven while the route read the bullet; this pins
    /// the fix, and the real-record test above is what caught the gap.
    func testHelperAgreesOnTheStandaloneResultBullet() {
        let text = """
            # Round 001: no-input-on-the-page

            - Goal: g
            - Started: 2026-09-17  Ended: 2026-09-17
            - Sessions: 2B671497-FDAD-485B-9288-36DB955A99B6
            - Base: 36d18d0
            - Cost: $7.73 · 7708k in (98% cached) · 50k out · 0h 15m
            - Result: `goals/no-input`, PR #125

            ## Decision
            done
            """
        XCTAssertEqual(Self.disagreements(path: "fixture", number: 1, text: text), [])
        XCTAssertEqual(GoalLedger.parse(text, number: 1).pr, 125, "the ledger now reads the bullet too")
    }

    /// The ordinary shape, `Result:` riding the `- Base:` line: agreed
    /// before and after this chore's fix.
    func testHelperAgreesOnTheOrdinaryBaseResultLine() {
        let text = """
            # Round 022: the-record-names-its-pr

            - Goal: g
            - Started: 2026-09-25T12:36+07:00  Ended: 2026-09-25T12:50+07:00
            - Sessions: D950F247-93C3-4155-9A49-E14DEE01DDC2
            - Base: c8a92ec   Result: 1a6174d on `agent-dashboard/round-22`, PR #162
            - Cost: $1.96 · 5999k in (98% cached) · 21k out · 0h 11m

            ## Decision
            done
            """
        XCTAssertEqual(Self.disagreements(path: "fixture", number: 22, text: text), [])
    }

    // MARK: - a fixture that proves the helper still catches a disagreement

    /// The two parsers build their `PR #N` pattern differently:
    /// `KnowledgeSummary`'s requires the literal words `PR #` before the
    /// digits (`\bPR #([0-9]+)`); `GoalLedger`'s only requires a bare `#`
    /// (`#([0-9]+)\b`), a looser pattern nothing in `LOOP.md`'s shape ever
    /// exercises for real (every real `Result:` value that names a PR writes
    /// `PR #N`), so this never disagreed against real records. It still
    /// proves the harness independently of what any one record in this tree
    /// happens to carry: a shape one parser reads and the other would not.
    func testHelperCatchesAPRPatternOnlyTheLedgerReads() {
        let text = """
            # Round 001: one

            - Goal: g
            - Sessions: 2B671497-FDAD-485B-9288-36DB955A99B6
            - Base: 36d18d0
            - Result: closed via #42

            ## Decision
            done
            """
        let found = Self.disagreements(path: "fixture", number: 1, text: text)
        XCTAssertEqual(found.count, 1, "\(found)")
        let disagreement = try! XCTUnwrap(found.first)
        XCTAssertEqual(disagreement.field, "pr")
        XCTAssertEqual(disagreement.route, "nil", "the route requires the literal words \"PR #\"")
        XCTAssertEqual(disagreement.ledger, "42", "the ledger's pattern accepts a bare #")
    }
}

// MARK: - `GoalLedger.parse`, the standalone bullet against the Base line

/// The four shapes a record's PR and result sha can take, tested directly
/// against `GoalLedger.parse` (not the cross-parser helper above): a
/// standalone `- Result:` bullet alone, `Result:` riding the `- Base:` line
/// alone, both at once (the bullet wins), and a result that names a sha with
/// no PR at all.
final class GoalLedgerResultBulletTests: XCTestCase {
    private func header(_ lines: String) -> String {
        "# Round 001: one\n\n- Goal: g\n- Sessions: 2B671497-FDAD-485B-9288-36DB955A99B6\n" + lines
    }

    func testBulletOnly() {
        let text = header("- Base: 36d18d0\n- Result: `goals/no-input`, PR #125\n")
        let record = GoalLedger.parse(text, number: 1)
        XCTAssertEqual(record.base, "36d18d0")
        XCTAssertEqual(record.pr, 125)
        XCTAssertNil(record.result, "the bullet names a branch, not a sha")
    }

    func testBaseLineOnly() {
        let text = header("- Base: c8a92ec   Result: 1a6174d on `branch`, PR #162\n")
        let record = GoalLedger.parse(text, number: 1)
        XCTAssertEqual(record.base, "c8a92ec")
        XCTAssertEqual(record.pr, 162)
        XCTAssertEqual(record.result, "1a6174d")
    }

    /// Both at once: the bullet wins over the Base line's own `Result:`
    /// value, even though the Base line comes first in the text.
    func testBothTheBulletWins() {
        let text = header("- Base: c8a92ec   Result: aaaaaaa, PR #1\n- Result: bbbbbbb, PR #2\n")
        let record = GoalLedger.parse(text, number: 1)
        XCTAssertEqual(record.base, "c8a92ec")
        XCTAssertEqual(record.pr, 2, "the standalone bullet, not the Base line's Result:")
        XCTAssertEqual(record.result, "bbbbbbb")
    }

    /// A result given as a sha alone names no PR, on either shape.
    func testShaOnlyNamesNoPR() {
        let text = header("- Base: c8a92ec   Result: 1a6174d\n")
        let record = GoalLedger.parse(text, number: 1)
        XCTAssertEqual(record.result, "1a6174d")
        XCTAssertNil(record.pr)
    }
}
