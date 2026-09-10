import Foundation
import XCTest

@testable import KittermCLI

/// Every `docs/goals` mention in the docs, the example skills, the
/// templates, and the strings the binary embeds agrees with the per-goal
/// layout: a goal's files live under `docs/goals/<slug>/`, and there is no
/// done folder. A path of the old flat layout fails the test.
final class GoalsLayoutDocsTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    /// The paths of the flat layout that `goal.md` of `goal-folders`
    /// replaced. `docs/goals/LOOP.md` and `docs/goals/facts.md` stay.
    static let flatLayoutPaths = [
        "docs/goals/STATE.md",
        "docs/goals/goal.md",
        "docs/goals/rounds/",
        "docs/goals/done/",
    ]

    /// The files checked: the three docs that describe the package, and
    /// every file under `examples/`.
    private static func documents() throws -> [(path: String, text: String)] {
        var paths = ["AGENTS.md", "docs/foreman.md", "docs/architecture.md"]
        let examples = root.appendingPathComponent("examples", isDirectory: true)
        paths += try CLIFixture.files(under: examples).keys.sorted().map { "examples/" + $0 }
        return try paths.map { path in
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            return (path, text)
        }
    }

    private func assertLayout(_ text: String, in name: String) {
        for flat in Self.flatLayoutPaths {
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(flat) {
                XCTFail("\(name):\(offset + 1) names the flat layout `\(flat)`: \(line)")
            }
        }
    }

    func testDocsAndExamplesUseTheGoalFolderLayout() throws {
        let documents = try Self.documents()
        XCTAssertGreaterThan(documents.count, 3, "examples/ is read")
        XCTAssertTrue(documents.contains { $0.path == "examples/foreman/foreman-loop.md" })
        for (path, text) in documents {
            assertLayout(text, in: path)
        }
    }

    /// The embedded copies are checked too, so a paste that lags behind the
    /// file cannot ship the flat layout.
    func testEmbeddedStringsUseTheGoalFolderLayout() {
        for (name, contents) in ForemanSkills.files {
            assertLayout(contents, in: "ForemanSkills.\(name)")
        }
        for (path, contents) in GoalsTemplates.files {
            assertLayout(contents, in: "GoalsTemplates.\(path)")
        }
    }

    /// The rules of the loop are written once and read in five places:
    /// `docs/goals/LOOP.md`, its generic derivation `examples/goals/LOOP.md`,
    /// the `foreman-loop` skill, and the two copies the binary embeds. Each
    /// rule below is the sentence that carries it, and every source must hold
    /// that sentence whole; only the line breaks may differ.
    ///
    /// A marker of a few words proves that the words co-occur, not that the
    /// files agree: a file can hold `is Propose, not Frozen` inside a sentence
    /// that states the rule backwards. A sentence cannot hold its own
    /// negation, so the rule itself is the check.
    static let loopRules: [(rule: String, sentence: String)] = [
        (
            "a killed attempt does not spend the budget",
            """
            A round attempt the host machine kills does not spend the budget and
            writes no round record. Note it in `STATE.md` under `Failures` as
            `attempt killed: <ISO date>, <what died>`. Leave the round counter and
            the queue item where they are. Run the round again.
            """
        ),
        (
            "`resumed-from` carries the pane's previous id as well as an archive id",
            "| `resumed-from` | archive id, or the id the pane held before an epoch change | foreman, on a respawn |"
        ),
        (
            "the crew's note goes out before the floor",
            """
            The crew posts its note before the floor, then posts the update after;
            a session that dies at its last step still leaves its evidence.
            """
        ),
        (
            "an assertion this round must change is Chartered, and the crew replaces it",
            """
            An assertion in an existing test file can pin a text, a count, or a
            layout. `goal.md` or the item's proof can require this round to change
            that text, that count, or that layout. The assertion is then Chartered,
            not Frozen. The crew replaces the assertion inside the round and keeps
            its intent. The foreman records the old assertion, the new assertion,
            and the line of `goal.md` or `plan.md` that requires the change. A
            Chartered assertion is not a proposal: the human does not edit the
            file, and the round's decision stays `done`.
            """
        ),
        (
            "a helper carries `crew:helper` with the round's labels, and the crew ends it",
            """
            A session the crew spawns inside the round carries `crew:helper` with
            the round's `goal:` and `round:` labels, and the crew ends it
            """
        ),
        (
            "a round is open while a `crew:<slug>` session is live, and a helper is not one",
            """
            A round is open while a live session carries `crew:<slug>`; a
            `crew:helper` session does not hold the round open.
            """
        ),
        (
            "a review session and a helper count toward the cap of three",
            "A review session and a crew's helper count toward the cap of three."
        ),
    ]

    /// A wording a round replaced. It names a tier or a label that the rule
    /// above now contradicts, so a copy that still carries it disagrees with
    /// the other four whatever else it says.
    static let retiredWordings = [
        "is Propose, not Frozen",
        "no live session carries `goal:<slug>`",
    ]

    /// Collapse every run of whitespace and fold the case, so one sentence
    /// wrapped at two widths, indented inside a Swift literal, or opening a
    /// bullet in lower case, reads as one string.
    private static func oneLine(_ text: String) -> String {
        collapsed(text).lowercased()
    }

    /// The same collapse with the case kept, for a failure message.
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func testTheLoopFilesCarryTheSameRuleSentences() throws {
        var files: [(name: String, text: String)] = try [
            "docs/goals/LOOP.md",
            "examples/goals/LOOP.md",
            "examples/foreman/foreman-loop.md",
        ].map { (name: $0, text: try String(contentsOf: Self.root.appendingPathComponent($0), encoding: .utf8)) }
        files.append(("GoalsTemplates.loop", GoalsTemplates.loop))
        files.append(("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop))
        for (name, text) in files {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.loopRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(Self.collapsed(sentence))")
            }
            for retired in Self.retiredWordings where oneLine.contains(Self.oneLine(retired)) {
                XCTFail("\(name) still carries the wording a round retired: `\(retired)`")
            }
        }
    }

    /// The skill names the goal's files by their folder path, so a round
    /// prompt cannot point a crew at a file that does not exist.
    func testForemanLoopNamesGoalFilesByFolder() {
        let skill = ForemanSkills.foremanLoop
        for path in ["docs/goals/<slug>/STATE.md", "docs/goals/<slug>/goal.md", "docs/goals/<slug>/plan.md", "docs/goals/<slug>/rounds/NNN.md"] {
            XCTAssertTrue(skill.contains(path), "foreman-loop names `\(path)`")
        }
        XCTAssertTrue(skill.contains("post_note"), "the digest goes to the event feed")
        XCTAssertTrue(skill.contains("Commit after every round"), "the package is committed each round")
        XCTAssertTrue(skill.contains("send_input keys=[\"down\"]"), "an arrow key goes by name")
        XCTAssertFalse(skill.contains("curl"), "no shell workaround in the skill")
        XCTAssertFalse(skill.contains("\\u001b[B"), "no arrow key inside a text argument")
    }

    /// The `- Round:` and `- Last floor:` lines have one shape: the
    /// template's line is the skill's shape-block line with its
    /// placeholders filled, and the skill's continue edit writes the same
    /// shape. The card parses `Round: N of M`, so the shape is an interface.
    func testStateLineShapesMatchTheSkill() throws {
        let template = GoalsTemplates.state.split(separator: "\n").map(String.init)
        let skill = ForemanSkills.foremanLoop.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let line = { (lines: [String], key: String) throws -> String in
            try XCTUnwrap(lines.first { $0.hasPrefix("- \(key):") }, "a `- \(key):` line")
        }
        let round = try line(skill, "Round")
        XCTAssertEqual(round, "- Round: <n> of <m> in this budget (<ordinal> budget)")
        let filled = round.replacingOccurrences(of: "<n>", with: "0")
            .replacingOccurrences(of: "<m>", with: "3")
            .replacingOccurrences(of: "<ordinal>", with: "first")
        XCTAssertEqual(try line(template, "Round"), filled)
        XCTAssertEqual(try line(template, "Last floor"), try line(skill, "Last floor"))
        XCTAssertTrue(
            ForemanSkills.foremanLoop.contains("set `Round: 0 of 3 in this budget (<ordinal> budget)`"),
            "the continue edit writes the shape"
        )
        XCTAssertTrue(
            GoalsTemplates.loop.contains("`Round: 0 of 3 in this budget (<ordinal>\n  budget)`"),
            "LOOP.md names the shape"
        )
    }

    /// The template's next action starts with the item and its proof, and
    /// names the goal placeholder apart from the item placeholder.
    func testStateTemplateNextActionStartsWithTheItem() throws {
        let next = try XCTUnwrap(GoalsTemplates.state.components(separatedBy: "## Next action\n\n").last)
        XCTAssertTrue(next.hasPrefix("Round 1: `<item>` from `plan.md` row 1; proof: `<test or screenshot>`."), next)
        XCTAssertEqual(GoalsTemplates.slugPlaceholder, "<goal slug>")
        XCTAssertTrue(next.contains("`goal:<goal slug>`"), next)
        XCTAssertFalse(GoalsTemplates.state.contains("<slug>"), "one placeholder for the goal")
        XCTAssertFalse(GoalsTemplates.state.contains("<capability slug>"), "one placeholder for the item")
        XCTAssertTrue(GoalsTemplates.state.hasPrefix("# STATE: <goal slug>\n"))
    }

    /// The `STATE.md` template is the short shape and nothing else.
    func testStateTemplateIsTheShortShape() {
        let headings = GoalsTemplates.state.split(separator: "\n").filter { $0.hasPrefix("## ") }.map(String.init)
        XCTAssertEqual(headings, ["## Queue", "## Failures", "## Proposals waiting on the human", "## Done", "## Next action"])
        let bullets = GoalsTemplates.state.split(separator: "\n").filter { $0.hasPrefix("- ") }
            .map { $0.prefix { $0 != ":" } }
        XCTAssertEqual(bullets, ["- Status", "- Round", "- Rounds total", "- Last floor", "- Updated"])
    }
}
