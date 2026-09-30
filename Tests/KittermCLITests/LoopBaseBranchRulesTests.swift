import Foundation
import XCTest

@testable import KittermCLI

/// The generic template and the foreman skill serve every registered
/// project, and other projects on this machine use `develop` or `dev` as
/// their base branch. Neither copy may hardcode `main` as the branch to cut
/// from, push to, or rebase onto (`base-branch` chore). `docs/goals/LOOP.md`
/// is kitterm's own copy, whose base branch is `main`, and is allowed to.
final class LoopBaseBranchRulesTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func genericFiles() throws -> [(name: String, text: String)] {
        [
            ("examples/goals/LOOP.md", try read("examples/goals/LOOP.md")),
            ("GoalsTemplates.loop", GoalsTemplates.loop),
            ("examples/foreman/foreman-loop.md", try read("examples/foreman/foreman-loop.md")),
            ("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop),
        ]
    }

    func testNoGenericCopyHardcodesMainAsTheBaseBranch() throws {
        for (name, text) in try Self.genericFiles() {
            XCTAssertFalse(text.contains("origin/main"), "\(name) names `origin/main`; cut from `origin/<base>` instead")
            XCTAssertFalse(text.contains("`main`"), "\(name) names `main` as a rule; name the base branch instead")
        }
    }

    /// `docs/goals/LOOP.md` is kitterm's own copy: its base branch is `main`,
    /// so it names it, unlike the generic files above.
    func testKittermsOwnCopyStillNamesMain() throws {
        let text = try Self.read("docs/goals/LOOP.md")
        XCTAssertTrue(text.contains("origin/main"), "docs/goals/LOOP.md cuts branches from origin/main")
        XCTAssertTrue(text.contains("`main`"), "docs/goals/LOOP.md never pushes to main")
    }
}
