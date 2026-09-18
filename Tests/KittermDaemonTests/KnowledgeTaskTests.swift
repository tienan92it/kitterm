import Foundation
import XCTest

@testable import KittermDaemon

/// `KnowledgeSummary.tasks`: the fourth level of the fleet view, read from
/// the `## Queue`, `## Failures` and `## Done` sections of `STATE.md`
/// (`agent-dashboard`, capability 3). The shapes are the ones
/// `corpus/inventory.md` measured across thirteen goals.
final class KnowledgeTaskTests: XCTestCase {
    private func parse(_ state: String) -> KnowledgeSummary {
        KnowledgeSummary.parse(state: state, goal: nil, roundNames: [], latestRound: nil)
    }

    func testNumberedQueueIsPendingInQueueOrder() {
        let state = """
            # STATE: x

            ## Queue

            1. `a-task-is-the-fourth-level` (capability 3)
            2. `the-band-replaces-the-strip` (capability 4)
            5. `every-line-is-one-line` (capability 5, last: it shapes the lines the
               others create)
            """
        XCTAssertEqual(parse(state).tasks, [
            .init(slug: "a-task-is-the-fourth-level", state: .pending),
            .init(slug: "the-band-replaces-the-strip", state: .pending),
            .init(slug: "every-line-is-one-line", state: .pending),
        ])
    }

    func testDoneBulletCarriesItsRoundAndItsPR() {
        let state = """
            ## Done

            - `the-foundation-in-the-stylesheet` (capability 2), round 2, PR #126.
              See `rounds/002.md`. `sessions.css` and `tokens.css` are named here.
            - `keep-the-cues` (round 4, the repair), `1c01d28`. See `rounds/004.md`.
            - `four-loop-rules` (capability 4), rounds 4 and 5, `61b3f78` plus the
              foreman's commit.
            - `paced-input-race` (1) and `takeover-race` (2), round 1, `9784fd2`.
            """
        let tasks = parse(state).tasks
        XCTAssertEqual(tasks, [
            .init(slug: "the-foundation-in-the-stylesheet", state: .done, round: 2, pr: 126),
            .init(slug: "keep-the-cues", state: .done, round: 4),
            .init(slug: "four-loop-rules", state: .done, round: 4),
            .init(slug: "paced-input-race", state: .done, round: 1),
            .init(slug: "takeover-race", state: .done, round: 1),
        ], "a continuation line's `sessions.css`, a sha and `rounds/002.md` are not slugs")
        let json = parse(state).json["tasks"] as? [[String: Any]]
        XCTAssertEqual(json?.first?["slug"] as? String, "the-foundation-in-the-stylesheet")
        XCTAssertEqual(json?.first?["state"] as? String, "done")
        XCTAssertEqual(json?.first?["round"] as? Int, 2)
        XCTAssertEqual(json?.first?["pr"] as? Int, 126)
        XCTAssertNil(json?[1]["pr"], "no PR on the line, no key")
    }

    func testEmptySectionIsAnEmptyListNotAnAbsentOne() {
        let state = """
            ## Queue

            Empty. All four capabilities in `plan.md` are done.

            ## Failures

            None.
            """
        XCTAssertEqual(parse(state).tasks, [], "prose under a heading names no task; the level exists and is empty")
        XCTAssertEqual(parse("## Queue\n").tasks, [])
        XCTAssertEqual((parse(state).json["tasks"] as? [[String: Any]])?.count, 0, "the route serves the empty list")
    }

    func testFailuresProseNamesNoTaskAndAFailureItemDoes() {
        let prose = """
            ## Failures

            None in the product. Two attempts at round 1 were killed by the host
            machine; `LiveTakeoverTests` flaked once, see `rounds/001.md`.
            attempt killed: 2026-09-10, the `swift test` run
            """
        XCTAssertEqual(parse(prose).tasks, [], "`swift test`, `LiveTakeoverTests` and `rounds/001.md` are not items")
        let item = """
            ## Failures

            - `takeover-race`, round 2: the floor went red twice.
            """
        XCTAssertEqual(parse(item).tasks, [.init(slug: "takeover-race", state: .failed, round: 2)])
    }

    func testASlugInTwoSectionsIsOneTaskWithTheStateAReaderNeedsMost() {
        let queuedAgain = """
            ## Queue

            1. `the-toggle` (capability 4, again)

            ## Done

            - `the-toggle` (capability 4), round 4, PR #90.
            """
        XCTAssertEqual(parse(queuedAgain).tasks, [.init(slug: "the-toggle", state: .pending)],
                       "pending beats done: the loop runs it again")
        let failedThenDone = """
            ## Queue

            1. `send-on-transition` (capability 3)

            ## Failures

            - `send-on-transition`, round 2: red floor.

            ## Done

            - `send-on-transition` (capability 3), round 3, PR #12.
            """
        XCTAssertEqual(parse(failedThenDone).tasks, [.init(slug: "send-on-transition", state: .failed, round: 2)],
                       "failed beats both; the queue position is kept")
        XCTAssertEqual(KnowledgeSummary.TaskState.failed.rank, 0)
        XCTAssertLessThan(KnowledgeSummary.TaskState.pending.rank, KnowledgeSummary.TaskState.done.rank)
    }

    func testStateWithNoneOfTheHeadingsHasNoTaskList() {
        let state = """
            # STATE: x

            - Status: active
            - Round: 1 of 3

            ## Proposals waiting on the human

            - `plan.md`: one.

            ## Next action

            Round 2.
            """
        let summary = parse(state)
        XCTAssertNil(summary.tasks, "no heading, no level: the goal renders as it did")
        XCTAssertNil(summary.json["tasks"])
        XCTAssertEqual(summary.status, "active", "the other fields are untouched")
        XCTAssertNil(KnowledgeSummary.parse(state: nil, goal: nil, roundNames: [], latestRound: nil).tasks)
    }

    func testTheOrderIsQueueThenFailuresThenDone() {
        let state = """
            ## Done

            - `one` (1), round 1, `rounds/001.md`
            - `dogfood` (6), round 8, `rounds/008.md`

            ## Failures

            * `three`, round 3.

            ## Queue

            1. `two` (2)
            """
        XCTAssertEqual(parse(state).tasks?.map(\.slug), ["two", "three", "one", "dogfood"],
                       "file order does not decide: the head of the queue runs next, a failure needs a person, done is history")
    }

    func testThisRepositorysOwnStateParses() throws {
        // agent-dashboard's `STATE.md` is the fixture the round's screenshot uses.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("docs/goals/agent-dashboard/STATE.md").path
        let text = try XCTUnwrap(try? String(contentsOfFile: path, encoding: .utf8))
        let tasks = try XCTUnwrap(parse(text).tasks)
        XCTAssertTrue(tasks.contains(.init(slug: "no-input-on-the-page", state: .done, round: 1, pr: 125)))
        XCTAssertTrue(tasks.contains { $0.slug == "a-task-is-the-fourth-level" })
        XCTAssertEqual(Set(tasks.map(\.slug)).count, tasks.count, "each slug once")
    }
}
