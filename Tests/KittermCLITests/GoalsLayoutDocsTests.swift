import Foundation
import XCTest

@testable import KittermCLI

/// Every `docs/goals` mention in the docs, the example skills, the
/// templates, and the strings the binary embeds agrees with the per-goal
/// layout: a goal's files live under `docs/goals/<slug>/`, and there is no
/// done folder. A path of the old flat layout fails the test.
final class GoalsLayoutDocsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // KittermCLITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

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

    /// The skill names the goal's files by their folder path, so a round
    /// prompt cannot point a crew at a file that does not exist.
    func testForemanLoopNamesGoalFilesByFolder() {
        let skill = ForemanSkills.foremanLoop
        for path in ["docs/goals/<slug>/STATE.md", "docs/goals/<slug>/goal.md", "docs/goals/<slug>/plan.md", "docs/goals/<slug>/rounds/NNN.md"] {
            XCTAssertTrue(skill.contains(path), "foreman-loop names `\(path)`")
        }
        XCTAssertTrue(skill.contains("post_note"), "the digest goes to the event feed")
        XCTAssertTrue(skill.contains("Commit after every round"), "the package is committed each round")
        XCTAssertTrue(skill.contains("printf '\\033[B' | curl"), "an arrow key goes through the input route")
        XCTAssertFalse(skill.contains("\\u001b[B"), "no arrow key through send_input")
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
