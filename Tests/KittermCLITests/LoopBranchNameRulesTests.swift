import Foundation
import XCTest

@testable import KittermCLI

/// A goal's branch is `goal/<slug>`, a chore's is `chore/<slug>`: one typed
/// prefix per kind of work (chore `goal-branch-name`, the human's word,
/// 2026-10-02). After the human merges, the foreman deletes the branch on
/// the remote, its worktree, and the local branch. Every copy of the loop,
/// the skill, the manual and `AGENTS.md` names the branch the same way, and
/// none keeps the retired `<slug>/rounds`.
final class LoopBranchNameRulesTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    static let retiredName = "`<slug>/rounds`"

    static let loopDeleteRule = """
        When the human merges a pull request, the foreman deletes its branch
        with `git push origin --delete <branch>`, then removes the worktree with
        `git worktree remove` and the local branch with `git branch -D`. A
        merged branch left on the remote reads as open work.
        """

    static let skillDeleteRule = """
        A merge of a goal's or a chore's pull request: delete its branch with
        `git push origin --delete <branch>`, then remove the worktree with
        `git worktree remove` and the local branch with `git branch -D`. A
        merged branch left on the remote reads as open work.
        """

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

    func testEveryCopyNamesTheGoalBranchWithItsPrefix() throws {
        let copies = try Self.loopFiles() + Self.skillFiles() + [
            ("docs/foreman.md", try Self.read("docs/foreman.md")),
            ("AGENTS.md", try Self.read("AGENTS.md")),
        ]
        for (name, text) in copies {
            XCTAssertTrue(text.contains("`goal/<slug>`"), "\(name) names the goal branch `goal/<slug>`")
            XCTAssertFalse(text.contains(Self.retiredName), "\(name) still names the retired \(Self.retiredName)")
        }
    }

    func testTheLoopFilesDeleteAMergedBranch() throws {
        for (name, text) in try Self.loopFiles() {
            XCTAssertTrue(Self.oneLine(text).contains(Self.oneLine(Self.loopDeleteRule)), "\(name) carries the delete rule")
        }
    }

    func testTheSkillDeletesAMergedBranch() throws {
        for (name, text) in try Self.skillFiles() {
            XCTAssertTrue(Self.oneLine(text).contains(Self.oneLine(Self.skillDeleteRule)), "\(name) carries the delete step")
        }
    }

    func testTheManualDeletesAMergedBranch() throws {
        let manual = Self.oneLine(try Self.read("docs/foreman.md"))
        let sentence = "After the merge, the foreman deletes the branch on the remote, its worktree, and the local branch."
        XCTAssertTrue(manual.contains(Self.oneLine(sentence)), "docs/foreman.md names the delete step")
    }
}
