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

    /// The `STATE.md` template is the short shape and nothing else.
    func testStateTemplateIsTheShortShape() {
        let headings = GoalsTemplates.state.split(separator: "\n").filter { $0.hasPrefix("## ") }.map(String.init)
        XCTAssertEqual(headings, ["## Queue", "## Failures", "## Proposals waiting on the human", "## Done", "## Next action"])
        let bullets = GoalsTemplates.state.split(separator: "\n").filter { $0.hasPrefix("- ") }
            .map { $0.prefix { $0 != ":" } }
        XCTAssertEqual(bullets, ["- Status", "- Round", "- Rounds total", "- Last floor", "- Updated"])
    }
}
