import Foundation
import XCTest

@testable import KittermCLI

/// The foreman protocol — a task list beside the package, a note's first
/// line naming its kind, the `FOREMAN:` prefix on every message into a crew
/// pane, and the one-automatic-continue stall rule (`foreman-protocol`,
/// capability 1). The rule is written once and read in three places: the
/// skill, its embedded copy, and `docs/foreman.md`, where it states the
/// rule. Each sentence below must be held whole; only the line breaks may
/// differ, the pattern of `LoopScopeRulesTests`.
final class ForemanProtocolRulesTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    static let protocolRules: [(rule: String, sentence: String)] = [
        (
            "a task's subject names the project, the slug, the round or chore, and the pull request",
            """
            One task per open round or chore, subject `<project> / <slug> round
            <n>: <queue item> · PR #N` (a chore: `<project> / chore <slug>: <what>
            · PR #N`), with an `activeForm`.
            """
        ),
        (
            "a crew note's first line names its kind, one of four",
            """
            Every crew note's first line is `<KIND> <slug> r<n>: <one line>` (a
            chore writes `<KIND> <slug>: <one line>`), and `KIND` is one of
            `PLAN`, `PROGRESS`, `BLOCKER`, or `DONE`
            """
        ),
        (
            "every message into a crew pane starts with the FOREMAN: prefix",
            """
            Every message the foreman types into a crew pane starts with
            `FOREMAN:` and carries one instruction. The crew treats `FOREMAN:`
            text as the foreman's word.
            """
        ),
        (
            "one automatic continue per round, then the human's word",
            """
            One automatic continue per round. A second stall in the round: report
            it to the human at once and wait for the human's word.
            """
        ),
    ]

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func files() throws -> [(name: String, text: String)] {
        [
            ("examples/foreman/foreman-loop.md", try read("examples/foreman/foreman-loop.md")),
            ("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop),
            ("docs/foreman.md", try read("docs/foreman.md")),
        ]
    }

    func testEveryFileCarriesTheProtocolRules() throws {
        for (name, text) in try Self.files() {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.protocolRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(sentence)")
            }
        }
    }

    /// The skill's own copy and the embedded one cannot drift; `ForemanSkillsTests`
    /// pins the whole file equal, this pins the rule inside it.
    func testTheSkillAndItsEmbeddedCopyAgree() throws {
        let onDisk = try Self.read("examples/foreman/foreman-loop.md")
        XCTAssertEqual(onDisk, ForemanSkills.foremanLoop)
    }

    /// Round 2 of `foreman-event-driven`: the skill stops holding an in-turn
    /// `wait_for_events` poll for the whole daemon and adopts
    /// delegate → report → yield → woken instead, naming `kitterm foreman
    /// watch`. `docs/foreman.md` still describes the old model (round 2's
    /// authority does not reach it), so only the skill and its embedded
    /// mirror are checked here — unlike `testEveryFileCarriesTheProtocolRules`
    /// above, which checks all three files for the unrelated protocol rules.
    private static func skillAndMirror() throws -> [(name: String, text: String)] {
        [
            ("examples/foreman/foreman-loop.md", try read("examples/foreman/foreman-loop.md")),
            ("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop),
        ]
    }

    /// The sentence this round retires: holding one `wait_for_events` for
    /// the whole daemon inside the foreman's own turn. Run against the
    /// pre-change text, this assertion fails — which is the proof the round
    /// asks for that the new assertions below are not vacuous.
    func testTheSkillNoLongerHoldsAnInTurnEventWaitForTheWholeDaemon() throws {
        for (name, text) in try Self.skillAndMirror() {
            XCTAssertFalse(
                Self.oneLine(text).contains(Self.oneLine("Hold one `wait_for_events` for the whole daemon")),
                "\(name) still holds an in-turn `wait_for_events` loop for the whole daemon"
            )
        }
    }

    /// The foreman names `kitterm foreman watch`, runs it in the background,
    /// and yields its turn after delegating — never `curl` (`GoalsLayoutDocsTests`
    /// bans it in the skill), and never an in-turn wait.
    func testTheSkillRunsForemanWatchInTheBackgroundAndYields() throws {
        for (name, text) in try Self.skillAndMirror() {
            XCTAssertTrue(text.contains("kitterm foreman watch"), "\(name) names `kitterm foreman watch`")
            XCTAssertTrue(
                Self.oneLine(text).contains(Self.oneLine(
                    "do not hold an event wait inside this turn: start `kitterm foreman watch` in the background and end your turn"
                )),
                "\(name) yields its turn after starting `kitterm foreman watch` in the background"
            )
            XCTAssertFalse(text.contains("curl"), "\(name) names no shell workaround")
        }
    }

    /// `kitterm foreman watch` is scoped to the foreman's own live crew
    /// sessions, never the whole daemon: one `--session` per live crew, and
    /// never the round's `crew:helper`.
    func testForemanWatchIsScopedToTheForemansOwnLiveCrews() throws {
        for (name, text) in try Self.skillAndMirror() {
            XCTAssertTrue(
                Self.oneLine(text).contains(Self.oneLine(
                    "One `--session` per live crew in your scope — the round's own session, and any other goal's crew still running."
                )),
                "\(name) scopes the watch to its own live crews"
            )
            XCTAssertTrue(
                Self.oneLine(text).contains(Self.oneLine("Never name a `crew:helper` session")),
                "\(name) never watches a helper session"
            )
        }
    }

    /// The human's own words (`corpus/00-request.md` rule 5): the foreman
    /// reports after each crew completes its piece of work, not while it
    /// runs.
    func testTheSkillReportsAfterEachCrewCompletes() throws {
        for (name, text) in try Self.skillAndMirror() {
            XCTAssertTrue(
                Self.oneLine(text).contains(Self.oneLine(
                    "Report after each crew completes, not while it runs"
                )),
                "\(name) reports after each crew completes, not while it runs"
            )
        }
    }
}
