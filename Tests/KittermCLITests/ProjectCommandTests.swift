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
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: url.path))
        var result: [String: Data] = [:]
        for case let relative as String in enumerator {
            let full = url.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                result[relative] = try Data(contentsOf: full)
            }
        }
        return result
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

    /// The package lands in `docs/goals`, each file equal to its template,
    /// and the project is registered as `add` would register it.
    func testInitWritesThePackageAndRegisters() throws {
        let project = try dir("My App")
        let expectedRoot = ProjectStore.canonicalRoot(project)

        let lines = try run(["init", project])
        XCTAssertEqual(
            lines,
            GoalsTemplates.files.map { "wrote docs/goals/\($0.path)" }
                + ["my-app\tMy App\t\(expectedRoot)\tdocs/goals"]
        )

        let written = try files(under: URL(fileURLWithPath: project).appendingPathComponent("docs/goals"))
        XCTAssertEqual(Set(written.keys), Set(GoalsTemplates.files.map(\.path)))
        for (path, contents) in GoalsTemplates.files {
            XCTAssertEqual(written[path], Data(contents.utf8), path)
        }
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: other + "/docs/STATE.md"))
        XCTAssertEqual(ProjectStore.load().last?.knowledge, "docs")
    }

    /// A file that exists is never overwritten: the command names it, writes
    /// nothing, and registers nothing.
    func testInitRefusesToOverwriteAndWritesNothing() throws {
        let project = try dir("repo")
        let goals = URL(fileURLWithPath: project).appendingPathComponent("docs/goals", isDirectory: true)
        try FileManager.default.createDirectory(at: goals, withIntermediateDirectories: true)
        let mine = Data("# mine\n".utf8)
        try mine.write(to: goals.appendingPathComponent("goal.md"))
        try mine.write(to: goals.appendingPathComponent("STATE.md"))

        XCTAssertThrowsError(try run(["init", project])) { error in
            let message = String(describing: (error as? CLIError)?.errorDescription ?? "")
            XCTAssertTrue(message.contains("docs/goals/goal.md"), message)
            XCTAssertTrue(message.contains("docs/goals/STATE.md"), message)
            XCTAssertFalse(message.contains("plan.md"), "only the files that exist are named: \(message)")
        }
        XCTAssertEqual(try files(under: goals), ["goal.md": mine, "STATE.md": mine])
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
            atPath: dangling + "/docs/goals/goal.md", withDestinationPath: outside + "/goal.md"
        )
        XCTAssertThrowsError(try run(["init", dangling]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/goal.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dangling + "/docs/goals/STATE.md"), "nothing written")
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
