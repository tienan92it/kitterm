import Foundation
import KittermDaemon
import XCTest

@testable import KittermCLI

/// `kitterm project add|init|list|remove` against a scratch state directory
/// and a scratch project path.
final class ProjectCommandTests: XCTestCase {
    private var stateDir: URL!
    private var work: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-project-cli-\(UUID().uuidString)")
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

    private func files(under url: URL) throws -> [String: Data] {
        try CLIFixture.files(under: url)
    }

    // MARK: - add, list, remove

    func testAddListRemove() throws {
        let path = try dir("My App")
        let expectedRoot = ProjectStore.canonicalRoot(path)

        let added = try run(["add", path])
        XCTAssertEqual(added, ["my-app\tMy App\t\(expectedRoot)\tdocs/goals"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: DaemonPaths.projectsFile.path))
        XCTAssertEqual(
            ProjectStore.load(),
            [Project(id: "my-app", name: "My App", root: expectedRoot, knowledge: "docs/goals")]
        )

        XCTAssertEqual(try run(["list"]), ["my-app\tMy App\t\(expectedRoot)\tdocs/goals"])

        XCTAssertEqual(try run(["remove", "my-app"]), ["removed my-app"])
        XCTAssertEqual(ProjectStore.load(), [])
        XCTAssertEqual(try run(["list"]).count, 1, "an empty list explains how to add one")
    }

    func testNameAndKnowledgeOptions() throws {
        let path = try dir("repo")
        try run(["add", path, "--name", "Kitterm", "--knowledge", "notes/goals"])
        let project = try XCTUnwrap(ProjectStore.load().first)
        XCTAssertEqual(project.id, "repo")
        XCTAssertEqual(project.name, "Kitterm")
        XCTAssertEqual(project.knowledge, "notes/goals")

        let other = try dir("other")
        try run(["add", other, "--name=Other", "--knowledge=docs"])
        XCTAssertEqual(ProjectStore.load().last?.name, "Other")
        XCTAssertEqual(ProjectStore.load().last?.knowledge, "docs")
    }

    /// The id is unique: a second folder of the same name gets `-2`.
    func testSameFolderNameGetsASuffixedID() throws {
        let first = try dir("one/app")
        let second = try dir("two/app")
        try run(["add", first])
        try run(["add", second])
        XCTAssertEqual(ProjectStore.load().map(\.id), ["app", "app-2"])
    }

    func testRefusals() throws {
        let path = try dir("repo")
        try run(["add", path])
        XCTAssertThrowsError(try run(["add", path]), "a registered root is refused")
        XCTAssertThrowsError(try run(["add", stateDir.path + "/no/such/dir"]))
        XCTAssertThrowsError(try run(["add", try dir("x"), "--knowledge", "../escape"]))
        XCTAssertThrowsError(try run(["add", try dir("y"), "--knowledge", "/abs"]))
        XCTAssertThrowsError(try run(["add", try dir("z"), "--bogus"]))
        XCTAssertThrowsError(try run(["remove", "nope"]))
        XCTAssertThrowsError(try run(["remove"]))
        XCTAssertThrowsError(try run(["frobnicate"]))
        XCTAssertThrowsError(try run([]))
        XCTAssertEqual(ProjectStore.load().map(\.id), ["repo"], "a refused command changes nothing")
    }

    /// The file and a fresh state directory are owner-only, like the tokens
    /// beside them.
    func testProjectsFileAndFreshStateDirectoryAreOwnerOnly() throws {
        let fresh = stateDir.appendingPathComponent("fresh")
        setenv("KITTERM_STATE_DIR", fresh.path, 1)
        try run(["add", try dir("repo")])
        func mode(_ path: String) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        }
        XCTAssertEqual(try mode(fresh.path), 0o700)
        XCTAssertEqual(try mode(DaemonPaths.projectsFile.path), 0o600)
    }

    /// A relative path resolves against the working directory.
    func testRelativePathResolvesAgainstCwd() throws {
        let path = try dir("rel")
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(work.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        try run(["add", "rel"])
        XCTAssertEqual(ProjectStore.load().first?.root, ProjectStore.canonicalRoot(path))
    }

    // MARK: - init

    /// The two project files land in `docs/goals`, each equal to its
    /// template, no goal folder beside them, and the project is registered
    /// as `add` would register it.
    func testInitWritesThePackageAndRegisters() throws {
        let project = try dir("My App")
        let expectedRoot = ProjectStore.canonicalRoot(project)

        let lines = try run(["init", project])
        XCTAssertEqual(
            lines,
            ["wrote docs/goals/LOOP.md", "wrote docs/goals/facts.md", "my-app\tMy App\t\(expectedRoot)\tdocs/goals"]
        )

        let written = try files(under: URL(fileURLWithPath: project).appendingPathComponent("docs/goals"))
        XCTAssertEqual(Set(written.keys), Set(GoalsTemplates.project.map(\.path)))
        for (path, contents) in GoalsTemplates.project {
            XCTAssertEqual(written[path], Data(contents.utf8), path)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: project + "/docs/goals").sorted(),
            ["LOOP.md", "facts.md"], "no goal folder: that is `kitterm goal new`"
        )
        XCTAssertEqual(
            ProjectStore.load(),
            [Project(id: "my-app", name: "My App", root: expectedRoot, knowledge: "docs/goals")]
        )
    }

    func testInitNameAndKnowledgeOptions() throws {
        let project = try dir("repo")
        try run(["init", project, "--name", "Kitterm", "--knowledge", "notes/goals"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project + "/notes/goals/LOOP.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/docs"))
        let registered = try XCTUnwrap(ProjectStore.load().first)
        XCTAssertEqual(registered.name, "Kitterm")
        XCTAssertEqual(registered.knowledge, "notes/goals")

        let other = try dir("other")
        try run(["init", other, "--name=Other", "--knowledge=docs"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other + "/docs/facts.md"))
        XCTAssertEqual(ProjectStore.load().last?.knowledge, "docs")
    }

    /// A file that exists is never overwritten: the command names it, writes
    /// nothing, and registers nothing. A goal folder beside it is not a
    /// project file and is left alone.
    func testInitRefusesToOverwriteAndWritesNothing() throws {
        let project = try dir("repo")
        let goals = URL(fileURLWithPath: project).appendingPathComponent("docs/goals", isDirectory: true)
        try FileManager.default.createDirectory(at: goals.appendingPathComponent("demo"), withIntermediateDirectories: true)
        let mine = Data("# mine\n".utf8)
        try mine.write(to: goals.appendingPathComponent("LOOP.md"))
        try mine.write(to: goals.appendingPathComponent("demo/STATE.md"))

        XCTAssertThrowsError(try run(["init", project])) { error in
            let message = String(describing: (error as? CLIError)?.errorDescription ?? "")
            XCTAssertTrue(message.contains("docs/goals/LOOP.md"), message)
            XCTAssertFalse(message.contains("facts.md"), "only the files that exist are named: \(message)")
        }
        XCTAssertEqual(try files(under: goals), ["LOOP.md": mine, "demo/STATE.md": mine])
        XCTAssertEqual(ProjectStore.load(), [], "a refused init registers nothing")
    }

    /// A root that is already registered is refused before any file is written.
    func testInitRefusesARegisteredRoot() throws {
        let project = try dir("repo")
        try run(["add", project])
        XCTAssertThrowsError(try run(["init", project]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/docs"))
        XCTAssertEqual(ProjectStore.load().count, 1)
    }

    /// A symlink at the knowledge directory, at a parent of it, or at a
    /// template path is refused before anything is written, so a checked-in
    /// link cannot take the package outside the repository.
    func testInitRefusesASymlinkOnTheTemplatePath() throws {
        let outside = try dir("outside")
        let project = try dir("linked")
        try FileManager.default.createDirectory(atPath: project + "/docs", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/docs/goals", withDestinationPath: outside)
        XCTAssertThrowsError(try run(["init", project])) { error in
            let message = String(describing: (error as? CLIError)?.errorDescription ?? "")
            XCTAssertTrue(message.contains("docs/goals is a symlink"), message)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside), [], "nothing crossed the link")

        // A dangling link at one template path: `stat` says absent, `lstat`
        // says link, and the link wins.
        let dangling = try dir("dangling")
        try FileManager.default.createDirectory(atPath: dangling + "/docs/goals", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: dangling + "/docs/goals/LOOP.md", withDestinationPath: outside + "/LOOP.md"
        )
        XCTAssertThrowsError(try run(["init", dangling]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/LOOP.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dangling + "/docs/goals/facts.md"), "nothing written")
        XCTAssertEqual(ProjectStore.load(), [])
    }

    // MARK: - init --refresh

    /// A scratch package: a `LOOP.md` with the given bytes, a `facts.md`
    /// and a goal folder beside it, none of which `--refresh` may touch.
    private func package(_ name: String, loop: Data) throws -> (project: String, goals: URL) {
        let project = try dir(name)
        let goals = URL(fileURLWithPath: project).appendingPathComponent("docs/goals", isDirectory: true)
        try FileManager.default.createDirectory(at: goals.appendingPathComponent("demo"), withIntermediateDirectories: true)
        try loop.write(to: goals.appendingPathComponent("LOOP.md"))
        try Data("# facts\n\n- mine\n".utf8).write(to: goals.appendingPathComponent("facts.md"))
        try Data("# STATE: demo\n".utf8).write(to: goals.appendingPathComponent("demo/STATE.md"))
        return (project, goals)
    }

    private func message(_ error: Error) -> String {
        String(describing: (error as? CLIError)?.errorDescription ?? "")
    }

    /// A file that is an earlier version of the template is rewritten to
    /// the current one, and the line names both hashes; `facts.md` and the
    /// goal folder keep their bytes, and nothing is registered.
    func testRefreshRewritesAnOlderTemplateAndLeavesTheRestUntouched() throws {
        let older = Data("# LOOP\n\nan earlier version of the template\n".utf8)
        let (project, goals) = try package("repo", loop: older)
        let before = try files(under: goals)
        let history = GoalsTemplates.loopHistory + [TokenStore.hash(String(decoding: older, as: UTF8.self))]

        var lines: [String] = []
        try ProjectCommand.refreshLoop(under: "docs/goals", root: project, history: history) { lines.append($0) }

        let now = TokenStore.hash(GoalsTemplates.loop).prefix(7)
        let was = history.last!.prefix(7)
        XCTAssertEqual(lines, ["rewrote \(project)/docs/goals/LOOP.md from template \(now) (was \(was))"])
        var after = try files(under: goals)
        XCTAssertEqual(after.removeValue(forKey: "LOOP.md"), Data(GoalsTemplates.loop.utf8))
        XCTAssertEqual(after, before.filter { $0.key != "LOOP.md" }, "facts.md and the goal folder are untouched")
        XCTAssertEqual(ProjectStore.load(), [], "a refresh registers nothing")
    }

    /// The shipped history rewrites a `LOOP.md` that `init` of an earlier
    /// release wrote: the file at the commit before the current template,
    /// read from git, so the seeded hashes are the right ones.
    func testRefreshRewritesTheTemplateOfThePreviousRelease() throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "-C", CLIFixture.repositoryRoot.path, "show", "41b6a76:examples/goals/LOOP.md"]
        let pipe = Pipe()
        git.standardOutput = pipe
        git.standardError = FileHandle.nullDevice
        try git.run()
        let previous = pipe.fileHandleForReading.readDataToEndOfFile()
        waitForExit(of: git, output: "\(previous.count) bytes")
        guard git.terminationStatus == 0, !previous.isEmpty else {
            throw XCTSkip("git history for examples/goals/LOOP.md is not available here")
        }
        XCTAssertNotEqual(previous, Data(GoalsTemplates.loop.utf8), "the previous version differs from the current")

        let (project, goals) = try package("repo", loop: previous)
        let lines = try run(["init", project, "--refresh"])
        XCTAssertEqual(lines.count, 1)
        let root = ProjectStore.canonicalRoot(project)
        XCTAssertTrue(lines[0].hasPrefix("rewrote \(root)/docs/goals/LOOP.md from template "), lines[0])
        XCTAssertEqual(try Data(contentsOf: goals.appendingPathComponent("LOOP.md")), Data(GoalsTemplates.loop.utf8))
        XCTAssertEqual(ProjectStore.load(), [])
    }

    /// A file that matches no shipped version was edited by hand: refused,
    /// and every byte under the package stays.
    func testRefreshRefusesAHandEditedFile() throws {
        let edited = Data((GoalsTemplates.loop + "\n## My rule\n").utf8)
        let (project, goals) = try package("repo", loop: edited)
        let before = try files(under: goals)
        XCTAssertThrowsError(try run(["init", project, "--refresh"])) { error in
            XCTAssertEqual(message(error), "LOOP.md was edited by hand (nothing written)")
        }
        XCTAssertEqual(try files(under: goals), before)
        XCTAssertEqual(ProjectStore.load(), [])
    }

    /// A file equal to the template is refused with its own reason.
    func testRefreshRefusesACurrentFile() throws {
        let (project, goals) = try package("repo", loop: Data(GoalsTemplates.loop.utf8))
        let before = try files(under: goals)
        XCTAssertThrowsError(try run(["init", project, "--refresh"])) { error in
            XCTAssertEqual(message(error), "LOOP.md is current (nothing written)")
        }
        XCTAssertEqual(try files(under: goals), before)
    }

    /// A symlink at `LOOP.md` or at the knowledge directory is refused as
    /// `init` refuses it, before the file is read.
    func testRefreshRefusesASymlink() throws {
        let outside = try dir("outside")
        try Data(GoalsTemplates.loop.utf8).write(to: URL(fileURLWithPath: outside + "/LOOP.md"))
        let project = try dir("linked")
        try FileManager.default.createDirectory(atPath: project + "/docs/goals", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: project + "/docs/goals/LOOP.md", withDestinationPath: outside + "/LOOP.md"
        )
        XCTAssertThrowsError(try run(["init", project, "--refresh"])) { error in
            XCTAssertTrue(message(error).contains("docs/goals/LOOP.md is a symlink"), message(error))
        }

        let dirLinked = try dir("dir-linked")
        try FileManager.default.createDirectory(atPath: dirLinked + "/docs", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dirLinked + "/docs/goals", withDestinationPath: outside)
        XCTAssertThrowsError(try run(["init", dirLinked, "--refresh"])) { error in
            XCTAssertTrue(message(error).contains("docs/goals is a symlink"), message(error))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outside + "/LOOP.md")), Data(GoalsTemplates.loop.utf8))
    }

    /// No file to refresh, `--name` beside `--refresh`, and `add --refresh`
    /// are usage errors; without `--refresh`, an existing file is refused
    /// as before.
    func testRefreshUsageRefusalsAndInitWithoutTheFlagIsUnchanged() throws {
        let empty = try dir("empty")
        XCTAssertThrowsError(try run(["init", empty, "--refresh"])) { error in
            XCTAssertEqual(message(error), "no docs/goals/LOOP.md to refresh (nothing written)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty + "/docs"))

        let older = Data("# LOOP\n\nolder\n".utf8)
        let (project, goals) = try package("repo", loop: older)
        XCTAssertThrowsError(try run(["init", project, "--refresh", "--name", "X"]))
        XCTAssertThrowsError(try run(["add", project, "--refresh"]))
        XCTAssertThrowsError(try run(["init", project])) { error in
            XCTAssertEqual(
                message(error), "refusing to overwrite: docs/goals/LOOP.md, docs/goals/facts.md (nothing written)"
            )
        }
        XCTAssertEqual(try files(under: goals)["LOOP.md"], older)
        XCTAssertEqual(ProjectStore.load(), [])
    }

    func testInitUsageRefusals() throws {
        XCTAssertThrowsError(try run(["init"]))
        XCTAssertThrowsError(try run(["init", stateDir.path + "/no/such/dir"]))
        XCTAssertThrowsError(try run(["init", try dir("x"), "--knowledge", "../escape"]))
        XCTAssertThrowsError(try run(["init", try dir("y"), "--bogus"]))
        XCTAssertEqual(ProjectStore.load(), [])
    }
}
