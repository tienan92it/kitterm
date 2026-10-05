import Foundation
import XCTest

@testable import KittermDaemon

/// A `gh` that is a shell script in a scratch directory, the only directory
/// on the search path a test hands `PullRequestStatus`, so the real `gh`
/// never runs. `mode` picks the answer; `calls.log` holds one line per run.
struct FakeGH {
    let directory: URL
    var searchPath: String { directory.path }

    private static let script = """
        #!/bin/sh
        dir="$(/usr/bin/dirname "$0")"
        echo "$*" >> "$dir/calls.log"
        mode="$(/bin/cat "$dir/mode" 2>/dev/null)"
        if [ "$1" = "auth" ]; then
          if [ "$mode" = "logged-out" ]; then
            echo "You are not logged into any GitHub hosts." >&2
            exit 1
          fi
          exit 0
        fi
        case "$mode" in
          ok) /bin/cat "$dir/pulls.json" ;;
          logged-out) echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4 ;;
          fail) echo "GraphQL: Could not resolve to a Repository" >&2; echo "second line" >&2; exit 1 ;;
          garbage) echo "not json" ;;
          slow) exec /bin/sleep 2 ;;
        esac

        """

    /// Three pulls: an open draft whose checks run, a merged one whose
    /// checks passed, a closed one with no check.
    static let pulls = """
        [{"additions":16844,"deletions":52,"headRefName":"goal/sessions-workflow","isDraft":true,"mergedAt":null,
          "number":185,"state":"OPEN","title":"sessions-workflow","url":"https://github.com/o/r/pull/185",
          "statusCheckRollup":[{"__typename":"CheckRun","conclusion":"","name":"test","status":"IN_PROGRESS"},
                               {"__typename":"CheckRun","conclusion":"SUCCESS","name":"pages","status":"COMPLETED"}]},
         {"additions":505,"deletions":20,"headRefName":"chore/respawn-resync","isDraft":false,
          "mergedAt":"2026-10-02T01:42:11Z","number":184,"state":"MERGED","title":"A respawned shell",
          "url":"https://github.com/o/r/pull/184",
          "statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","name":"test","status":"COMPLETED"},
                               {"__typename":"CheckRun","conclusion":"SKIPPED","name":"bench","status":"COMPLETED"}]},
         {"additions":1,"deletions":2,"headRefName":"old","isDraft":false,"mergedAt":null,"number":7,
          "state":"CLOSED","title":"Dropped","url":"https://github.com/o/r/pull/7","statusCheckRollup":[]}]
        """

    /// A directory with the script in it; `withScript: false` leaves the
    /// directory empty, a machine with no `gh`.
    init(withScript: Bool = true) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-fake-gh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard withScript else { return }
        let gh = directory.appendingPathComponent("gh")
        try Self.script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        try Self.pulls.write(to: directory.appendingPathComponent("pulls.json"), atomically: true, encoding: .utf8)
        try set(mode: "ok")
    }

    func set(mode: String) throws {
        try mode.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    /// The argument line of every run so far.
    var calls: [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    var listCalls: Int { calls.filter { $0.hasPrefix("pr list") }.count }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// `PullRequestStatus`: the parse of `gh pr list --json`, the CI word, each
/// reason, and the one-minute bound, against a fake `gh`.
final class PullRequestStatusTests: XCTestCase {
    private var gh: FakeGH!
    private let repository = "o/r"

    override func setUpWithError() throws {
        gh = try FakeGH()
    }

    override func tearDown() {
        // Let a read still on the queue end before its script goes.
        PullRequestStatus.queue.sync {}
        gh.remove()
    }

    /// One read through the queue, as the route starts it.
    private func read(_ status: PullRequestStatus, at now: Date = Date()) -> PullRequestStatus.Snapshot {
        XCTAssertTrue(status.refreshIfDue(repository: repository, now: now))
        PullRequestStatus.queue.sync {}
        return status.snapshot(repository: repository)
    }

    // MARK: - the parse

    func testParseReadsEveryField() throws {
        let pulls = try XCTUnwrap(PullRequestStatus.parse(Data(FakeGH.pulls.utf8)))
        XCTAssertEqual(pulls.map(\.number), [185, 184, 7], "gh's order is kept")
        XCTAssertEqual(pulls[0], PullRequestStatus.Pull(
            number: 185, title: "sessions-workflow", state: "open", draft: true,
            headRefName: "goal/sessions-workflow", mergedAt: nil, url: "https://github.com/o/r/pull/185",
            ci: "pending", additions: 16844, deletions: 52
        ))
        XCTAssertEqual(pulls[1].state, "merged")
        XCTAssertEqual(pulls[1].mergedAt, "2026-10-02T01:42:11Z")
        XCTAssertEqual(pulls[1].ci, "passing")
        XCTAssertFalse(pulls[1].draft)
        XCTAssertEqual(pulls[2].state, "closed")
        XCTAssertNil(pulls[2].ci, "no check, no word")
    }

    func testParseRefusesWhatIsNotAList() {
        XCTAssertNil(PullRequestStatus.parse(Data("not json".utf8)))
        XCTAssertNil(PullRequestStatus.parse(Data(#"{"number":1}"#.utf8)))
        XCTAssertEqual(PullRequestStatus.parse(Data("[]".utf8)), [])
        XCTAssertEqual(PullRequestStatus.parse(Data(#"[{"title":"no number"}]"#.utf8)), [], "an item with no number is skipped")
    }

    func testPullJSONOmitsAbsentFields() throws {
        let pulls = try XCTUnwrap(PullRequestStatus.parse(Data(FakeGH.pulls.utf8)))
        let closed = pulls[2].json
        XCTAssertNil(closed["ci"])
        XCTAssertNil(closed["mergedAt"])
        XCTAssertEqual(closed["draft"] as? Bool, false)
        XCTAssertEqual(pulls[1].json["mergedAt"] as? String, "2026-10-02T01:42:11Z")
        XCTAssertEqual(pulls[1].json["ci"] as? String, "passing")
    }

    // MARK: - the CI word

    func testCIWord() {
        func run(_ status: String, _ conclusion: String) -> [String: Any] {
            ["__typename": "CheckRun", "status": status, "conclusion": conclusion]
        }
        func context(_ state: String) -> [String: Any] { ["__typename": "StatusContext", "state": state] }
        XCTAssertNil(PullRequestStatus.ciWord(rollup: []))
        XCTAssertEqual(PullRequestStatus.ciWord(rollup: [run("COMPLETED", "SUCCESS")]), "passing")
        XCTAssertEqual(PullRequestStatus.ciWord(rollup: [run("COMPLETED", "NEUTRAL"), run("COMPLETED", "SKIPPED")]), "passing")
        XCTAssertEqual(PullRequestStatus.ciWord(rollup: [run("COMPLETED", "SUCCESS"), run("QUEUED", "")]), "pending")
        XCTAssertEqual(PullRequestStatus.ciWord(rollup: [run("IN_PROGRESS", "")]), "pending")
        for failed in ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"] {
            XCTAssertEqual(PullRequestStatus.ciWord(rollup: [run("COMPLETED", failed)]), "failing", failed)
        }
        XCTAssertEqual(
            PullRequestStatus.ciWord(rollup: [run("IN_PROGRESS", ""), run("COMPLETED", "FAILURE"), run("COMPLETED", "SUCCESS")]),
            "failing", "a failure wins over a check that still runs")
        XCTAssertEqual(PullRequestStatus.ciWord(rollup: [context("SUCCESS")]), "passing")
        XCTAssertEqual(PullRequestStatus.ciWord(rollup: [context("PENDING"), run("COMPLETED", "SUCCESS")]), "pending")
        XCTAssertEqual(PullRequestStatus.ciWord(rollup: [context("EXPECTED")]), "pending")
        XCTAssertEqual(PullRequestStatus.ciWord(rollup: [context("FAILURE")]), "failing")
        XCTAssertEqual(PullRequestStatus.ciWord(rollup: [context("ERROR"), context("SUCCESS")]), "failing")
    }

    func testRepositoryOfPullRequestBase() {
        XCTAssertEqual(PullRequestStatus.repository(pullRequestBase: "https://github.com/owner/repo/pull/"), "owner/repo")
        XCTAssertNil(PullRequestStatus.repository(pullRequestBase: "https://gitlab.com/owner/repo/pull/"))
        XCTAssertNil(PullRequestStatus.repository(pullRequestBase: "https://github.com//pull/"))
    }

    // MARK: - a good read

    func testAReadAsksGhForTheListAndKeepsIt() {
        let status = PullRequestStatus(searchPath: gh.searchPath)
        XCTAssertEqual(status.snapshot(repository: repository),
                       PullRequestStatus.Snapshot(pulls: [], readAt: nil, reason: "not read yet"))
        let before = Date()
        let snapshot = read(status)
        XCTAssertEqual(snapshot.pulls.map(\.number), [185, 184, 7])
        XCTAssertNil(snapshot.reason)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(snapshot.readAt), before)
        XCTAssertEqual(gh.calls, [
            "pr list --repo o/r --state all --limit 50 --json "
                + "number,title,state,isDraft,headRefName,mergedAt,url,statusCheckRollup,additions,deletions",
        ], "one gh, no auth check after a good list")
    }

    // MARK: - the reasons

    func testGhAbsentFromThePath() throws {
        let empty = try FakeGH(withScript: false)
        defer { empty.remove() }
        let snapshot = read(PullRequestStatus(searchPath: empty.searchPath))
        XCTAssertEqual(snapshot, PullRequestStatus.Snapshot(pulls: [], readAt: nil, reason: "gh is not on PATH"))
    }

    func testGhNotLoggedIn() throws {
        try gh.set(mode: "logged-out")
        let snapshot = read(PullRequestStatus(searchPath: gh.searchPath))
        XCTAssertEqual(snapshot, PullRequestStatus.Snapshot(pulls: [], readAt: nil, reason: "gh is not logged in"))
        XCTAssertEqual(gh.calls.last, "auth status", "gh auth status decides it")
    }

    func testAFailedCallNamesTheExitCodeAndTheFirstStderrLine() throws {
        try gh.set(mode: "fail")
        let snapshot = read(PullRequestStatus(searchPath: gh.searchPath))
        XCTAssertEqual(snapshot.reason, "gh pr list exited 1: GraphQL: Could not resolve to a Repository")
        XCTAssertNil(snapshot.readAt)
        XCTAssertEqual(snapshot.pulls, [])
    }

    func testOutputThatIsNotJSON() throws {
        try gh.set(mode: "garbage")
        XCTAssertEqual(read(PullRequestStatus(searchPath: gh.searchPath)).reason, "gh pr list printed no JSON list")
    }

    func testAGhThatHangsIsEndedAtTheTimeout() throws {
        try gh.set(mode: "slow")
        let path = gh.searchPath
        let status = PullRequestStatus(searchPath: path) { executable, args in
            PullRequestStatus.run(executable: executable, args: args, searchPath: path, timeout: 0.3)
        }
        let started = Date()
        let snapshot = read(status)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.9, "the 2 s sleep did not run to its end")
        XCTAssertEqual(snapshot.reason, "gh pr list timed out after 20 s")
        XCTAssertEqual(gh.calls.count, 1, "no auth check after a timeout")
    }

    func testAFailureKeepsTheLastGoodReadAndItsTime() throws {
        let status = PullRequestStatus(searchPath: gh.searchPath)
        let start = Date()
        let good = read(status, at: start)
        try gh.set(mode: "fail")
        let failed = read(status, at: start.addingTimeInterval(60))
        XCTAssertEqual(failed.pulls, good.pulls)
        XCTAssertEqual(failed.readAt, good.readAt, "the time of the last good read")
        XCTAssertEqual(failed.reason, "gh pr list exited 1: GraphQL: Could not resolve to a Repository")
        try gh.set(mode: "ok")
        let again = read(status, at: start.addingTimeInterval(120))
        XCTAssertNil(again.reason, "a good read clears the reason")
        XCTAssertGreaterThan(try XCTUnwrap(again.readAt), try XCTUnwrap(good.readAt))
    }

    // MARK: - the one-minute bound

    func testOneReadAMinutePerRepository() {
        let status = PullRequestStatus(searchPath: gh.searchPath)
        let start = Date()
        XCTAssertTrue(status.refreshIfDue(repository: repository, now: start))
        for offset in [0.0, 1, 30, 59.9] {
            XCTAssertFalse(status.refreshIfDue(repository: repository, now: start.addingTimeInterval(offset)), "\(offset)")
        }
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.listCalls, 1)
        XCTAssertFalse(status.refreshIfDue(repository: repository, now: start.addingTimeInterval(59.9)), "still under a minute once the read ended")
        XCTAssertTrue(status.refreshIfDue(repository: repository, now: start.addingTimeInterval(60)))
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.listCalls, 2)
        XCTAssertTrue(status.refreshIfDue(repository: "o/other", now: start), "the bound is per repository")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.listCalls, 3)
    }

    func testAFailedReadIsBoundedToo() throws {
        try gh.set(mode: "fail")
        let status = PullRequestStatus(searchPath: gh.searchPath)
        let start = Date()
        _ = read(status, at: start)
        XCTAssertFalse(status.refreshIfDue(repository: repository, now: start.addingTimeInterval(30)))
        XCTAssertEqual(gh.listCalls, 1)
    }

    func testNoSecondReadWhileOneRuns() throws {
        try gh.set(mode: "slow")
        let path = gh.searchPath
        let status = PullRequestStatus(searchPath: path) { executable, args in
            PullRequestStatus.run(executable: executable, args: args, searchPath: path, timeout: 0.3)
        }
        let start = Date()
        XCTAssertTrue(status.refreshIfDue(repository: repository, now: start))
        XCTAssertFalse(status.refreshIfDue(repository: repository, now: start.addingTimeInterval(3600)),
                       "a read in flight holds the next one, whatever the clock says")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.listCalls, 1)
    }
}
