import Foundation
import KittermDaemon
import XCTest

@testable import KittermCLI

/// `kitterm project init` against a scratch state directory and a scratch
/// project path.
final class ProjectInitTests: XCTestCase {
    private var stateDir: URL!
    private var work: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-project-init-\(UUID().uuidString)")
        work = stateDir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func dir(_ name: String) throws -> URL {
        let url = work.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    /// The package lands in `docs/goals`, each file equal to its template,
    /// and the project is registered as `add` would register it.
    func testInitWritesThePackageAndRegisters() throws {
        let project = try dir("My App")
        let expectedRoot = ProjectStore.canonicalRoot(project.path)

        let lines = try run(["init", project.path])
        XCTAssertEqual(
            lines,
            GoalsTemplates.files.map { "wrote docs/goals/\($0.path)" }
                + ["my-app\tMy App\t\(expectedRoot)\tdocs/goals"]
        )

        let written = try files(under: project.appendingPathComponent("docs/goals"))
        XCTAssertEqual(Set(written.keys), Set(GoalsTemplates.files.map(\.path)))
        for (path, contents) in GoalsTemplates.files {
            XCTAssertEqual(written[path], Data(contents.utf8), path)
        }
        XCTAssertEqual(
            ProjectStore.load(),
            [Project(id: "my-app", name: "My App", root: expectedRoot, knowledge: "docs/goals")]
        )
    }

    func testNameAndKnowledgeOptions() throws {
        let project = try dir("repo")
        try run(["init", project.path, "--name", "Kitterm", "--knowledge", "notes/goals"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("notes/goals/LOOP.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("docs").path))
        let registered = try XCTUnwrap(ProjectStore.load().first)
        XCTAssertEqual(registered.name, "Kitterm")
        XCTAssertEqual(registered.knowledge, "notes/goals")

        let other = try dir("other")
        try run(["init", other.path, "--name=Other", "--knowledge=docs"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("docs/STATE.md").path))
        XCTAssertEqual(ProjectStore.load().last?.knowledge, "docs")
    }

    /// A file that exists is never overwritten: the command names it, writes
    /// nothing, and registers nothing.
    func testRefusesToOverwriteAndWritesNothing() throws {
        let project = try dir("repo")
        let goals = project.appendingPathComponent("docs/goals", isDirectory: true)
        try FileManager.default.createDirectory(at: goals, withIntermediateDirectories: true)
        let mine = Data("# mine\n".utf8)
        try mine.write(to: goals.appendingPathComponent("goal.md"))
        try mine.write(to: goals.appendingPathComponent("STATE.md"))

        XCTAssertThrowsError(try run(["init", project.path])) { error in
            let message = String(describing: (error as? CLIError)?.errorDescription ?? "")
            XCTAssertTrue(message.contains("docs/goals/goal.md"), message)
            XCTAssertTrue(message.contains("docs/goals/STATE.md"), message)
            XCTAssertFalse(message.contains("plan.md"), "only the files that exist are named: \(message)")
        }
        XCTAssertEqual(try files(under: goals), ["goal.md": mine, "STATE.md": mine])
        XCTAssertEqual(ProjectStore.load(), [], "a refused init registers nothing")
    }

    /// A root that is already registered is refused before any file is written.
    func testRefusesARegisteredRoot() throws {
        let project = try dir("repo")
        try run(["add", project.path])
        XCTAssertThrowsError(try run(["init", project.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("docs").path))
        XCTAssertEqual(ProjectStore.load().count, 1)
    }

    func testUsageRefusals() throws {
        XCTAssertThrowsError(try run(["init"]))
        XCTAssertThrowsError(try run(["init", stateDir.path + "/no/such/dir"]))
        XCTAssertThrowsError(try run(["init", try dir("x").path, "--knowledge", "../escape"]))
        XCTAssertThrowsError(try run(["init", try dir("y").path, "--bogus"]))
        XCTAssertEqual(ProjectStore.load(), [])
    }
}
