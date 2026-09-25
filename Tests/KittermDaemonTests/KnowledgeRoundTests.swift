import Foundation
import XCTest

@testable import KittermDaemon

/// The round records on the knowledge summary (`agent-dashboard`,
/// capability 7): one entry per `rounds/<N>.md` with the task the heading
/// names, the day it started, its `- Cost:` lines summed, the pull request
/// its `- Result:` line names, and whether it carries a `## Correction`
/// section. The `WHERE` panel groups by goal and by task from these; the
/// `LEAKS` lines count them.
final class KnowledgeRoundTests: XCTestCase {
    private let priced = """
        # Round 003: a-task-is-the-fourth-level

        - Goal: agent-dashboard
        - Started: 2026-09-18T09:12+07:00  Ended: 2026-09-18
        - Sessions: 54DE753D-5FAF-46AB-925A-1933F2127D53
        - Base: 86c2da6
        - Cost: $10.99 · 13363k in (98% cached) · 61k out · 0h 18m
        - Result: `goals/task-level`, PR #127

        ## Prompt
        Capability 3 of `plan.md`.

        ## Decision
        done
        """

    private let unpriced = """
        # Round 001: scaffold-and-docs

        - Started: 2026-09-08  Ended: 2026-09-08
        - Base: e586688   Result: 259e38e

        ## Correction
        One correction inside the round.

        ## Decision
        done
        """

    private let bare = """
        # Round 002: the-second

        - Started: soon
        - Result: `goals/x`, merged as a squash
        """

    /// `LOOP.md`'s own shape: `Result:` on the `- Base:` line, no separate
    /// bullet. 74 of 85 kitterm records write it this way (e.g.
    /// `docs/goals/landing-page/rounds/003.md`).
    private let resultOnBaseLine = """
        # Round 003: landing-round

        - Started: 2026-09-20  Ended: 2026-09-20
        - Base: dfdffbc   Result: 5194017 on `landing-page/round-3`, PR #158

        ## Decision
        done
        """

    /// Both shapes on the same record: a `- Result:` bullet and a PR after
    /// `Result:` on the `- Base:` line. The bullet wins.
    private let bothShapes = """
        # Round 004: both-shapes

        - Started: 2026-09-21
        - Base: aaaaaaa   Result: bbbbbbb, PR #100
        - Result: `goals/y`, PR #200

        ## Decision
        done
        """

    func testReadsEveryFieldOfAPricedRecord() {
        let record = KnowledgeSummary.roundRecord(number: 3, text: priced)
        XCTAssertEqual(record, .init(
            number: 3, task: "a-task-is-the-fourth-level", started: "2026-09-18",
            costUSD: 10.99, durationMs: 18 * 60_000, pr: 127, correction: false
        ))
    }

    func testAnUnpricedRecordCarriesNoCostAndNoPullRequest() {
        let record = KnowledgeSummary.roundRecord(number: 1, text: unpriced)
        XCTAssertEqual(record.task, "scaffold-and-docs")
        XCTAssertEqual(record.started, "2026-09-08")
        XCTAssertNil(record.costUSD, "no line, no cost: never a zero")
        XCTAssertNil(record.durationMs)
        XCTAssertNil(record.pr, "the Result on the Base line is a sha, and not on a Result bullet")
        XCTAssertTrue(record.correction)
    }

    func testADateThatIsNotADayAndAResultWithNoNumberLeaveTheirFieldsAbsent() {
        let record = KnowledgeSummary.roundRecord(number: 2, text: bare)
        XCTAssertEqual(record.task, "the-second")
        XCTAssertNil(record.started)
        XCTAssertNil(record.pr)
        XCTAssertFalse(record.correction)
        let empty = KnowledgeSummary.roundRecord(number: 9, text: "")
        XCTAssertEqual(empty, .init(number: 9))
        let titled = KnowledgeSummary.roundRecord(number: 4, text: "# Round 004:\n")
        XCTAssertNil(titled.task)
    }

    func testThePRAfterResultOnTheBaseLineIsReadWithNoResultBullet() {
        let record = KnowledgeSummary.roundRecord(number: 3, text: resultOnBaseLine)
        XCTAssertEqual(record.pr, 158)
    }

    func testAResultBulletWinsOverAPROnTheBaseLine() {
        let record = KnowledgeSummary.roundRecord(number: 4, text: bothShapes)
        XCTAssertEqual(record.pr, 200, "the Result bullet, when a record carries both shapes, wins")
    }

    func testTwoCostLinesSumAndTheJSONOmitsWhatIsAbsent() {
        let two = priced.replacingOccurrences(
            of: "- Result:", with: "- Cost: $1.01 · 100k in (90% cached) · 1k out · 0h 2m\n- Result:"
        )
        let record = KnowledgeSummary.roundRecord(number: 3, text: two)
        XCTAssertEqual(record.costUSD!, 12.0, accuracy: 1e-9)
        XCTAssertEqual(record.durationMs, 20 * 60_000)
        let json = record.json
        XCTAssertEqual(json["number"] as? Int, 3)
        XCTAssertEqual(json["pr"] as? Int, 127)
        XCTAssertEqual(json["correction"] as? Bool, false)
        let bareJSON = KnowledgeSummary.roundRecord(number: 9, text: "").json
        XCTAssertEqual(Set(bareJSON.keys), ["number", "correction"])
    }

    func testTheSummaryListsTheRecordsByNumberAndNoneWithoutARoundsDirectory() {
        var summary = KnowledgeSummary()
        summary.readRounds([(3, priced), (1, unpriced)])
        XCTAssertEqual(summary.rounds?.map(\.number), [1, 3])
        XCTAssertEqual((summary.json["rounds"] as? [[String: Any]])?.count, 2)
        var none = KnowledgeSummary()
        none.readRounds([])
        XCTAssertNil(none.rounds)
        XCTAssertNil(none.json["rounds"])
    }

    /// This repository's own package is the fixture that changes under
    /// the parser every round, so this is a smoke test: every record has a
    /// number and a start day, the first `agent-dashboard` round names its
    /// pull request and its cost, and the counts are plausible rather than
    /// exact (`facts.md`: a test that pins the live tree breaks on the next
    /// record).
    func testThisRepositoryOwnPackage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let goals = try XCTUnwrap(KnowledgeFile.summaries(root: root, knowledge: "docs/goals"))
        let dashboard = try XCTUnwrap(goals.first { $0.slug == "agent-dashboard" })
        let rounds = try XCTUnwrap(dashboard.rounds)
        XCTAssertGreaterThanOrEqual(rounds.count, 5)
        XCTAssertEqual(rounds[0].number, 1)
        XCTAssertEqual(rounds[0].task, "no-input-on-the-page")
        XCTAssertEqual(rounds[0].started, "2026-09-17")
        XCTAssertEqual(rounds[0].pr, 125)
        XCTAssertEqual(rounds[0].costUSD ?? 0, 7.73, accuracy: 1e-9)
        for goal in goals {
            for record in goal.rounds ?? [] {
                XCTAssertNotNil(record.started, "\(goal.slug ?? "?") round \(record.number)")
            }
        }
    }
}
