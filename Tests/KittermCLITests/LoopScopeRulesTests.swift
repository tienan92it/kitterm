import Foundation
import XCTest

@testable import KittermCLI
@testable import KittermDaemon

/// A foreman's scope is the projects under its `scope:<path>` label, else
/// its pane's cwd, and "one foreman per daemon" becomes "one foreman per
/// scope" (`foreman-scope` round 3, capability 3). The rule is written once
/// and read in six places: the three copies of `LOOP.md`, the two copies of
/// the foreman skill, and `docs/foreman.md`. Each sentence below must be
/// held whole; only the line breaks may differ, the pattern of
/// `LoopPullRequestRulesTests`.
final class LoopScopeRulesTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    /// Shared, word for word, by `docs/goals/LOOP.md`, `examples/goals/LOOP.md`
    /// and `GoalsTemplates.loop`: none of the three names a literal path or
    /// `main`.
    static let loopRules: [(rule: String, sentence: String)] = [
        (
            "the foreman owns every project in its scope, and one foreman runs per scope",
            """
            One foreman runs per scope, in a kitterm pane named `foreman` with the
            labels `crew:foreman` and `scope:<path>`, on the `foreman-loop` skill and
            """
        ),
        (
            "a foreman's scope is its own `scope:` label, else its cwd, and it acts only inside it",
            """
            A foreman's scope is a directory: the value of its own pane's `scope:<path>`
            label, else its pane's cwd. Its projects are the registered projects whose
            root is the scope or lies under it, plus a project a live session under the
            scope discovers. The foreman reads, schedules, types into, archives, and
            relabels a session only inside its scope; it never acts on a session outside
            it.
            """
        ),
        (
            "one foreman runs per scope, not per daemon, and a second one in or around the same scope is the conflict",
            """
            One foreman runs per scope, not per daemon: another live foreman in a
            different scope is not a conflict. Another live foreman in the same scope,
            or in a scope that holds or sits inside this one, is the conflict: the
            foreman stops and tells the human.
            """
        ),
        (
            "the start step runs the catch-up before anything else and stops on a conflict",
            """
            **Start.** Before anything else, run `kitterm foreman catch-up`, with
            `--scope <path>` when the pane carries a `scope:` label. Read the
            predecessor's note and the last message of its transcript for what the
            human told it. Adopt its open pull requests and its live crews by their
            labels. A second live foreman already in this scope is the conflict
            above: stop and tell the human. Archive a predecessor's pane only on the
            human's word, and only inside this scope.
            """
        ),
        (
            "the upkeep step checks every project in scope and routes behind and edited to a pull request",
            """
            **Upkeep.** At start, and again after `kitterm skills install` changes
            this skill, run `kitterm project init --refresh --check <root>` for
            every project in the scope: `current` leaves it. `behind` runs it as a
            chore on the branch `chore/refresh-loop`, with
            `kitterm project init --refresh <root>`. `edited` opens a draft pull
            request on the project's base branch that brings the new template
            sections into its `LOOP.md`, keeping the project's own lines; the
            human's merge is the Propose-tier approval.
            """
        ),
        (
            "`scope` is a reserved label, set by the foreman on its own pane",
            "| `scope` | the scope directory, an absolute path | foreman, on its own pane |"
        ),
    ]

    /// Shared, word for word, by `examples/foreman/foreman-loop.md` and
    /// `ForemanSkills.foremanLoop`.
    static let skillRules: [(rule: String, sentence: String)] = [
        (
            "the skill's opening line says one foreman per scope",
            "You are the foreman. One foreman runs per scope and serves every project in\nit."
        ),
        (
            "the Rules bullet names the scope and the conflict a foreman stops on",
            """
            One foreman per scope, in a pane named `foreman` with the labels
            `crew:foreman` and `scope:<path>`. Your scope is the value of that label,
            else your pane's cwd. Act only on a project whose root is your scope or
            lies under it, and never on a session outside it. Another live foreman in
            a different scope is not a conflict; one in your own scope, or in a scope
            that holds or sits inside yours, is: stop and tell the human.
            """
        ),
        (
            "the Start section runs the catch-up with the pane's own scope",
            """
            Run `kitterm foreman catch-up`, with `--scope <path>` when your pane
            carries a `scope:` label. It prints the predecessor foreman in your
            scope, the goals not done, the live crews, and the worktrees.
            """
        ),
        (
            "the Upkeep section checks every project in scope",
            """
            For every project in your scope, run
            `kitterm project init --refresh --check <root>`:
            """
        ),
    ]

    /// The wording capability 1 of `foreman-scope` retired: a foreman used
    /// to run per daemon, not per scope.
    static let retiredWordings = [
        "one foreman runs per daemon and serves every project",
        "one foreman runs per daemon and serves every registered project",
        "one foreman per daemon",
        "## one foreman for every project",
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

    func testTheLoopFilesCarryTheScopeRules() throws {
        for (name, text) in try Self.loopFiles() {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.loopRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(sentence)")
            }
        }
    }

    func testTheSkillCarriesTheScopeProcedure() throws {
        for (name, text) in try Self.skillFiles() {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.skillRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(sentence)")
            }
        }
    }

    func testNoCopyStillSaysOneForemanPerDaemon() throws {
        for (name, text) in try Self.loopFiles() + Self.skillFiles() {
            let oneLine = Self.oneLine(text)
            for retired in Self.retiredWordings where oneLine.contains(Self.oneLine(retired)) {
                XCTFail("\(name) still carries the wording capability 3 retired: `\(retired)`")
            }
        }
        let manual = Self.oneLine(try Self.read("docs/foreman.md"))
        let agents = Self.oneLine(try Self.read("AGENTS.md"))
        for retired in Self.retiredWordings {
            XCTAssertFalse(manual.contains(Self.oneLine(retired)), "docs/foreman.md: `\(retired)`")
            XCTAssertFalse(agents.contains(Self.oneLine(retired)), "AGENTS.md: `\(retired)`")
        }
    }

    /// `docs/foreman.md` describes the same rule in its own prose.
    func testTheManualNamesTheScopeAndTheNewSteps() throws {
        let manual = Self.oneLine(try Self.read("docs/foreman.md"))
        for phrase in [
            "One foreman runs per scope and serves every project under it.",
            "`scope:<path>`", "`kitterm foreman catch-up`",
            "`kitterm project init --refresh --check <root>`",
            "## One foreman for every scope",
        ] {
            XCTAssertTrue(manual.contains(Self.oneLine(phrase)), "docs/foreman.md names \(phrase)")
        }
    }

    /// The label the table reserves is the constant the daemon passes through.
    func testTheReservedKeyIsTheDaemonsConstant() {
        XCTAssertEqual(SessionLabels.scopeKey, "scope")
        XCTAssertTrue(GoalsTemplates.loop.contains("| `\(SessionLabels.scopeKey)` |"))
    }
}
