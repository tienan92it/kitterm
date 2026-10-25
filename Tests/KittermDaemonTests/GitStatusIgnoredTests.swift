import Foundation
import XCTest

@testable import KittermDaemon

/// `GET /api/git/status`'s `ignored` field (`code-editor` round 13,
/// `corpus/09-approved-frames.md` rule 19): `--ignored=matching` names a
/// top-level ignored path without descending into it, kept out of `files`
/// and `counts`, capped at `GitStatus.maxIgnored`.
final class GitStatusIgnoredTests: XCTestCase {
    private var git: String!
    private var scratch: URL!
    private var repo: String!

    override func setUpWithError() throws {
        git = try XCTUnwrap(PullRequestStatus.locate("git", in: PullRequestStatus.defaultSearchPath), "git on PATH")
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-git-ignored-\(UUID().uuidString)", isDirectory: true)
        let repoURL = scratch.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        repo = try XCTUnwrap(FileEdit.realPath(repoURL.path))
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try ".build/\nnode_modules/\n*.log\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: repo + "/.build/x.txt", atomically: true, encoding: .utf8)
        try "y\n".write(toFile: repo + "/node_modules/y.js", atomically: true, encoding: .utf8)
        try "log\n".write(toFile: repo + "/debug.log", atomically: true, encoding: .utf8)
        try sh(repo, "init", "-q", "-b", "main")
        try sh(repo, "add", "a.txt", ".gitignore")
        try sh(repo, "commit", "-q", "-m", "init")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func sh(_ directory: String, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "t"
        environment["GIT_AUTHOR_EMAIL"] = "t@example"
        environment["GIT_COMMITTER_NAME"] = "t"
        environment["GIT_COMMITTER_EMAIL"] = "t@example"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard waitForExit(of: process, output: text) else { return text }
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")): \(text)")
        return text
    }

    /// An ignored directory is one `!` record (`.build/`), never one per
    /// file inside it; an ignored file (`debug.log`) is its own record. A
    /// clean, committed file is no entry at all.
    func testIgnoredDirectoriesAndFilesListAtTheTopLevelWithNoDescent() throws {
        let gitRead = GitRead()
        let report = try gitRead.status(of: GitRead.Repository(toplevel: repo, relative: ""))
        XCTAssertEqual(Set(report.ignored), [".build/", "node_modules/", "debug.log"])
        XCTAssertFalse(report.ignoredTruncated)
        XCTAssertTrue(report.files.isEmpty, "a.txt is clean and committed; nothing else is a change")
        XCTAssertFalse(report.ignored.contains(".build/x.txt"))
        XCTAssertFalse(report.ignored.contains("node_modules/y.js"))
    }

    func testTheIgnoredListIsCappedWithATruncatedFlag() {
        var records = ["# branch.oid abc", "# branch.head main"]
        for i in 0..<(GitStatus.maxIgnored + 5) { records.append("! dir\(i)/") }
        let data = Data(records.joined(separator: "\0").utf8) + Data([0])
        let report = GitStatus.parse(data)
        XCTAssertEqual(report.ignored.count, GitStatus.maxIgnored)
        XCTAssertTrue(report.ignoredTruncated)
    }
}
