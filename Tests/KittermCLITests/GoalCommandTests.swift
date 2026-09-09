import Foundation
import XCTest

@testable import KittermCLI

/// `kitterm goal new|list` against a scratch checkout. No project is
/// registered: the commands read and write the checkout only.
final class GoalCommandTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-goal-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func dir(_ name: String) throws -> String {
        let url = work.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @discardableResult
    private func run(_ args: [String]) throws -> [String] {
        var lines: [String] = []
        try GoalCommand.run(args) { lines.append($0) }
        return lines
    }

    private func writeState(_ project: String, slug: String, lines: [String]) throws {
        let folder = project + "/docs/goals/" + slug
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: folder + "/STATE.md"))
    }

    // MARK: - new

    /// The folder holds the five template entries; `STATE.md` carries the
    /// slug in its heading; every other file equals its template.
    func testNewWritesTheGoalFolder() throws {
        let project = try dir("repo")
        let lines = try run(["new", project, "demo"])
        XCTAssertEqual(lines, GoalsTemplates.goal.map { "wrote docs/goals/demo/\($0.path)" })

        let folder = URL(fileURLWithPath: project).appendingPathComponent("docs/goals/demo")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            ["STATE.md", "corpus", "goal.md", "plan.md", "rounds"]
        )
        let written = try CLIFixture.files(under: folder)
        XCTAssertEqual(Set(written.keys), Set(GoalsTemplates.goal.map(\.path)))
        for (path, contents) in GoalsTemplates.goal where path != "STATE.md" {
            XCTAssertEqual(written[path], Data(contents.utf8), path)
        }
        let state = String(decoding: try XCTUnwrap(written["STATE.md"]), as: UTF8.self)
        XCTAssertTrue(state.hasPrefix("# STATE: demo\n\n- Status: active\n"), state)
        XCTAssertFalse(state.contains("<slug>"), "every <slug> placeholder is replaced")
        XCTAssertEqual(
            state, GoalsTemplates.state.replacingOccurrences(of: "<slug>", with: "demo"),
            "only the slug changes"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/docs/goals/LOOP.md"), "no project file")
    }

    func testNewKnowledgeOption() throws {
        let project = try dir("repo")
        try run(["new", project, "a-1", "--knowledge", "notes/goals"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project + "/notes/goals/a-1/STATE.md"))
        try run(["new", project, "b2", "--knowledge=notes/goals"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project + "/notes/goals/b2/goal.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/docs"))
    }

    /// A second `new` with the same slug is refused with nothing written:
    /// the folder keeps the bytes the first run wrote.
    func testNewRefusesAnExistingFolder() throws {
        let project = try dir("repo")
        try run(["new", project, "demo"])
        let folder = URL(fileURLWithPath: project).appendingPathComponent("docs/goals/demo")
        let before = try CLIFixture.files(under: folder)
        try Data("edited\n".utf8).write(to: folder.appendingPathComponent("goal.md"))
        let edited = try CLIFixture.files(under: folder)

        XCTAssertThrowsError(try run(["new", project, "demo"])) { error in
            let message = String(describing: (error as? CLIError)?.errorDescription ?? "")
            XCTAssertTrue(message.contains("docs/goals/demo exists"), message)
            XCTAssertTrue(message.contains("nothing written"), message)
        }
        XCTAssertEqual(try CLIFixture.files(under: folder), edited)
        XCTAssertNotEqual(before, edited)

        // A file, or a dangling link, of that name occupies it too.
        try Data().write(to: URL(fileURLWithPath: project + "/docs/goals/file"))
        XCTAssertThrowsError(try run(["new", project, "file"]))
        try FileManager.default.createSymbolicLink(atPath: project + "/docs/goals/gone", withDestinationPath: project + "/nowhere")
        XCTAssertThrowsError(try run(["new", project, "gone"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/nowhere"))
    }

    /// A slug is lowercase letters, digits, and hyphens. Anything else is
    /// refused before the knowledge directory exists.
    func testNewRefusesABadSlug() throws {
        let project = try dir("repo")
        for slug in ["Demo", "demo_1", "demo.md", "a/b", "../x", ".", "", "démo", "demo x", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try run(["new", project, slug]), "slug \(slug.debugDescription) is refused")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/docs"), "nothing written")
        XCTAssertTrue(GoalCommand.isValidSlug("a"))
        XCTAssertTrue(GoalCommand.isValidSlug("goal-folders-2"))
    }

    func testNewUsageRefusals() throws {
        let project = try dir("repo")
        XCTAssertThrowsError(try run(["new"]))
        XCTAssertThrowsError(try run(["new", project]), "the slug is required")
        XCTAssertThrowsError(try run(["new", project, "demo", "extra"]))
        XCTAssertThrowsError(try run(["new", work.path + "/no/such/dir", "demo"]))
        XCTAssertThrowsError(try run(["new", project, "demo", "--knowledge", "../escape"]))
        XCTAssertThrowsError(try run(["new", project, "demo", "--knowledge"]))
        XCTAssertThrowsError(try run(["new", project, "demo", "--bogus"]))
        XCTAssertThrowsError(try run(["frobnicate"]))
        XCTAssertThrowsError(try run([]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/docs"), "nothing written")
    }

    // MARK: - list

    /// One line per goal folder, `<slug>\t<status>`, ordered active,
    /// waiting, stopped, done, then the rest, and by slug inside a status.
    /// A folder without `STATE.md` and a plain file are not goals.
    func testListOrdersByStatusThenSlug() throws {
        let project = try dir("repo")
        try writeState(project, slug: "zed", lines: ["# STATE: zed", "", "- Status: active", "- Round: 1 of 3"])
        try writeState(project, slug: "alpha", lines: ["# STATE: alpha", "", "- Status: done"])
        try writeState(project, slug: "beta", lines: ["# STATE: beta", "", "- Status: stopped"])
        try writeState(project, slug: "mid", lines: ["# STATE: mid", "", "- Status:   waiting  "])
        try writeState(project, slug: "gamma", lines: ["# STATE: gamma", "", "- Status: active"])
        try writeState(project, slug: "odd", lines: ["# STATE: odd", "", "- Status: paused"])
        try writeState(project, slug: "bare", lines: ["# STATE: bare", "", "- Round: 0 of 3"])
        try writeState(project, slug: "blank", lines: ["# STATE: blank", "", "- Status:"])
        try FileManager.default.createDirectory(atPath: project + "/docs/goals/notagoal/rounds", withIntermediateDirectories: true)
        try Data("# LOOP\n".utf8).write(to: URL(fileURLWithPath: project + "/docs/goals/LOOP.md"))

        XCTAssertEqual(
            try run(["list", project]),
            [
                "gamma\tactive", "zed\tactive",
                "mid\twaiting",
                "beta\tstopped",
                "alpha\tdone",
                "bare\tunknown", "blank\tunknown", "odd\tpaused",
            ]
        )
    }

    /// `list` after `new` shows the new goal as active; a missing knowledge
    /// directory lists nothing and is not an error.
    func testListAfterNewAndOnAMissingDirectory() throws {
        let project = try dir("repo")
        XCTAssertEqual(try run(["list", project]), [])
        try run(["new", project, "demo"])
        XCTAssertEqual(try run(["list", project]), ["demo\tactive"])
        try run(["new", project, "other", "--knowledge", "notes"])
        XCTAssertEqual(try run(["list", project, "--knowledge", "notes"]), ["other\tactive"])
        XCTAssertEqual(try run(["list", project]), ["demo\tactive"])
    }

    func testListUsageRefusals() throws {
        let project = try dir("repo")
        XCTAssertThrowsError(try run(["list"]))
        XCTAssertThrowsError(try run(["list", project, "extra"]))
        XCTAssertThrowsError(try run(["list", work.path + "/no/such/dir"]))
        XCTAssertThrowsError(try run(["list", project, "--knowledge", "/abs"]))
    }

    /// This repository's own package: `goal-folders` before
    /// `projects-and-knowledge` (done), every `done` goal after every
    /// `active` one. Containment and order only, so a new goal folder
    /// keeps the floor green.
    func testListThisRepository() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/goals/projects-and-knowledge/STATE.md").path) else {
            throw XCTSkip("docs/goals/projects-and-knowledge is not beside the test source")
        }
        let lines = try run(["list", root.path])
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("projects-and-knowledge\tdone"), joined)
        let slugs = lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init) }
        let statuses = lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).last.map(String.init) }
        let folders = try XCTUnwrap(slugs.firstIndex(of: "goal-folders"), joined)
        let done = try XCTUnwrap(slugs.firstIndex(of: "projects-and-knowledge"), joined)
        XCTAssertLessThan(folders, done, "goal-folders before projects-and-knowledge")
        if let lastActive = statuses.lastIndex(of: "active"), let firstDone = statuses.firstIndex(of: "done") {
            XCTAssertLessThan(lastActive, firstDone, "every done goal after every active one")
        }
        for line in lines {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            XCTAssertEqual(parts.count, 2, line)
            XCTAssertTrue(GoalCommand.isValidSlug(String(parts[0])), line)
        }
    }
}
