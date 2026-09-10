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

    /// The rules of the loop are written once and read in three places:
    /// `docs/goals/LOOP.md`, its generic derivation `examples/goals/LOOP.md`,
    /// and the `foreman-loop` skill. A rule that lands in one file and not the
    /// others fails here, and so does an embedded copy that lags behind its
    /// file. One marker per rule, chosen to be the words the rule cannot lose.
    static let loopRules: [(rule: String, marker: String)] = [
        ("a killed attempt does not spend the budget", "attempt killed:"),
        ("`resumed-from` may carry the pane's previous id", "the id the pane held before"),
        ("the crew's note goes out before the floor", "note before the floor"),
        ("an assertion this round must change is Propose", "is Propose, not Frozen"),
        ("a crew's helper session carries its own `crew` value", "crew:helper"),
    ]

    func testTheThreeLoopFilesCarryTheSameRules() throws {
        var files: [(name: String, text: String)] = try [
            "docs/goals/LOOP.md",
            "examples/goals/LOOP.md",
            "examples/foreman/foreman-loop.md",
        ].map { (name: $0, text: try String(contentsOf: Self.root.appendingPathComponent($0), encoding: .utf8)) }
        files.append(("GoalsTemplates.loop", GoalsTemplates.loop))
        files.append(("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop))
        for (rule, marker) in Self.loopRules {
            for (name, text) in files where !text.contains(marker) {
                XCTFail("\(name) does not carry the rule that \(rule): no `\(marker)`")
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
