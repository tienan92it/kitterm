import Foundation
import XCTest

@testable import KittermCLI

/// The embedded templates equal the files under `examples/goals/` byte for
/// byte, so the two cannot drift: the project files at the top and the
/// goal folder under `goal/`. Edit the file, then paste it into
/// `GoalsTemplates.swift`.
final class GoalsTemplatesTests: XCTestCase {
    private static let examples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // KittermCLITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("examples/goals", isDirectory: true)

    func testEveryTemplateMatchesItsExampleFile() throws {
        for (path, contents) in GoalsTemplates.files {
            let file = Self.examples.appendingPathComponent(path)
            let onDisk = try Data(contentsOf: file)
            XCTAssertEqual(onDisk, Data(contents.utf8), "examples/goals/\(path) differs from GoalsTemplates")
        }
    }

    /// Every file under `examples/goals/` is embedded; nothing is left behind.
    func testEveryExampleFileIsEmbedded() throws {
        let onDisk = Set(try CLIFixture.files(under: Self.examples).keys)
        XCTAssertEqual(onDisk, Set(GoalsTemplates.files.map(\.path)))
    }

    /// Two sets: the project files `init` writes and the goal folder `goal
    /// new` writes, the latter under `goal/` in `examples/goals/`.
    func testPackageShape() {
        XCTAssertEqual(GoalsTemplates.project.map(\.path), ["LOOP.md", "facts.md"])
        XCTAssertEqual(
            GoalsTemplates.goal.map(\.path),
            ["goal.md", "plan.md", "STATE.md", "corpus/.gitkeep", "rounds/.gitkeep"]
        )
        XCTAssertEqual(
            GoalsTemplates.files.map(\.path),
            ["LOOP.md", "facts.md", "goal/goal.md", "goal/plan.md", "goal/STATE.md", "goal/corpus/.gitkeep", "goal/rounds/.gitkeep"]
        )
        for (path, contents) in GoalsTemplates.files where !path.hasSuffix(".gitkeep") {
            XCTAssertTrue(contents.hasPrefix("# "), "\(path) starts with a title")
            XCTAssertTrue(contents.hasSuffix("\n"), "\(path) ends with a newline")
        }
    }

    /// The goal's `STATE.md` opens with the heading and the status line the
    /// daemon's summary parser reads, with the slug as the placeholder
    /// `goal new` replaces.
    func testStateTemplateHeadingAndStatus() {
        let lines = GoalsTemplates.state.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "# STATE: \(GoalsTemplates.slugPlaceholder)")
        XCTAssertEqual(GoalsTemplates.slugPlaceholder, "<goal slug>", "apart from the `<item>` placeholder")
        XCTAssertTrue(lines.contains("- Status: active"), "the template opens active")
        XCTAssertFalse(GoalsTemplates.goalFile.contains("Status:"), "status lives in STATE.md only")
    }
}
