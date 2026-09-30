import Foundation
import XCTest

@testable import KittermCLI
@testable import KittermDaemon

/// One file per chore (`foreman-flow` round 4, completion condition 5):
/// a chore's line lives in `docs/goals/chores/<ISO date>-<slug>.md`, so
/// two chore pull requests cut from one base merge in either order with
/// no conflict, where the shared tail of `CHORES.md` conflicted on every
/// second chore. The folder holds no `STATE.md`, so the daemon's goal
/// listing and `kitterm goal list` skip it. The five texts that describe
/// the loop name the path.
final class ChoreFilesMergeTests: XCTestCase {
    private var work: URL!
    private var repo: String!

    override func setUpWithError() throws {
        work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-chore-files-\(UUID().uuidString)", isDirectory: true)
        repo = work.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Fixture

    @discardableResult
    private func git(_ arguments: String..., expectSuccess: Bool = true) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repo] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.test",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.test",
        ]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        waitForExit(of: process, output: output)
        if expectSuccess {
            XCTAssertEqual(process.terminationStatus, 0, "git \(arguments): \(output)")
        }
        return (process.terminationStatus, output)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: "\(repo!)/\(path)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The base: a package with one goal folder and the pointer `CHORES.md`.
    private func writeBase() throws {
        try git("init", "-q", "-b", "main")
        try write("docs/goals/LOOP.md", "# LOOP\n")
        try write("docs/goals/CHORES.md", "# Chores\n\nNew chores go under `chores/`.\n\n- 2026-09-21 · old · PR #140\n")
        try write("docs/goals/example/STATE.md", "# STATE: example\n\n- Status: done\n")
        try git("add", ".")
        try git("commit", "-q", "-m", "base")
    }

    /// A chore branch from `main` that adds its one file and nothing else.
    private func chore(_ slug: String, day: String, pr: Int) throws {
        try git("checkout", "-q", "-b", "chore/\(slug)", "main")
        try write(
            "docs/goals/chores/\(day)-\(slug).md",
            "- \(day) · \(slug), one sentence · PR #\(pr) · Cost: $1.00 · 100k in (90% cached) · 1k out · 0h 01m\n"
        )
        try git("add", ".")
        try git("commit", "-q", "-m", slug)
        try git("checkout", "-q", "main")
    }

    // MARK: - Two chores, either order

    func testTwoChoreBranchesFromOneBaseMergeInEitherOrder() throws {
        try writeBase()
        try chore("fix-the-widget", day: "2026-09-30", pr: 201)
        try chore("bump-the-dep", day: "2026-09-30", pr: 202)

        for order in [["fix-the-widget", "bump-the-dep"], ["bump-the-dep", "fix-the-widget"]] {
            try git("checkout", "-q", "-b", "trial-\(order[0])", "main")
            for slug in order {
                let merge = try git("merge", "-q", "--no-edit", "chore/\(slug)", expectSuccess: false)
                XCTAssertEqual(merge.status, 0, "merging chore/\(slug) after \(order): \(merge.output)")
                XCTAssertFalse(merge.output.contains("CONFLICT"), merge.output)
            }
            let files = try git("ls-files", "docs/goals/chores").output.split(separator: "\n").map(String.init)
            XCTAssertEqual(
                files,
                ["docs/goals/chores/2026-09-30-bump-the-dep.md", "docs/goals/chores/2026-09-30-fix-the-widget.md"],
                "both chore files after \(order)"
            )
            let chores = try String(contentsOfFile: "\(repo!)/docs/goals/CHORES.md", encoding: .utf8)
            XCTAssertEqual(chores.components(separatedBy: "\n- ").count - 1, 1, "CHORES.md gains no line")
            try git("checkout", "-q", "main")
        }
    }

    /// `git merge-tree` is the check `plan.md` names: it reports the
    /// conflict without touching the index, the way the foreman can ask
    /// before it rebases.
    func testMergeTreeReportsNoConflictBetweenTwoChores() throws {
        try writeBase()
        try chore("fix-the-widget", day: "2026-09-30", pr: 201)
        try chore("bump-the-dep", day: "2026-09-30", pr: 202)
        let tree = try git("merge-tree", "--write-tree", "chore/fix-the-widget", "chore/bump-the-dep", expectSuccess: false)
        XCTAssertEqual(tree.status, 0, tree.output)
        XCTAssertFalse(tree.output.contains("CONFLICT"), tree.output)
    }

    // MARK: - The folder is not a goal

    func testTheChoresFolderIsNotAGoalFolder() throws {
        try writeBase()
        try chore("fix-the-widget", day: "2026-09-30", pr: 201)
        try git("merge", "-q", "--no-edit", "chore/fix-the-widget")
        let goals = try XCTUnwrap(KnowledgeFile.summaries(root: repo, knowledge: "docs/goals"))
        XCTAssertEqual(goals.map(\.slug), ["example"], "`chores/` holds no STATE.md, so it is no goal")

        var lines: [String] = []
        try GoalCommand.run(["list", repo]) { lines.append($0) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("example"), lines[0])
    }

    // MARK: - The texts name the path

    func testTheLoopTextsNameTheChoreFile() throws {
        let root = CLIFixture.repositoryRoot
        let named: [(path: String, text: String, needle: String)] = [
            ("docs/goals/LOOP.md", try text(root, "docs/goals/LOOP.md"), "`docs/goals/chores/<ISO date>-<slug>.md`"),
            ("examples/goals/LOOP.md", try text(root, "examples/goals/LOOP.md"), "`<knowledge directory>/chores/<ISO date>-<slug>.md`"),
            ("GoalsTemplates.loop", GoalsTemplates.loop, "`<knowledge directory>/chores/<ISO date>-<slug>.md`"),
            ("examples/foreman/foreman-loop.md", try text(root, "examples/foreman/foreman-loop.md"), "`docs/goals/chores/<ISO date>-<slug>.md`"),
            ("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop, "`docs/goals/chores/<ISO date>-<slug>.md`"),
            ("docs/foreman.md", try text(root, "docs/foreman.md"), "`docs/goals/chores/<ISO date>-<slug>.md`"),
            ("docs/goals/CHORES.md", try text(root, "docs/goals/CHORES.md"), "`docs/goals/chores/<ISO date>-<slug>.md`"),
        ]
        for file in named {
            XCTAssertTrue(file.text.contains(file.needle), "\(file.path) names the chore file")
        }
        // The command that writes the line, in the contract and the procedure.
        for file in named where file.path != "docs/goals/CHORES.md" {
            XCTAssertTrue(file.text.contains("kitterm archive cost <id> --line"), "\(file.path) names the command")
        }
        // Nothing sends a new chore line to the shared list.
        for file in named where file.path != "docs/goals/CHORES.md" {
            XCTAssertFalse(file.text.contains("one line in `docs/goals/CHORES.md`"), "\(file.path) still appends to CHORES.md")
        }
    }

    private func text(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
