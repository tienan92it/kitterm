import Foundation
import NIOConcurrencyHelpers
import XCTest

@testable import KittermDaemon

/// A `gh` that is a shell script in a scratch directory, the only directory
/// on the search path a test hands `PullRequestStatus`, so the real `gh`
/// never runs. `mode` picks the answer; `calls.log` holds one line per run.
struct FakeGH {
    /// What the fake prints for `gh auth token`. No test may find it in a
    /// result.
    static let token = "gho_fakefakefake"

    let directory: URL
    var searchPath: String { directory.path }

    private static let script = """
        #!/bin/sh
        dir="$(/usr/bin/dirname "$0")"
        echo "$*" >> "$dir/calls.log"
        mode="$(/bin/cat "$dir/mode" 2>/dev/null)"
        if [ "$1" = "auth" ]; then
          if [ "$mode" = "logged-out" ]; then
            echo "no oauth token found for github.com" >&2
            exit 1
          fi
          echo "gho_fakefakefake"
          exit 0
        fi
        case "$mode" in
          ok) /bin/cat "$dir/pulls.json" ;;
          logged-out) echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4 ;;
          fail) echo "GraphQL: Could not resolve to a Repository" >&2; echo "second line" >&2; exit 1 ;;
          garbage) echo "not json" ;;
          slow) exec /bin/sleep 2 ;;
          big) /bin/cat "$dir/big.json" ;;
          holder) /bin/sleep 3 & /bin/cat "$dir/pulls.json" ;;
          stubborn) trap '' TERM; echo $$ > "$dir/pid"; /bin/sleep 5 ;;
        esac

        """

    /// Three pulls: an open draft whose checks run, a merged one whose
    /// checks passed, a closed one with no check.
    static let pulls = """
        [{"additions":16844,"deletions":52,"headRefName":"goal/sessions-workflow","isDraft":true,"mergedAt":null,
          "number":185,"state":"OPEN","title":"sessions-workflow","url":"https://github.com/o/r/pull/185",
          "createdAt":"2026-10-03T10:00:00Z","updatedAt":"2026-10-05T18:34:00Z",
          "statusCheckRollup":[{"__typename":"CheckRun","conclusion":"","name":"test","status":"IN_PROGRESS"},
                               {"__typename":"CheckRun","conclusion":"SUCCESS","name":"pages","status":"COMPLETED"}]},
         {"additions":505,"deletions":20,"headRefName":"chore/respawn-resync","isDraft":false,
          "mergedAt":"2026-10-02T01:42:11Z","number":184,"state":"MERGED","title":"A respawned shell",
          "url":"https://github.com/o/r/pull/184","createdAt":"2026-10-01T09:00:00Z","updatedAt":"2026-10-02T01:42:11Z",
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

/// A clock a test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NIOLock()
    private var time = Date()
    var now: Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// `PullRequestStatus`: the parse of `gh pr list --json`, the CI word, each
/// reason, and the one-minute bound, against a fake `gh`.
final class PullRequestStatusTests: XCTestCase {
    private var gh: FakeGH!
    private var clock: TestClock!
    private let repository = "o/r"

    override func setUpWithError() throws {
        gh = try FakeGH()
        clock = TestClock()
    }

    /// A status on the fake `gh` and the test clock. `timeout` shortens the
    /// run's timeout and its two graces.
    private func makeStatus(searchPath: String? = nil, timeout: TimeInterval? = nil) -> PullRequestStatus {
        let path = searchPath ?? gh.searchPath
        let clock = self.clock!
        guard let timeout else { return PullRequestStatus(searchPath: path, clock: { clock.now }) }
        return PullRequestStatus(searchPath: path, run: { executable, args, keepOutput in
            PullRequestStatus.run(
                executable: executable, args: args, searchPath: path, timeout: timeout,
                killGrace: 0.3, pipeGrace: 0.3, keepOutput: keepOutput
            )
        }, clock: { clock.now })
    }

    override func tearDown() {
        // Let a read still on the queue end before its script goes.
        PullRequestStatus.queue.sync {}
        gh.remove()
    }

    /// One read through the queue, as the route starts it.
    private func read(_ status: PullRequestStatus) -> PullRequestStatus.Snapshot {
        XCTAssertTrue(status.refreshIfDue(repository: repository))
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
            ci: "pending", additions: 16844, deletions: 52,
            createdAt: "2026-10-03T10:00:00Z", updatedAt: "2026-10-05T18:34:00Z"
        ))
        XCTAssertEqual(pulls[1].state, "merged")
        XCTAssertEqual(pulls[1].mergedAt, "2026-10-02T01:42:11Z")
        XCTAssertEqual(pulls[1].ci, "passing")
        XCTAssertFalse(pulls[1].draft)
        XCTAssertEqual(pulls[2].state, "closed")
        XCTAssertNil(pulls[2].ci, "no check, no word")
        XCTAssertNil(pulls[2].createdAt, "a gh that printed no time gives none")
        XCTAssertNil(pulls[2].updatedAt)
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
        XCTAssertNil(closed["createdAt"])
        XCTAssertNil(closed["updatedAt"])
        XCTAssertEqual(closed["draft"] as? Bool, false)
        XCTAssertEqual(pulls[0].json["createdAt"] as? String, "2026-10-03T10:00:00Z")
        XCTAssertEqual(pulls[0].json["updatedAt"] as? String, "2026-10-05T18:34:00Z")
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
        let status = makeStatus()
        XCTAssertEqual(status.snapshot(repository: repository),
                       PullRequestStatus.Snapshot(pulls: [], readAt: nil, reason: "not read yet"))
        let snapshot = read(status)
        XCTAssertEqual(snapshot.pulls.map(\.number), [185, 184, 7])
        XCTAssertNil(snapshot.reason)
        XCTAssertEqual(snapshot.readAt, clock.now)
        XCTAssertEqual(gh.calls, [
            "pr list --repo o/r --state all --limit 50 --json "
                + "number,title,state,isDraft,headRefName,mergedAt,url,statusCheckRollup,additions,deletions,createdAt,updatedAt,isCrossRepository",
        ], "one gh, no auth check after a good list")
    }

    // MARK: - the reasons

    func testGhAbsentFromThePath() throws {
        let empty = try FakeGH(withScript: false)
        defer { empty.remove() }
        let snapshot = read(makeStatus(searchPath: empty.searchPath))
        XCTAssertEqual(snapshot, PullRequestStatus.Snapshot(pulls: [], readAt: nil, reason: "gh is not on PATH"))
    }

    func testGhNotLoggedIn() throws {
        try gh.set(mode: "logged-out")
        let snapshot = read(makeStatus())
        XCTAssertEqual(snapshot, PullRequestStatus.Snapshot(pulls: [], readAt: nil, reason: "gh is not logged in"))
        XCTAssertEqual(gh.calls.last, "auth token", "the local gh auth token decides it, not gh auth status")
    }

    func testTheTokenOfTheAuthCheckIsNeverKept() throws {
        try gh.set(mode: "fail")
        let snapshot = read(makeStatus())
        XCTAssertEqual(gh.calls.last, "auth token")
        XCTAssertEqual(snapshot.reason, "gh pr list exited 1: GraphQL: Could not resolve to a Repository")
        let script = gh.directory.appendingPathComponent("gh").path
        let kept = try XCTUnwrap(PullRequestStatus.run(
            executable: script, args: ["auth", "token"], searchPath: gh.searchPath, timeout: 5))
        XCTAssertTrue(String(decoding: kept.output, as: UTF8.self).contains(FakeGH.token), "the fake does print one")
        let dropped = try XCTUnwrap(PullRequestStatus.run(
            executable: script, args: ["auth", "token"], searchPath: gh.searchPath, timeout: 5, keepOutput: false))
        XCTAssertEqual(dropped.status, 0)
        XCTAssertEqual(dropped.output, Data(), "stdout went to /dev/null")
        XCTAssertFalse(dropped.error.contains(FakeGH.token))
    }

    func testARelativePathEntryIsSkipped() {
        XCTAssertEqual(PullRequestStatus.locate("sh", in: "bin:.::/bin"), "/bin/sh")
        XCTAssertNil(PullRequestStatus.locate("sh", in: "bin:."))
        let relative = "../../../../../../../../../../../.." + gh.searchPath
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: relative + "/gh"), "the relative entry does reach the fake")
        XCTAssertNil(PullRequestStatus.locate("gh", in: relative))
    }

    func testAFailedCallNamesTheExitCodeAndTheFirstStderrLine() throws {
        try gh.set(mode: "fail")
        let snapshot = read(makeStatus())
        XCTAssertEqual(snapshot.reason, "gh pr list exited 1: GraphQL: Could not resolve to a Repository")
        XCTAssertNil(snapshot.readAt)
        XCTAssertEqual(snapshot.pulls, [])
    }

    func testOutputThatIsNotJSON() throws {
        try gh.set(mode: "garbage")
        XCTAssertEqual(read(makeStatus()).reason, "gh pr list printed no JSON list")
    }

    func testAGhThatHangsIsEndedAtTheTimeout() throws {
        try gh.set(mode: "slow")
        let started = Date()
        let snapshot = read(makeStatus(timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.9, "the 2 s sleep did not run to its end")
        XCTAssertEqual(snapshot.reason, "gh pr list timed out after 20 s")
        XCTAssertEqual(gh.calls.count, 1, "no auth check after a timeout")
    }

    /// A `gh` that ignores `SIGTERM`, with a child that ignores it too: the
    /// group gets `SIGKILL` after the grace, so the queue is not held.
    func testAGhThatIgnoresSIGTERMIsKilledWithItsGroup() throws {
        try gh.set(mode: "stubborn")
        let started = Date()
        let snapshot = read(makeStatus(timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the 5 s sleep did not run to its end")
        XCTAssertEqual(snapshot.reason, "gh pr list timed out after 20 s")
        let text = try String(contentsOf: gh.directory.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "the script is gone")
        XCTAssertEqual(kill(-pid, 0), -1, "and so is every process of its group, the sleep included")
    }

    /// A child of `gh` keeps the pipes open for 3 s after `gh` exits 0: the
    /// read ends after the grace and the list it printed is the answer.
    func testAChildThatHoldsThePipeDoesNotHoldTheRead() throws {
        try gh.set(mode: "holder")
        let started = Date()
        let snapshot = read(makeStatus(timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the read did not wait for the 3 s child")
        XCTAssertNil(snapshot.reason)
        XCTAssertEqual(snapshot.pulls.map(\.number), [185, 184, 7])
    }

    /// 50 pulls in more than 64 KiB, the pipe's buffer and one read's size.
    func testOutputOverThePipeBufferIsReadWhole() throws {
        let pulls: [[String: Any]] = (1...50).map { number in
            [
                "number": number, "title": String(repeating: "t", count: 4096), "state": "OPEN", "isDraft": false,
                "headRefName": "b\(number)", "mergedAt": NSNull(), "url": "https://github.com/o/r/pull/\(number)",
                "statusCheckRollup": [[String: Any]](), "additions": 1, "deletions": 1,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: pulls)
        XCTAssertGreaterThan(data.count, 3 * 65536)
        try data.write(to: gh.directory.appendingPathComponent("big.json"))
        try gh.set(mode: "big")
        let snapshot = read(makeStatus())
        XCTAssertNil(snapshot.reason)
        XCTAssertEqual(snapshot.pulls.map(\.number), Array(1...50))
        XCTAssertEqual(snapshot.pulls.last?.title.count, 4096)
    }

    func testAFailureKeepsTheLastGoodReadAndItsTime() throws {
        let status = makeStatus()
        let good = read(status)
        try gh.set(mode: "fail")
        clock.advance(60)
        let failed = read(status)
        XCTAssertEqual(failed.pulls, good.pulls)
        XCTAssertEqual(failed.readAt, good.readAt, "the time of the last good read")
        XCTAssertEqual(failed.reason, "gh pr list exited 1: GraphQL: Could not resolve to a Repository")
        try gh.set(mode: "ok")
        clock.advance(60)
        let again = read(status)
        XCTAssertNil(again.reason, "a good read clears the reason")
        XCTAssertGreaterThan(try XCTUnwrap(again.readAt), try XCTUnwrap(good.readAt))
    }

    // MARK: - the one-minute bound

    func testOneReadAMinutePerRepository() {
        let status = makeStatus()
        XCTAssertTrue(status.refreshIfDue(repository: repository))
        PullRequestStatus.queue.sync {}
        for step in [0.0, 1, 29, 29.9] {
            clock.advance(step)
            XCTAssertFalse(status.refreshIfDue(repository: repository), "\(step)")
        }
        XCTAssertEqual(gh.listCalls, 1)
        clock.advance(0.1)
        XCTAssertTrue(status.refreshIfDue(repository: repository), "60 s after the read ended")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.listCalls, 2)
        XCTAssertTrue(status.refreshIfDue(repository: "o/other"), "the bound is per repository")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.listCalls, 3)
    }

    func testAFailedReadIsBoundedToo() throws {
        try gh.set(mode: "fail")
        let status = makeStatus()
        _ = read(status)
        clock.advance(30)
        XCTAssertFalse(status.refreshIfDue(repository: repository))
        XCTAssertEqual(gh.listCalls, 1)
    }

    /// The minute counts from the end of a read: a read that started 100 s
    /// ago and ended now is not due.
    func testTheMinuteCountsFromTheEndOfARead() throws {
        try gh.set(mode: "slow")
        let status = makeStatus(timeout: 0.3)
        XCTAssertTrue(status.refreshIfDue(repository: repository))
        clock.advance(100)
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(status.snapshot(repository: repository).reason, "gh pr list timed out after 20 s")
        XCTAssertFalse(status.refreshIfDue(repository: repository), "due at once under a bound from the start")
        clock.advance(59)
        XCTAssertFalse(status.refreshIfDue(repository: repository))
        clock.advance(1)
        XCTAssertTrue(status.refreshIfDue(repository: repository))
    }

    func testNoSecondReadWhileOneRuns() throws {
        try gh.set(mode: "slow")
        let status = makeStatus(timeout: 0.3)
        XCTAssertTrue(status.refreshIfDue(repository: repository))
        clock.advance(3600)
        XCTAssertFalse(status.refreshIfDue(repository: repository),
                       "a read in flight holds the next one, whatever the clock says")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.listCalls, 1)
    }
}
