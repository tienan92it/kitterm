import Foundation
import XCTest

/// `scripts/test-diff-guard.sh` on a scratch git repository: each case
/// commits a base, commits a change on a second branch, and runs the script
/// against the two. The script reads only `git` and `sh`, so nothing here
/// touches the checkout the test sits in.
final class TestDiffGuardTests: XCTestCase {
    private var scratch: URL!

    private static let script = CLIFixture.repositoryRoot
        .appendingPathComponent("scripts/test-diff-guard.sh").path

    private static let baseTest = """
    import XCTest
    final class SampleTests: XCTestCase {
        func testSum() {
            XCTAssertEqual(1 + 1, 2)
        }
    }

    """

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/env"),
              try run("git", ["--version"]).status == 0,
              try run("sh", ["-c", "true"]).status == 0
        else { throw XCTSkip("git or sh is not available here") }
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-diff-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "guard@example.invalid")
        try git("config", "user.name", "guard")
        try git("config", "commit.gpgsign", "false")
        try write("Tests/SampleTests.swift", Self.baseTest)
        try write(".github/workflows/ci.yml", "name: CI\n")
        try commit("base")
        try git("switch", "-q", "-c", "change")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testRemovedAssertionExitsOne() throws {
        try write("Tests/SampleTests.swift", Self.baseTest.replacingOccurrences(
            of: "        XCTAssertEqual(1 + 1, 2)\n", with: ""))
        try commit("weaken")
        let result = try guardRun()
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("::warning file=Tests/SampleTests.swift,line="), result.output)
        XCTAssertTrue(result.output.contains("assertion removed or changed"), result.output)
    }

    func testRemovedAssertionWithCharteredLineExitsZero() throws {
        try write("Tests/SampleTests.swift", Self.baseTest.replacingOccurrences(
            of: "XCTAssertEqual(1 + 1, 2)", with: "XCTAssertEqual(2 + 2, 4)"))
        try commit("replace")
        let body = "Summary\n\nChartered: sum now pins 2 + 2, same intent.\n"
        let result = try guardRun(body: body)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("::warning"), "the finding is still printed")
    }

    func testAddedAssertionOnlyExitsZero() throws {
        try write("Tests/SampleTests.swift", Self.baseTest.replacingOccurrences(
            of: "    }\n}\n", with: "        XCTAssertTrue(true)\n    }\n}\n"))
        try write("Tests/NewTests.swift", Self.baseTest.replacingOccurrences(of: "SampleTests", with: "NewTests"))
        try commit("strengthen")
        let result = try guardRun()
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(result.output.contains("::warning"), result.output)
    }

    func testAddedSkipExitsOne() throws {
        try write("Tests/SampleTests.swift", Self.baseTest.replacingOccurrences(
            of: "        XCTAssertEqual(1 + 1, 2)\n",
            with: "        throw XCTSkip(\"later\")\n        XCTAssertEqual(1 + 1, 2)\n"))
        try commit("skip")
        let result = try guardRun()
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("skip or focus marker added"), result.output)
    }

    func testWorkflowEditExitsOne() throws {
        try write(".github/workflows/ci.yml", "name: CI\non: push\n")
        try commit("workflow")
        let result = try guardRun()
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("::warning file=.github/workflows/ci.yml,line=1::"), result.output)
    }

    // MARK: - Scratch repository

    private func guardRun(body: String? = nil) throws -> (status: Int32, output: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["PR_BODY"] = body ?? ""
        environment.removeValue(forKey: "PR_BODY_FILE")
        return try run("sh", [Self.script, "main", "HEAD"], environment: environment)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = scratch.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    private func git(_ arguments: String...) throws {
        let result = try run("git", arguments)
        XCTAssertEqual(result.status, 0, "git \(arguments.joined(separator: " ")): \(result.output)")
    }

    private func run(
        _ tool: String, _ arguments: [String], environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        if let scratch { process.currentDirectoryURL = scratch }
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        waitForExit(of: process, output: output)
        return (process.terminationStatus, output)
    }
}
