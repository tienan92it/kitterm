import Foundation
import XCTest

@testable import KittermDaemon

/// Each merged pull request keeps its number and the lines it added
/// (`agent-dashboard`, round 10): the fleet view's `WHERE` panel prices a
/// goal's lines from the `PR #N` its round records name, so the yield
/// carries a `pullRequests` list beside the two sums. The number is read
/// from the same two subject shapes `isPullRequest` accepts.
final class RepositoryYieldPullRequestTests: XCTestCase {
    static let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-yield-pr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testTheNumberComesFromTheSquashSuffixOrTheMergeSubject() {
        XCTAssertEqual(RepositoryYield.pullRequestNumber("Say every agent's model on its line (#129)"), 129)
        XCTAssertEqual(RepositoryYield.pullRequestNumber("Merge pull request #12 from tienan92it/fix"), 12)
        XCTAssertEqual(RepositoryYield.pullRequestNumber("  Trailing space (#7)  "), 7)
        XCTAssertNil(RepositoryYield.pullRequestNumber("Back-fill the Cost line on rounds 1 to 4"))
        XCTAssertNil(RepositoryYield.pullRequestNumber("Note (see #12)"), "a reference is not a merge")
        XCTAssertNil(RepositoryYield.pullRequestNumber("Fix (#12a)"))
    }

    func testAReadListsEachMergedPullRequestWithItsLines() throws {
        let root = try repo("listed")
        try git(root, ["remote", "add", "origin", "https://example.invalid/repo.git"])
        try commit(root, "Before the range (#1)", lines: 50, at: "2026-08-01T10:00:00+07:00")
        try commit(root, "Plain work", lines: 7, at: "2026-09-02T10:00:00+07:00")
        try commit(root, "First merged (#2)", lines: 100, at: "2026-09-03T10:00:00+07:00")
        try commit(root, "Merge pull request #3 from x/y", lines: 20, at: "2026-09-04T10:00:00+07:00")
        try commit(root, "Docs only (#4)", lines: 0, at: "2026-09-05T10:00:00+07:00")
        try git(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])

        let yield = RepositoryYield.read(root: root, from: DayKey("2026-09-01")!, to: DayKey("2026-09-30")!, zone: Self.saigon)
        XCTAssertEqual(yield.mergedPullRequests, 3)
        XCTAssertEqual(yield.mergedLines, 120)
        // Newest first, the log's own order; the plain commit and the one
        // before the range are not in it; a merge that added nothing is a
        // measured zero.
        XCTAssertEqual(yield.pullRequests, [
            .init(number: 4, lines: 0),
            .init(number: 3, lines: 20),
            .init(number: 2, lines: 100),
        ])
        XCTAssertEqual(yield.pullRequests?.reduce(0) { $0 + $1.lines }, yield.mergedLines, "the list sums to the total")

        let empty = RepositoryYield.read(root: root, from: DayKey("2026-10-01")!, to: DayKey("2026-10-31")!, zone: Self.saigon)
        XCTAssertEqual(empty.pullRequests, [], "a range with nothing merged lists nothing, and is not absent")
    }

    func testARootWithNoRemoteOrNoCheckoutListsNothing() throws {
        let root = try repo("noremote")
        try commit(root, "Local merge (#9)", lines: 10, at: "2026-09-03T10:00:00+07:00")
        let yield = RepositoryYield.read(root: root, from: DayKey("2026-09-01")!, to: DayKey("2026-09-30")!, zone: Self.saigon)
        XCTAssertNil(yield.pullRequests, "a pull request is the remote's concept")
        XCTAssertNil(RepositoryYield.none.pullRequests)
    }

    func testTheListRidesOnTheRouteBody() throws {
        let report = RepositoryYields.Report(
            from: "2026-09-01", to: "2026-09-30",
            projects: [.init(
                id: "p", name: "p", root: "/p", registered: true,
                yield: RepositoryYield(
                    checkout: true, remote: true, branch: "origin/main", mergedPullRequests: 1, mergedLines: 12, releases: 0,
                    pullRequests: [.init(number: 5, lines: 12)]
                )
            )],
            totals: .init(checkouts: 1, counted: 1, mergedPullRequests: 1, mergedLines: 12, releases: 0)
        )
        let body = HTTPAPIHandler.yieldBody(report)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let project = try XCTUnwrap((json["projects"] as? [[String: Any]])?.first)
        let yield = try XCTUnwrap(project["yield"] as? [String: Any])
        let list = try XCTUnwrap(yield["pullRequests"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["number"] as? Int, 5)
        XCTAssertEqual(list[0]["lines"] as? Int, 12)
    }

    // MARK: - helpers

    private func repo(_ name: String) throws -> String {
        let root = scratch.appendingPathComponent(name, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git(root, ["init", "-q", "-b", "main"])
        try git(root, ["config", "user.email", "crew@example.test"])
        try git(root, ["config", "user.name", "crew"])
        try git(root, ["config", "commit.gpgsign", "false"])
        try git(root, ["config", "tag.gpgsign", "false"])
        return root
    }

    private func commit(_ root: String, _ subject: String, lines: Int, at: String) throws {
        let name = "f-\(UUID().uuidString.prefix(8)).txt"
        let body = (0..<lines).map { "line \($0)" }.joined(separator: "\n") + (lines > 0 ? "\n" : "")
        try body.write(toFile: root + "/" + name, atomically: true, encoding: .utf8)
        try git(root, ["add", name])
        try git(root, ["commit", "-q", "--allow-empty", "-m", subject], at: at)
    }

    private func git(_ root: String, _ args: [String], at: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root] + args
        var environment = ProcessInfo.processInfo.environment
        if let at {
            environment["GIT_AUTHOR_DATE"] = at
            environment["GIT_COMMITTER_DATE"] = at
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        waitForExit(of: process)
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }
}
