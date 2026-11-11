import Foundation
import XCTest

@testable import KittermCLI

/// The crew settings file (`one-rule-one-place`, completion condition 5):
/// `examples/foreman/crew-settings.json` equals its embedded copy byte for
/// byte, and holds the deny rules and the guard hook a crew session starts
/// with. A rule removed from the file fails here, not in a crew's push.
final class CrewSettingsTests: XCTestCase {
    private static let file = CLIFixture.repositoryRoot
        .appendingPathComponent("examples/foreman/crew-settings.json")

    func testTheFileEqualsTheEmbeddedCopy() throws {
        XCTAssertEqual(try Data(contentsOf: Self.file), Data(ForemanSkills.crewSettings.utf8))
    }

    /// Every file under `examples/foreman/` that is not a skill is a support
    /// file that `skills install` writes.
    func testEverySupportFileIsEmbedded() throws {
        let examples = Self.file.deletingLastPathComponent()
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: examples.path)
            .filter { !$0.hasSuffix(".md") }
        XCTAssertEqual(Set(onDisk), Set(ForemanSkills.supportFiles.map { ($0.path as NSString).lastPathComponent }))
        for (path, contents) in ForemanSkills.supportFiles {
            let name = (path as NSString).lastPathComponent
            XCTAssertEqual(try Data(contentsOf: examples.appendingPathComponent(name)), Data(contents.utf8), path)
        }
    }

    /// The rules, in the syntax of Claude Code 2.1.322. A path in a
    /// `--settings` file anchors at the file's own folder, so the `Edit`
    /// rules start `//`, the filesystem root.
    func testTheDenyRules() throws {
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(ForemanSkills.crewSettings.utf8)) as? [String: Any]
        )
        let deny = try XCTUnwrap((settings["permissions"] as? [String: Any])?["deny"] as? [String])
        XCTAssertEqual(deny, [
            "Bash(gh pr merge)",
            "Bash(gh pr merge *)",
            "Bash(kitterm start)",
            "Bash(kitterm start *)",
            "Bash(kitterm stop)",
            "Bash(kitterm stop *)",
            "Bash(kitterm restart)",
            "Bash(kitterm restart *)",
            "Edit(//**/.github/workflows/**)",
            "Edit(//**/docs/goals/*/goal.md)",
            "Edit(//**/docs/goals/*/corpus/**)",
        ])
        XCTAssertEqual(settings.keys.sorted(), ["hooks", "permissions"])
    }

    /// One `PreToolUse` hook on `Bash`. `|| exit 2` blocks the call when the
    /// guard cannot run (no `kitterm` on the PATH, or a build without
    /// `round guard`); Claude Code lets the call run on any other failing
    /// exit code.
    func testTheGuardHook() throws {
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(ForemanSkills.crewSettings.utf8)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks.keys.sorted(), ["PreToolUse"])
        let entry = try XCTUnwrap(hooks["PreToolUse"]?.first)
        XCTAssertEqual(hooks["PreToolUse"]?.count, 1)
        XCTAssertEqual(entry["matcher"] as? String, "Bash")
        let commands = try XCTUnwrap(entry["hooks"] as? [[String: String]])
        XCTAssertEqual(commands, [["type": "command", "command": "kitterm round guard || exit 2"]])
    }

    /// The skill starts each crew with the file `skills install` writes.
    func testTheSkillStartsTheCrewWithTheFile() {
        XCTAssertTrue(ForemanSkills.foremanLoop.contains(
            "claude --model <id> --settings ~/.claude/skills/foreman-loop/crew-settings.json"
        ))
        XCTAssertTrue(ForemanSkills.foremanLoop.contains("kitterm round guard --check"))
    }
}
