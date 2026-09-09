import Foundation
import XCTest

@testable import KittermDaemon

/// `KnowledgeSummary.parse` on string fixtures, `KnowledgeFile.summaries`
/// on a package with three folders, and both on this repository's own
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

    func testControlAndBidiCharactersAreDropped() {
        XCTAssertEqual(KnowledgeSummary.cap("a\u{202E}b\u{0007}c\u{2066}d\u{0085}e", bytes: 64), "abcde")
        XCTAssertEqual(KnowledgeSummary.cap("é\u{202A}é", bytes: 2), "é", "the cap counts the kept bytes only")
        let goal = KnowledgeSummary.parse(state: nil, goal: "# Goal: \u{202E}evil\u{202C}", roundNames: [], latestRound: nil)
        XCTAssertEqual(goal.goal, "evil")
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
        let package = root.appendingPathComponent("docs/goals/projects-and-knowledge")
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("STATE.md").path) else {
            throw XCTSkip("docs/goals/projects-and-knowledge is not beside the test source")
        }
        let summary = KnowledgeFile.summary(root: root.path, knowledge: "docs/goals/projects-and-knowledge")
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

    // MARK: - one summary per goal folder

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A scratch package: `LOOP.md` and `facts.md` at the top, `zed/`
    /// active with a record, `alpha/` done whose heading names another
    /// slug, and `notes/` with no `STATE.md`.
    private func threeFolders() throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-knowledge-summaries-\(UUID().uuidString)")
        let files: [String: String] = [
            "docs/goals/LOOP.md": "# LOOP\n",
            "docs/goals/facts.md": "# Facts\n",
            "docs/goals/zed/STATE.md": "# STATE: zed\n\n- Status: active\n- Round: 1 of 3\n\n## Next action\n\nRound 2.\n",
            "docs/goals/zed/goal.md": "# Goal: zed ships\n",
            "docs/goals/zed/rounds/001.md": "# Round 001\n\n## Decision\n\npropose (x)\n",
            "docs/goals/alpha/STATE.md": "# STATE: not-alpha\n\n- Status: done\n",
            "docs/goals/alpha/rounds/003.md": "# Round 003\n\n## Decision\n\ndone.\n",
            "docs/goals/notes/README.md": "not a goal\n",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.path
    }

    func testSummariesListEveryGoalFolder() throws {
        let root = try threeFolders()
        let goals = try XCTUnwrap(KnowledgeFile.summaries(root: root, knowledge: "docs/goals"))
        XCTAssertEqual(goals.map(\.slug), ["zed", "alpha"], "active before done; `notes/` has no STATE.md")
        XCTAssertEqual(goals[0].status, "active")
        XCTAssertEqual(goals[0].goal, "zed ships")
        XCTAssertEqual(goals[0].round, 1)
        XCTAssertEqual(goals[0].nextAction, "Round 2.")
        XCTAssertEqual(goals[0].lastRound, 1)
        XCTAssertEqual(goals[0].lastRecord, "zed/rounds/001.md", "the record path carries the folder")
        XCTAssertEqual(goals[0].lastDecision, "propose (x)")
        XCTAssertEqual(goals[1].slug, "alpha", "the folder name, not the `# STATE:` heading")
        XCTAssertEqual(goals[1].status, "done")
        XCTAssertEqual(goals[1].lastRecord, "alpha/rounds/003.md")
        XCTAssertNil(goals[1].goal)
        XCTAssertNil(KnowledgeFile.summaries(root: root, knowledge: "docs/none"), "no knowledge directory")
        XCTAssertEqual(KnowledgeFile.summaries(root: root, knowledge: "docs/goals/notes"), [], "a folder with no goal folder")
    }

    /// A child whose name is not a slug is not a goal: a right-to-left
    /// override, a space, an upper-case letter, or a trailing hyphen in
    /// the folder name never reaches `slug`, the sub-header, or the record
    /// path, whatever its `STATE.md` says.
    func testSummariesSkipAFolderWhoseNameIsNotASlug() throws {
        let root = try threeFolders()
        for name in ["\u{202E}zed", "with space", "Upper", "trailing-", "-leading", "dots.md"] {
            let folder = root + "/docs/goals/" + name
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try "# STATE: \(name)\n\n- Status: active\n".write(toFile: folder + "/STATE.md", atomically: true, encoding: .utf8)
        }
        let goals = try XCTUnwrap(KnowledgeFile.summaries(root: root, knowledge: "docs/goals"))
        XCTAssertEqual(goals.map(\.slug), ["zed", "alpha"])
        for slug in goals.compactMap(\.slug) {
            XCTAssertTrue(ProjectStore.isValidID(slug), slug)
        }
    }

    /// Every descriptor the listing opens is closed: the knowledge
    /// directory, each goal folder, each file, and `rounds/`, on the
    /// skipped folders too.
    func testSummariesLeaveNoDescriptorOpen() throws {
        let root = try threeFolders()
        try FileManager.default.createSymbolicLink(
            atPath: root + "/docs/goals/linked", withDestinationPath: root + "/docs/goals/zed")
        let open = { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
        let before = try open()
        for _ in 0..<3 {
            XCTAssertEqual(KnowledgeFile.summaries(root: root, knowledge: "docs/goals")?.count, 2)
        }
        XCTAssertEqual(try open(), before, "no descriptor leaks per listing")
    }

    /// At most `maxGoalFolders` folders are read, the first in name order;
    /// the rest are skipped, so a checkout with thousands of folders costs
    /// one bounded listing.
    func testSummariesReadAtMostTheCapInNameOrder() throws {
        let root = try threeFolders()
        let cap = KnowledgeFile.maxGoalFolders
        for n in 0..<(cap + 5) {
            let folder = root + "/docs/goals/g" + String(format: "%03d", n)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try "# STATE: g\(n)\n\n- Status: active\n".write(toFile: folder + "/STATE.md", atomically: true, encoding: .utf8)
        }
        let goals = try XCTUnwrap(KnowledgeFile.summaries(root: root, knowledge: "docs/goals"))
        XCTAssertEqual(goals.count, cap)
        let slugs = Set(goals.compactMap(\.slug))
        XCTAssertTrue(slugs.contains("alpha"), "`alpha` sorts first by name")
        XCTAssertTrue(slugs.contains("g000"))
        XCTAssertFalse(slugs.contains("zed"), "`zed` sorts after the cap by name")
        XCTAssertFalse(slugs.contains("g" + String(format: "%03d", cap + 4)))
    }

    /// The order the summary route and `kitterm goal list` share: the same
    /// slugs and statuses `GoalCommandTests.testListOrdersByStatusThenSlug`
    /// pins, in the same order.
    func testListOrderIsTheOneTheCLIPins() {
        let folders: [(String, String?)] = [
            ("zed", "active"), ("alpha", "done"), ("beta", "stopped"), ("mid", "waiting"),
            ("gamma", "active"), ("odd", "paused"), ("bare", nil), ("blank", nil),
        ]
        let goals = folders.map { slug, status -> KnowledgeSummary in
            var goal = KnowledgeSummary()
            goal.slug = slug
            goal.status = status
            return goal
        }.sorted(by: KnowledgeSummary.isOrderedBefore)
        XCTAssertEqual(goals.map(\.slug), ["gamma", "zed", "mid", "beta", "alpha", "bare", "blank", "odd"])
        XCTAssertEqual(KnowledgeSummary.statusOrder, ["active", "waiting", "stopped", "done"])
        XCTAssertEqual(KnowledgeSummary.statusRank(nil), 4)
        XCTAssertEqual(KnowledgeSummary.statusRank("paused"), 4)
        XCTAssertEqual(KnowledgeSummary.statusRank("unknown"), 4, "the CLI's word for a missing line ranks the same")
    }

    /// This repository's own package as the second fixture: `goal-folders`
    /// before `projects-and-knowledge` (done), every `done` goal after every
    /// `active` one. Containment and order only, so a new goal folder or an
    /// edited `goal.md` title keeps the floor green.
    func testSummariesOfThisRepositoryOwnPackage() throws {
        let root = Self.repositoryRoot
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/goals/goal-folders/STATE.md").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/goals/projects-and-knowledge/STATE.md").path)
        else { throw XCTSkip("docs/goals is not beside the test source") }
        let goals = try XCTUnwrap(KnowledgeFile.summaries(root: root.path, knowledge: "docs/goals"))
        let slugs = goals.map(\.slug)
        let folders = try XCTUnwrap(slugs.firstIndex(of: "goal-folders"))
        let done = try XCTUnwrap(slugs.firstIndex(of: "projects-and-knowledge"))
        XCTAssertLessThan(folders, done, "goal-folders before projects-and-knowledge")
        let statuses = goals.map(\.status)
        if let lastActive = statuses.lastIndex(of: "active"), let firstDone = statuses.firstIndex(of: "done") {
            XCTAssertLessThan(lastActive, firstDone, "every done goal after every active one")
        }
        XCTAssertEqual(goals[done].status, "done")
        XCTAssertNotNil(goals[done].goal, "goal.md has a title")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(goals[done].lastRound), 8)
        XCTAssertTrue(try XCTUnwrap(goals[done].lastRecord).hasPrefix("projects-and-knowledge/rounds/"))
        XCTAssertNotNil(goals[folders].status)
        XCTAssertNotNil(goals[folders].nextAction)
        XCTAssertNotNil(goals[folders].goal, "goal.md has a title")
    }
}
