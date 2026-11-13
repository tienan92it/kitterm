import Foundation
import XCTest

@testable import KittermCLI

/// Each rule of the goal loop has one home (`one-rule-one-place`, completion
/// condition 3): `docs/goals/LOOP.md` holds the policy, the skill
/// `examples/foreman/foreman-loop.md` holds the procedure, and
/// `docs/foreman.md` holds the set-up and the tools. A stale line in any of
/// them is one an agent will run, so this test fails when a document, or a
/// copy the binary embeds, holds a phrase from the table below. Compare one
/// line, whitespace collapsed and case folded, the pattern of
/// `GoalsLayoutDocsTests`.
final class StaleLoopPhrasesTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    /// The one table: a phrase no document may hold, and what replaced it.
    static let stalePhrases: [(phrase: String, replacedBy: String)] = [
        // A held `wait_for_events` as the foreman's monitor.
        ("Hold one `wait_for_events`", "`kitterm foreman watch` in the background, and the turn yields"),
        ("One `wait_for_events` watches the whole daemon", "`kitterm foreman watch` in the background"),
        ("One `wait_for_events` call watches every session", "`kitterm foreman watch` in the background"),
        // Model ids the skill's model table named before Claude Code 2.1.322.
        ("`claude-fable-5-1`", "`claude-fable-5-2`"),
        ("`claude-sonnet-5`", "`claude-sonnet-5-5`"),
        ("`claude-opus-5[1m]`", "`claude-opus-5-5[1m]`"),
        ("`claude-haiku-4-5-20251001`", "`claude-haiku-5-5`"),
        // Round steps done by hand that `kitterm round open` does.
        ("gh pr create --draft --base <base> --title", "`kitterm round open` opens the draft pull request"),
        ("Write `, PR #N.` at the end of the queue item's first line", "`kitterm round open` writes the queue line"),
        ("The foreman writes `, PR #N.`", "`kitterm round open` writes the queue line"),
        ("spawn_session name=\"<slug> round <n>\"", "`kitterm round open` spawns the crew session"),
        ("Before it spawns the crew, the foreman commits the queue line", "`kitterm round open` commits the queue line"),
        // Round steps done by hand that `kitterm round close` does.
        ("Archive the session, then run `kitterm archive cost", "`kitterm round close` archives and writes the `- Cost:` lines"),
        ("the next action, the round counter, and `Updated`", "`kitterm round close` raises `- Round:` and `- Updated:`"),
        ("Commit the record, the state, and the fact together", "`kitterm round close --commit` after a green `gh pr checks`"),
        ("pastes one `- Cost:` line", "`kitterm round close` writes the `- Cost:` lines"),
        ("`STATE.md` while that check runs", "read `gh pr checks` first; on green, `kitterm round close`"),
        // One pull request per goal, which the records contradict.
        ("its one pull request for all its rounds", "an open pull request for as many rounds as the human leaves it open"),
        ("The human merges, once per goal", "the human merges each pull request"),
        ("merges once per goal", "the human merges each pull request"),
        // The correction rule before `round-commands` round 1.
        ("the correction is a `## Correction` heading", "a `## Correction` section whose text does not start with \"None\""),
        // The correction cap and the hand step before `one-rule-one-place` round 3.
        ("One correction per round", "two corrections per round, then a fresh session (`LOOP.md`, \"Budget\")"),
        ("move the line by hand", "`kitterm round close --decision failed|propose`"),
        // Lines written before a tool shipped, and the old split of the documents.
        ("once capability 1 ships", "`list_projects`"),
        ("`kitterm goal new <path> <slug>` once it exists", "`kitterm goal new <path> <slug>`"),
        ("is the source of the procedure", "the skill holds the procedure"),
        ("`LOOP.md` holds the procedure", "`LOOP.md` holds the policy"),
    ]

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The three documents, the generic template, the two embedded copies,
    /// and `docs/control-plane.md`, which names the round commands.
    private static func documents() throws -> [(name: String, text: String)] {
        [
            ("docs/goals/LOOP.md", try read("docs/goals/LOOP.md")),
            ("examples/goals/LOOP.md", try read("examples/goals/LOOP.md")),
            ("GoalsTemplates.loop", GoalsTemplates.loop),
            ("examples/foreman/foreman-loop.md", try read("examples/foreman/foreman-loop.md")),
            ("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop),
            ("docs/foreman.md", try read("docs/foreman.md")),
            ("docs/control-plane.md", try read("docs/control-plane.md")),
        ]
    }

    func testNoDocumentHoldsAStalePhrase() throws {
        for (name, text) in try Self.documents() {
            let oneLine = Self.oneLine(text)
            for (phrase, replacedBy) in Self.stalePhrases where oneLine.contains(Self.oneLine(phrase)) {
                XCTFail("\(name) holds the stale phrase `\(phrase)`; write \(replacedBy)")
            }
        }
    }

    /// The model table names the ids Claude Code 2.1.322 serves; a renamed id
    /// goes in the table above with the one that replaced it.
    func testTheSkillNamesTheCurrentModelIds() {
        for id in ["`claude-fable-5-2`", "`claude-sonnet-5-5`", "`claude-opus-5-5[1m]`", "`claude-haiku-5-5`"] {
            XCTAssertTrue(ForemanSkills.foremanLoop.contains(id), "the model table names \(id)")
        }
    }
}
