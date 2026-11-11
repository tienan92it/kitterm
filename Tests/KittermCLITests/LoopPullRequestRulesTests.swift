import Foundation
import XCTest

@testable import KittermCLI
@testable import KittermDaemon

/// The pull request opens before the crew starts (`foreman-flow` round 1,
/// capability 1). The rule is written once and read in five places: the
/// three copies of `LOOP.md` carry the contract, the two copies of the
/// foreman skill carry the procedure, and `docs/foreman.md` names both.
/// Each sentence below must be held whole; only the line breaks may differ,
/// the `GoalsLayoutDocsTests` check. Three rules name a branch: `main` for
/// `docs/goals/LOOP.md` (kitterm's own base branch), the base branch for
/// every other copy (`base-branch` chore, so the sentence differs there
/// and is pinned apart, in `kittermLoopRules` and `genericLoopRules`).
final class LoopPullRequestRulesTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    static let loopRules: [(rule: String, sentence: String)] = [
        (
            "a goal's branch and a chore's branch have one name each",
            "A goal's branch is `goal/<slug>`. A chore's branch is `chore/<slug>`."
        ),
        (
            // Chartered by `one-rule-one-place` round 1: "when the foreman
            // writes the record" became "when `kitterm round close` writes the
            // record"; the three places are kept.
            "the number goes on the queue line, on the session and in the record at once",
            """
            The pull request's number goes in three places: on the queue line in
            `STATE.md`, as `, PR #N.` at the end of the item's first line; on the
            crew session, as the label `pr:<N>`; and in the round record's
            `Result:`, when `kitterm round close` writes the record. No record
            needs a later commit to name its pull request.
            """
        ),
        (
            // Chartered by `one-rule-one-place` round 1: the sentence read
            // `A goal keeps its one branch and its one pull request for all its
            // rounds.`; the records show 6 pull requests for `code-editor` and
            // 4 for `sessions-workflow`, so the rule says the practice. One
            // branch per goal, the ready mark and the human merge are kept.
            "a goal keeps one branch, a pull request stays open while the human leaves it, and the human merges",
            """
            A goal keeps its one branch for all its rounds, and an open pull
            request for as many rounds as the human leaves it open. Each round's
            record and `STATE.md` commit land on that branch. The human can merge
            the pull request before the goal is done; the next `kitterm round open`
            then opens a new one.
            """
        ),
        (
            "the foreman marks the pull request ready when the goal is done, and the human merges",
            "When the goal is done, the foreman runs `gh pr ready <N>`, and the human merges."
        ),
        (
            "the foreman cannot merge",
            "The foreman cannot merge: the auto-mode classifier refuses `gh pr merge`."
        ),
        (
            "`pr` is a reserved label",
            "| `pr` | pull request number, the one the queue line names | foreman |"
        ),
    ]

    /// `docs/goals/LOOP.md` is kitterm's own copy (`base-branch` chore):
    /// kitterm's base branch is `main`, and this file keeps naming it.
    static let kittermLoopRules: [(rule: String, sentence: String)] = [
        (
            // Chartered by `one-rule-one-place` round 1: the sentence read
            // `Before it spawns the crew, the foreman commits the queue line,
            // pushes the branch, and opens a draft pull request with
            // `gh pr create --draft`.`; `kitterm round open` does those steps.
            "the draft pull request opens before the crew is spawned",
            """
            `kitterm round open` does every step before the crew starts: it cuts
            the branch, commits the queue line, pushes the branch, opens a draft
            pull request with `gh pr create --draft` when none is open, and spawns
            the crew session.
            """
        ),
        (
            "a crew pushes to its branch and never to main",
            """
            A crew pushes to its branch after each commit. A crew never pushes to
            `main`, never force-pushes, and never merges.
            """
        ),
        (
            "the foreman rebases every open branch after a merge to main",
            """
            After any merge to `main`, the foreman rebases every open goal or chore
            branch onto `main` and pushes each one with `--force-with-lease`.
            """
        ),
    ]

    /// `examples/goals/LOOP.md` and its embedded copy serve every registered
    /// project, so they name the base branch instead of hardcoding `main`
    /// (`base-branch` chore): other projects on this machine use `develop`
    /// or `dev`.
    static let genericLoopRules: [(rule: String, sentence: String)] = [
        (
            // Chartered by `one-rule-one-place` round 1, as in `kittermLoopRules`.
            "the draft pull request opens before the crew is spawned",
            """
            `kitterm round open` does every step before the crew starts: it cuts
            the branch, commits the queue line, pushes the branch, opens a draft
            pull request with `gh pr create --draft --base <base>` when none is
            open, and spawns the crew session.
            """
        ),
        (
            "a crew pushes to its branch and never to the base branch",
            """
            A crew pushes to its branch after each commit. A crew never pushes to
            the base branch, never force-pushes, and never merges.
            """
        ),
        (
            "the foreman rebases every open branch after a merge to the base branch",
            """
            After any merge to the base branch, the foreman rebases every open goal
            or chore branch onto `origin/<base>` and pushes each one with
            `--force-with-lease`.
            """
        ),
    ]

    static let skillRules: [(rule: String, sentence: String)] = [
        (
            "the prompt tells the crew to push after each commit and never to the base branch",
            """
            commit on the branch and push it after each commit, so the human
            watches the diff on the pull request; never push to the base branch,
            never force-push, never merge; do not commit under `docs/goals/`;
            """
        ),
        (
            // Chartered by `one-rule-one-place` round 1: the skill typed
            // `spawn_session ... labels={crew:"<slug>", goal:"<slug>",
            // round:"<n>", task:"<queue-item>", pr:"<N>"}`; `kitterm round open`
            // spawns the session with the five labels of `LOOP.md`, "Labels",
            // which pins the `pr` row.
            "the crew session is spawned by `kitterm round open` with the five labels",
            """
            kitterm round open <root> <slug> --task <queue-item>
            """
        ),
        (
            "the crew session carries the five labels of the loop",
            "crew, up to one crew session in the worktree of `goal/<slug>` with the five labels and no input"
        ),
        (
            "the foreman rebases every open branch after the human's merge",
            """
            rebase every open goal or chore branch onto `origin/<base>` and push each one
            with `--force-with-lease`.
            """
        ),
        (
            "the foreman marks the pull request ready when the goal is done",
            "When the goal is done, run `gh pr ready <N>`; the human merges."
        ),
    ]

    /// The wording capability 1 retired: a crew used to commit and not push.
    static let retiredWordings = [
        "commit on the branch, do not push",
        "with the four labels and no `input`",
    ]

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func loopFiles() throws -> [(name: String, text: String)] {
        [
            ("docs/goals/LOOP.md", try read("docs/goals/LOOP.md")),
            ("examples/goals/LOOP.md", try read("examples/goals/LOOP.md")),
            ("GoalsTemplates.loop", GoalsTemplates.loop),
        ]
    }

    private static func skillFiles() throws -> [(name: String, text: String)] {
        [
            ("examples/foreman/foreman-loop.md", try read("examples/foreman/foreman-loop.md")),
            ("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop),
        ]
    }

    func testTheLoopFilesCarryThePullRequestRules() throws {
        for (name, text) in try Self.loopFiles() {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.loopRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(sentence)")
            }
        }
    }

    /// `docs/goals/LOOP.md` alone: kitterm's base branch is `main`.
    func testDocsGoalsLoopNamesMainAsKittermsOwnBaseBranch() throws {
        let text = try Self.read("docs/goals/LOOP.md")
        let oneLine = Self.oneLine(text)
        for (rule, sentence) in Self.kittermLoopRules where !oneLine.contains(Self.oneLine(sentence)) {
            XCTFail("docs/goals/LOOP.md does not carry the rule that \(rule), in these words: \(sentence)")
        }
    }

    /// The generic template and its embedded copy: every registered project
    /// may have a different base branch, so neither hardcodes `main`.
    func testGenericLoopFilesNameTheBaseBranchNotMain() throws {
        for (name, text) in [
            ("examples/goals/LOOP.md", try Self.read("examples/goals/LOOP.md")),
            ("GoalsTemplates.loop", GoalsTemplates.loop),
        ] {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.genericLoopRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(sentence)")
            }
        }
    }

    func testTheSkillCarriesThePullRequestProcedure() throws {
        for (name, text) in try Self.skillFiles() {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.skillRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(sentence)")
            }
        }
    }

    func testNoCopyStillTellsTheCrewNotToPush() throws {
        for (name, text) in try Self.loopFiles() + Self.skillFiles() {
            let oneLine = Self.oneLine(text)
            for retired in Self.retiredWordings where oneLine.contains(Self.oneLine(retired)) {
                XCTFail("\(name) still carries the wording capability 1 retired: `\(retired)`")
            }
        }
    }

    /// Chartered by `one-rule-one-place` round 1: `docs/foreman.md` restated
    /// the branch, the label and the merge; it now names `LOOP.md`, their one
    /// home, which the tests above pin.
    func testTheManualNamesTheBranchTheLabelAndTheMerge() throws {
        let manual = Self.oneLine(try Self.read("docs/foreman.md"))
        for phrase in ["`goal/<slug>`", "`docs/goals/LOOP.md` gives the scope, the package, the branch `goal/<slug>`, its pull request and the merge"] {
            XCTAssertTrue(manual.contains(Self.oneLine(phrase)), "docs/foreman.md names \(phrase)")
        }
    }

    /// The label the table reserves is the constant the daemon passes through.
    func testTheReservedKeyIsTheDaemonsConstant() {
        XCTAssertEqual(SessionLabels.prKey, "pr")
        XCTAssertTrue(GoalsTemplates.loop.contains("| `\(SessionLabels.prKey)` |"))
    }
}
