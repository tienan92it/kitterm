import Foundation
import XCTest

@testable import KittermDaemon

/// `KnowledgeSummary.parse` on string fixtures and on this repository's own
/// `docs/goals/`, read from the source tree.
final class KnowledgeSummaryTests: XCTestCase {
    private let state = """
        # STATE: projects-and-knowledge

        - Status: active
        - Round: 2 of 3 in this budget (second budget)
        - Rounds total: 5
        - Last floor: green (2026-09-08, round 5 after)
        - Updated: 2026-09-08

        ## Queue

        1. `knowledge-on-dashboard` (capability 5)

        ## Proposals waiting on the human

        - `plan.md` capability 1: the resolution rule.
          Decide before the PR merges.
        - `LOOP.md` Authority: a count pin is Propose, not Frozen.
          - a nested note is not a proposal
        - Decided 2026-09-08 by "continue".

        ## Next action

        Round 3: dashboard.
        Send the capability 2 row from `plan.md`.

        A second paragraph is not the next action.
        """

    private let goal = """
        # Goal: projects on the fleet view, and a knowledge base per project

        Status: active (opened 2026-09-08).
        """

    func testParsesEveryField() {
        let round = """
            # Round 002: dashboard

            ## Decision

            propose (`plan.md` capability 1: decide the resolution rule.)
            """
        let summary = KnowledgeSummary.parse(
            state: state, goal: goal, roundNames: ["001.md", "002.md", "README.md", "003.txt"], latestRound: round
        )
        XCTAssertEqual(summary.slug, "projects-and-knowledge")
        XCTAssertEqual(summary.goal, "projects on the fleet view, and a knowledge base per project")
        XCTAssertEqual(summary.status, "active")
        XCTAssertEqual(summary.round, 2)
        XCTAssertEqual(summary.budget, 3)
        XCTAssertEqual(summary.lastFloor, "green (2026-09-08, round 5 after)")
        XCTAssertEqual(summary.nextAction, "Round 3: dashboard. Send the capability 2 row from `plan.md`.")
        XCTAssertEqual(summary.proposals, 3, "top-level bullets only; the nested one is a note")
        XCTAssertEqual(summary.lastRound, 2)
        XCTAssertEqual(summary.lastDecision, "propose (`plan.md` capability 1: decide the resolution rule.)")
    }

    func testLatestRecordKeepsItsRealName() {
        XCTAssertEqual(KnowledgeSummary.latestRecordName(["001.md", "7.md", "0006.md", "README.md"]), "7.md")
        XCTAssertEqual(KnowledgeSummary.latestRecordName(["notes.md"]), nil)
        let summary = KnowledgeSummary.parse(
            state: nil, goal: nil, roundNames: ["005.md", "7.md"], latestRound: "## Decision\n\npropose (x)\n"
        )
        XCTAssertEqual(summary.lastRound, 7)
        XCTAssertEqual(summary.lastRecord, "rounds/7.md", "the link opens the file that was read")
        XCTAssertEqual(summary.lastDecision, "propose (x)")
        XCTAssertEqual(summary.json["lastRecord"] as? String, "rounds/7.md")
        XCTAssertNil(KnowledgeSummary.parse(state: nil, goal: nil, latestRecord: nil, latestRound: "## Decision\n\nx").lastRecord)
    }

    func testRoundCounterKeepsTheBudgetAfterAComma() {
        XCTAssertEqual(KnowledgeSummary.roundCounter("3 of 3, budget spent").1, 3)
        XCTAssertEqual(KnowledgeSummary.roundCounter("3 of 3 (budget spent)").1, 3)
        XCTAssertEqual(KnowledgeSummary.roundCounter("2 of 3 in this budget").0, 2)
        XCTAssertNil(KnowledgeSummary.roundCounter("of 3").0)
        XCTAssertNil(KnowledgeSummary.roundCounter("3 of x").1)
    }

    func testEveryFieldIsAbsentWithoutTheFiles() {
        let summary = KnowledgeSummary.parse(state: nil, goal: nil, roundNames: [], latestRound: nil)
        XCTAssertEqual(summary, KnowledgeSummary())
        XCTAssertTrue(summary.json.isEmpty)
    }

    func testMissingLinesLeaveTheirFieldsAbsent() {
        let sparse = """
            # STATE: sparse

            - Status:
            - Round: soon

            ## Next action

            ## Proposals waiting on the human

            No bullets here.
            """
        let summary = KnowledgeSummary.parse(state: sparse, goal: "no heading here", roundNames: [], latestRound: nil)
        XCTAssertEqual(summary.slug, "sparse")
        XCTAssertNil(summary.status, "an empty value is absent")
        XCTAssertNil(summary.round, "`soon` is not a number")
        XCTAssertNil(summary.budget)
        XCTAssertNil(summary.nextAction, "an empty section is absent")
        XCTAssertEqual(summary.proposals, 0, "the section exists with no bullet")
        XCTAssertNil(summary.goal, "goal.md without a `# ` heading has no title")
        XCTAssertNil(summary.lastRound)
    }

    func testMalformedTextIsNeverAnError() {
        let junk = String(repeating: "## ## # - : \u{0} \r\n", count: 50) + "- Round: of of of\n# STATE:\n"
        let summary = KnowledgeSummary.parse(state: junk, goal: junk, roundNames: ["x.md", ".md", "12"], latestRound: junk)
        XCTAssertNil(summary.slug, "an empty slug is absent")
        XCTAssertNil(summary.round)
        XCTAssertNil(summary.lastRound)
    }

    func testGoalTitleKeepsAHeadingWithoutThePrefix() {
        XCTAssertEqual(KnowledgeSummary.goalTitle("# Ship it\n"), "Ship it")
        XCTAssertEqual(KnowledgeSummary.goalTitle("intro\n\n#   Goal:   spaced  \n# second"), "spaced")
    }

    func testStateHeadingWithAnotherPrefixGivesNoSlug() {
        XCTAssertNil(KnowledgeSummary.heading("# Round 001: x", prefix: "STATE:"))
    }

    func testNextActionIsCappedOnACharacterBoundary() {
        let long = "## Next action\n\n" + String(repeating: "é", count: 400)
        let summary = KnowledgeSummary.parse(state: long, goal: nil, roundNames: [], latestRound: nil)
        let next = try! XCTUnwrap(summary.nextAction)
        XCTAssertLessThanOrEqual(next.utf8.count, KnowledgeSummary.nextActionCap)
        XCTAssertEqual(next.count, KnowledgeSummary.nextActionCap / 2, "é is two bytes; no split character")
    }

    func testRoundFileNames() {
        XCTAssertEqual(KnowledgeSummary.roundNumber("002.md"), 2)
        XCTAssertEqual(KnowledgeSummary.roundNumber("1000.md"), 1000)
        XCTAssertNil(KnowledgeSummary.roundNumber("002.md.bak"))
        XCTAssertNil(KnowledgeSummary.roundNumber("notes.md"))
        XCTAssertEqual(KnowledgeSummary.roundFileName(2), "002.md")
        XCTAssertEqual(KnowledgeSummary.roundFileName(1000), "1000.md")
    }

    func testSectionStopsAtTheNextHeading() {
        let text = "## Decision\n\ndone.\n\npropose (x)\n## Reflection\nnot this"
        XCTAssertEqual(KnowledgeSummary.section(text, heading: "Decision"), "\ndone.\n\npropose (x)")
        XCTAssertEqual(KnowledgeSummary.firstLine(KnowledgeSummary.section(text, heading: "Decision")!), "done.")
        XCTAssertNil(KnowledgeSummary.section(text, heading: "Missing"))
    }

    /// This repository's own package is the fixture the corpus request
    /// reads. The values pinned here are the ones the file holds on `main`
    /// when this test was written; they change when the foreman updates
    /// `STATE.md`, so only the shape is pinned, not the round.
    func testParsesThisRepositoryOwnPackage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package = root.appendingPathComponent("docs/goals")
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("STATE.md").path) else {
            throw XCTSkip("docs/goals is not beside the test source")
        }
        let summary = KnowledgeFile.summary(root: root.path, knowledge: "docs/goals")
        let parsed = try XCTUnwrap(summary)
        XCTAssertEqual(parsed.slug, "projects-and-knowledge")
        XCTAssertEqual(parsed.goal, "projects on the fleet view, and a knowledge base per project")
        XCTAssertNotNil(parsed.status)
        XCTAssertNotNil(parsed.round)
        XCTAssertNotNil(parsed.budget)
        XCTAssertNotNil(parsed.nextAction)
        XCTAssertNotNil(parsed.proposals)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(parsed.lastRound), 5)
        XCTAssertNotNil(parsed.lastDecision)
    }
}
