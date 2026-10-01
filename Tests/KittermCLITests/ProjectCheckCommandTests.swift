import Foundation
import KittermDaemon
import XCTest

@testable import KittermCLI

/// `kitterm project init --refresh --check <root>` — capability 1 of
/// `foreman-scope`. It must answer `current`, `behind`, or `edited` and
/// write nothing, using the same comparison `refreshLoop` uses
/// (`GoalsTemplates.loopState`), so a `--check` answer can never disagree
/// with what a plain `--refresh` would have done.
final class ProjectCheckCommandTests: XCTestCase {
    private var stateDir: URL!
    private var work: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-project-check-cli-\(UUID().uuidString)")
        work = stateDir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func dir(_ name: String) throws -> String {
        let url = work.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @discardableResult
    private func run(_ args: [String]) throws -> [String] {
        var lines: [String] = []
        try ProjectCommand.run(args) { lines.append($0) }
        return lines
    }

    private func message(_ error: Error) -> String {
        String(describing: (error as? CLIError)?.errorDescription ?? "")
    }

    /// A project folder with `<knowledge>/LOOP.md` holding `loop`, and a
    /// `facts.md` and goal folder beside it that no `--check` may touch.
    private func package(_ name: String, knowledge: String = "docs/goals", loop: Data) throws -> (
        project: String, knowledgeDir: URL
    ) {
        let project = try dir(name)
        let knowledgeDir = URL(fileURLWithPath: project).appendingPathComponent(knowledge, isDirectory: true)
        try FileManager.default.createDirectory(
            at: knowledgeDir.appendingPathComponent("demo"), withIntermediateDirectories: true
        )
        try loop.write(to: knowledgeDir.appendingPathComponent("LOOP.md"))
        try Data("# facts\n\n- mine\n".utf8).write(to: knowledgeDir.appendingPathComponent("facts.md"))
        try Data("# STATE: demo\n".utf8).write(to: knowledgeDir.appendingPathComponent("demo/STATE.md"))
        return (project, knowledgeDir)
    }

    // MARK: - current

    func testCheckReportsCurrentAndWritesNothing() throws {
        let (project, knowledgeDir) = try package("repo", loop: Data(GoalsTemplates.loop.utf8))
        let before = try CLIFixture.files(under: knowledgeDir)
        let root = ProjectStore.canonicalRoot(project)

        XCTAssertEqual(try run(["init", project, "--refresh", "--check"]), ["\(root): current"])

        XCTAssertEqual(try CLIFixture.files(under: knowledgeDir), before, "--check changes no byte")
        XCTAssertEqual(ProjectStore.load(), [], "a check registers nothing")
    }

    // MARK: - behind

    /// A fixture for an older shipped template cannot be built by hashing
    /// forward (SHA-256 has no known preimage), so this reproduces the
    /// frozen `ProjectCommandTests.testRefreshRewritesAnOlderTemplateAndLeavesTheRestUntouched`
    /// technique instead: write an arbitrary "older" text, then pass
    /// `checkLoop` a `history` that is the real `loopHistory` plus that
    /// text's own hash — exactly the shape `loopHistory` has (one entry per
    /// shipped version), so the comparison `--check` runs in production is
    /// exercised unchanged.
    func testCheckReportsBehindAndWritesNothing() throws {
        let older = Data("# LOOP\n\nan earlier version of the template\n".utf8)
        let (project, knowledgeDir) = try package("repo", loop: older)
        let before = try CLIFixture.files(under: knowledgeDir)
        let history = GoalsTemplates.loopHistory + [TokenStore.hash(String(decoding: older, as: UTF8.self))]
        let root = ProjectStore.canonicalRoot(project)

        var lines: [String] = []
        try ProjectCommand.checkLoop(root: root, under: "docs/goals", history: history) { lines.append($0) }

        XCTAssertEqual(lines, ["\(root): behind"])
        XCTAssertEqual(try CLIFixture.files(under: knowledgeDir), before, "--check changes no byte")
        XCTAssertEqual(ProjectStore.load(), [])
    }

    // MARK: - edited

    func testCheckReportsEditedAndWritesNothing() throws {
        let edited = Data((GoalsTemplates.loop + "\n## My rule\n").utf8)
        let (project, knowledgeDir) = try package("repo", loop: edited)
        let before = try CLIFixture.files(under: knowledgeDir)
        let root = ProjectStore.canonicalRoot(project)

        XCTAssertEqual(try run(["init", project, "--refresh", "--check"]), ["\(root): edited"])

        XCTAssertEqual(try CLIFixture.files(under: knowledgeDir), before, "--check changes no byte")
        XCTAssertEqual(ProjectStore.load(), [])
    }

    // MARK: - missing and symlink

    func testCheckExitsOneForAMissingLOOPFile() throws {
        let empty = try dir("empty")
        let root = ProjectStore.canonicalRoot(empty)
        XCTAssertThrowsError(try run(["init", empty, "--refresh", "--check"])) { error in
            XCTAssertEqual(message(error), "no \(root)/docs/goals/LOOP.md to check (nothing written)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty + "/docs"), "nothing written")
        XCTAssertEqual(ProjectStore.load(), [])
    }

    /// The message names the absolute path of the file the check looked
    /// for, under the registered project's own knowledge directory, so a
    /// foreman that checks several projects reads which file is missing.
    func testCheckNamesTheAbsolutePathOfAMissingLOOPFile() throws {
        let project = try dir("repo")
        try run(["add", project, "--knowledge", "goals-pkg"])
        let root = ProjectStore.canonicalRoot(project)

        XCTAssertThrowsError(try run(["init", project, "--refresh", "--check"])) { error in
            XCTAssertEqual(message(error), "no \(root)/goals-pkg/LOOP.md to check (nothing written)")
            XCTAssertTrue(message(error).hasPrefix("no /"), "an absolute path: \(message(error))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/goals-pkg"), "nothing written")
    }

    func testCheckExitsOneForASymlinkedLOOPFile() throws {
        let outside = try dir("outside")
        try Data(GoalsTemplates.loop.utf8).write(to: URL(fileURLWithPath: outside + "/LOOP.md"))
        let project = try dir("linked")
        try FileManager.default.createDirectory(atPath: project + "/docs/goals", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: project + "/docs/goals/LOOP.md", withDestinationPath: outside + "/LOOP.md"
        )

        XCTAssertThrowsError(try run(["init", project, "--refresh", "--check"])) { error in
            XCTAssertTrue(message(error).contains("docs/goals/LOOP.md is a symlink"), message(error))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outside + "/LOOP.md")), Data(GoalsTemplates.loop.utf8))
    }

    func testCheckExitsOneForARootThatIsNotADirectory() throws {
        XCTAssertThrowsError(try run(["init", stateDir.path + "/no/such/dir", "--refresh", "--check"]))
    }

    // MARK: - usage

    func testCheckWithoutRefreshIsAUsageError() throws {
        let project = try dir("repo")
        XCTAssertThrowsError(try run(["init", project, "--check"])) { error in
            XCTAssertTrue(message(error).hasPrefix("--check needs --refresh"), message(error))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/docs"), "nothing written")
        XCTAssertEqual(ProjectStore.load(), [])
    }

    func testAddWithCheckIsAUsageError() throws {
        let project = try dir("repo")
        XCTAssertThrowsError(try run(["add", project, "--refresh", "--check"]))
        XCTAssertThrowsError(try run(["add", project, "--check"]))
        XCTAssertEqual(ProjectStore.load(), [])
    }

    // MARK: - knowledge directory

    /// `--check` reads the project's own `knowledge` once it is registered,
    /// not the `docs/goals` default: a `LOOP.md` under the registered
    /// directory reports `current` even though no `docs/goals` exists.
    func testCheckUsesTheRegisteredProjectsOwnKnowledgeDirectory() throws {
        let (project, knowledgeDir) = try package("repo", knowledge: "goals-pkg", loop: Data(GoalsTemplates.loop.utf8))
        try run(["add", project, "--knowledge", "goals-pkg"])
        let root = ProjectStore.canonicalRoot(project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/docs/goals"))

        XCTAssertEqual(try run(["init", project, "--refresh", "--check"]), ["\(root): current"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: knowledgeDir.appendingPathComponent("LOOP.md").path))
    }

    /// An unregistered root falls back to `docs/goals`, even when a
    /// `--knowledge` option is given — `--check` does not take one.
    func testCheckFallsBackToDocsGoalsForAnUnregisteredProject() throws {
        let (project, _) = try package("repo", loop: Data(GoalsTemplates.loop.utf8))
        let root = ProjectStore.canonicalRoot(project)
        XCTAssertEqual(try run(["init", project, "--refresh", "--check"]), ["\(root): current"])
    }
}
