import Foundation
import KittermDaemon
import XCTest

@testable import KittermCLI

/// `kitterm project add|list|remove` against a scratch state directory.
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

    /// A relative path resolves against the working directory.
    func testRelativePathResolvesAgainstCwd() throws {
        let path = try dir("rel")
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(work.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        try run(["add", "rel"])
        XCTAssertEqual(ProjectStore.load().first?.root, ProjectStore.canonicalRoot(path))
    }
}
