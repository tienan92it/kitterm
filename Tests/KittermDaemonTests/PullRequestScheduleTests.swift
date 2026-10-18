import Foundation
import NIOConcurrencyHelpers
import XCTest

@testable import KittermDaemon

/// The adaptive schedule of `PullRequestStatus` (`sessions-workflow` round
/// 8, `corpus/03-faster-pull-sync.md`): the interval from a repository's
/// open work, the nudge rules, the daemon-wide ceiling, and `pulls.changed`
/// on the event feed. The clock and the scheduler are fakes; the `gh` is a
/// closure, so no process runs.
final class PullRequestScheduleTests: XCTestCase {
    private var gh: FakeGH!
    private var clock: TestClock!
    private var scheduled: Scheduled!
    private var runner: FakeRunner!
    private let repository = "o/r"

    /// The delayed work `PullRequestStatus` asked for, fired by hand.
    private final class Scheduled: @unchecked Sendable {
        private let lock = NIOLock()
        private var items: [(delay: TimeInterval, work: @Sendable () -> Void)] = []
        func add(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
            lock.withLock { items.append((delay, work)) }
        }
        var delays: [TimeInterval] { lock.withLock { items.map(\.delay) } }
        var count: Int { lock.withLock { items.count } }
        /// Run and drop the oldest item.
        func fire() {
            let work: (@Sendable () -> Void)? = lock.withLock { items.isEmpty ? nil : items.removeFirst().work }
            work?()
        }
    }

    /// The `gh` as a closure: counts list runs, answers `output`, and blocks
    /// while `hold` is set.
    private final class FakeRunner: @unchecked Sendable {
        private let lock = NIOLock()
        private var listRuns = 0
        private var outputStorage = Data(FakeGH.pulls.utf8)
        private let gate = DispatchSemaphore(value: 0)
        private var holding = false

        var listCalls: Int { lock.withLock { listRuns } }
        var output: Data {
            get { lock.withLock { outputStorage } }
            set { lock.withLock { outputStorage = newValue } }
        }
        func hold() { lock.withLock { holding = true } }
        func release() {
            lock.withLock { holding = false }
            gate.signal()
        }
        func run(_ executable: String, _ args: [String], _ keepOutput: Bool) -> PullRequestStatus.RunResult? {
            guard args.first == "pr" else { return PullRequestStatus.RunResult(status: 0) }
            let wait: Bool = lock.withLock {
                listRuns += 1
                return holding
            }
            if wait { gate.wait() }
            return PullRequestStatus.RunResult(status: 0, output: output)
        }
    }

    override func setUpWithError() throws {
        gh = try FakeGH()
        clock = TestClock()
        scheduled = Scheduled()
        runner = FakeRunner()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: gh.directory)
    }

    private func makeStatus(eventLog: EventLog? = nil) -> PullRequestStatus {
        let clock = self.clock!, scheduled = self.scheduled!, runner = self.runner!
        return PullRequestStatus(
            searchPath: gh.searchPath, run: { runner.run($0, $1, $2) }, clock: { clock.now },
            schedule: { scheduled.add($0, $1) }, eventLog: eventLog
        )
    }

    private func pulls(_ json: String) -> Data { Data(json.utf8) }

    /// One open pull request with no check, updated long ago.
    private let quiet = """
        [{"number":10,"state":"OPEN","isDraft":false,"headRefName":"x","url":"u","title":"t",
          "updatedAt":"2026-01-01T00:00:00Z","statusCheckRollup":[],"additions":1,"deletions":1}]
        """
    private let merged = """
        [{"number":10,"state":"MERGED","isDraft":false,"headRefName":"x","url":"u","title":"t",
          "mergedAt":"2026-01-02T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","statusCheckRollup":[],"additions":1,"deletions":1}]
        """

    // MARK: - the interval

    func testTheIntervalFromEachSignOfOpenWork() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let idle = PullRequestStatus.Activity(openNumbers: [10])
        XCTAssertEqual(PullRequestStatus.interval(activity: idle, labelledPulls: [], now: now), 180)
        XCTAssertEqual(PullRequestStatus.interval(activity: PullRequestStatus.Activity(), labelledPulls: [10], now: now), 180, "no pull at all")
        let pending = PullRequestStatus.Activity(pendingCI: true, openNumbers: [10])
        XCTAssertEqual(PullRequestStatus.interval(activity: pending, labelledPulls: [], now: now), 15, "a check runs")
        let recent = PullRequestStatus.Activity(lastUpdatedAt: now.addingTimeInterval(-299), openNumbers: [10])
        XCTAssertEqual(PullRequestStatus.interval(activity: recent, labelledPulls: [], now: now), 15, "changed inside 5 min")
        let stale = PullRequestStatus.Activity(lastUpdatedAt: now.addingTimeInterval(-301), openNumbers: [10])
        XCTAssertEqual(PullRequestStatus.interval(activity: stale, labelledPulls: [], now: now), 180)
        XCTAssertEqual(PullRequestStatus.interval(activity: idle, labelledPulls: [10], now: now), 15, "a live session labels an open one")
        XCTAssertEqual(PullRequestStatus.interval(activity: idle, labelledPulls: [11, 12], now: now), 180, "the labels name no open one")
        XCTAssertEqual(PullRequestStatus.activeSeconds, 15)
        XCTAssertEqual(PullRequestStatus.idleSeconds, 180)
    }

    func testActivityOfAList() throws {
        let list = try XCTUnwrap(PullRequestStatus.parse(Data(FakeGH.pulls.utf8)))
        let activity = PullRequestStatus.Activity.of(pulls: list)
        XCTAssertTrue(activity.pendingCI, "185 has a check in progress")
        XCTAssertEqual(activity.openNumbers, [185], "184 merged, 7 closed")
        XCTAssertEqual(activity.lastUpdatedAt, PullRequestStatus.date(iso8601: "2026-10-05T18:34:00Z"))
        XCTAssertEqual(PullRequestStatus.Activity.of(pulls: []), PullRequestStatus.Activity())
        let mergedList = try XCTUnwrap(PullRequestStatus.parse(pulls(merged)))
        XCTAssertFalse(PullRequestStatus.Activity.of(pulls: mergedList).pendingCI)
        XCTAssertEqual(PullRequestStatus.Activity.of(pulls: mergedList).openNumbers, [])
    }

    func testTheGhTime() {
        XCTAssertEqual(PullRequestStatus.date(iso8601: "2026-10-06T08:10:36Z")?.timeIntervalSince1970, 1_791_274_236)
        XCTAssertEqual(PullRequestStatus.date(iso8601: "1970-01-01T00:00:00Z")?.timeIntervalSince1970, 0)
        XCTAssertEqual(PullRequestStatus.date(iso8601: "2026-10-06T08:10:36.123Z")?.timeIntervalSince1970, 1_791_274_236)
        for bad in ["", "2026-10-06", "2026-10-06T08:10:36", "2026-10-06 08:10:36Z", "yesterday", "2026-10-06T08:10:36+07:00"] {
            XCTAssertNil(PullRequestStatus.date(iso8601: bad), bad)
        }
    }

    func testRefreshIfDueReadsAtTheInterval() {
        runner.output = pulls(quiet)
        let status = makeStatus()
        XCTAssertTrue(status.refreshIfDue(repository: repository))
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 1)
        XCTAssertEqual(status.interval(repository: repository), 180)
        clock.advance(179)
        XCTAssertFalse(status.refreshIfDue(repository: repository), "idle: inside 180 s")
        clock.advance(1)
        runner.output = Data(FakeGH.pulls.utf8)
        XCTAssertTrue(status.refreshIfDue(repository: repository))
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 2)
        XCTAssertEqual(status.interval(repository: repository), 15, "the new list has a check running")
        clock.advance(14)
        XCTAssertFalse(status.refreshIfDue(repository: repository))
        clock.advance(1)
        XCTAssertTrue(status.refreshIfDue(repository: repository))
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 3)
    }

    func testTheLabelsHandedWithARequestDecideTheInterval() {
        runner.output = pulls(quiet)
        let status = makeStatus()
        status.refreshIfDue(repository: repository, project: "hub", labelledPulls: [])
        PullRequestStatus.queue.sync {}
        clock.advance(10)
        XCTAssertFalse(status.refreshIfDue(repository: repository, project: "hub", labelledPulls: [10]), "the labels are taken, the read is not due yet: 10 s since it ended")
        XCTAssertEqual(status.interval(repository: repository), 15)
        XCTAssertFalse(status.refreshIfDue(repository: repository, project: "hub", labelledPulls: nil), "nil keeps the labels")
        XCTAssertEqual(status.interval(repository: repository), 15)
        XCTAssertFalse(status.refreshIfDue(repository: repository, project: "hub", labelledPulls: [99]))
        XCTAssertEqual(status.interval(repository: repository), 180, "a label on a number that is not open")
    }

    // MARK: - the nudge

    func testANudgeReadsAtOnceAndKeepsTheGap() {
        let status = makeStatus()
        status.nudge(repository: repository)
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 1, "nothing read yet: at once")
        XCTAssertEqual(scheduled.count, 0)
        clock.advance(2)
        status.nudge(repository: repository)
        XCTAssertEqual(runner.listCalls, 1)
        XCTAssertEqual(scheduled.delays, [3], "the gap since the last start: 5 s less the 2 s gone")
        status.nudge(repository: repository)
        XCTAssertEqual(scheduled.count, 1, "a nudge while one waits changes nothing")
        XCTAssertFalse(status.refreshIfDue(repository: repository), "a claimed read holds the schedule")
        clock.advance(3)
        scheduled.fire()
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 2)
        clock.advance(6)
        status.nudge(repository: repository)
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 3, "past the gap: at once")
        XCTAssertEqual(scheduled.count, 0)
    }

    func testANudgeWhileAReadRunsQueuesExactlyOne() {
        let status = makeStatus()
        runner.hold()
        status.nudge(repository: repository)
        // Wait until the read holds the gate.
        let deadline = Date().addingTimeInterval(5)
        while runner.listCalls < 1, Date() < deadline { usleep(5_000) }
        XCTAssertEqual(runner.listCalls, 1)
        status.nudge(repository: repository)
        status.nudge(repository: repository)
        status.nudge(repository: repository)
        XCTAssertFalse(status.refreshIfDue(repository: repository))
        clock.advance(1)
        runner.release()
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 1, "the queued read waits for the gap")
        XCTAssertEqual(scheduled.delays, [4])
        clock.advance(4)
        scheduled.fire()
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 2, "one more read, not three")
        XCTAssertEqual(scheduled.count, 0)
        status.nudge(repository: "o/other")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 3, "the gap is per repository")
    }

    // MARK: - the ceiling

    func testAtMost24ReadsAMinuteDaemonWide() {
        let status = makeStatus()
        for index in 0..<24 {
            XCTAssertTrue(status.refreshIfDue(repository: "o/r\(index)"))
            clock.advance(1)
        }
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 24)
        XCTAssertTrue(status.refreshIfDue(repository: repository), "claimed")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 24, "the 25th waits")
        XCTAssertEqual(scheduled.delays, [36], "the slot opens a minute after the oldest start, 24 s ago")
        status.nudge(repository: "o/r0")
        XCTAssertEqual(scheduled.count, 2, "a nudge waits too")
        XCTAssertEqual(scheduled.delays[1], 36)
        clock.advance(36)
        scheduled.fire()
        scheduled.fire()
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 25, "one slot opened; the nudge waits again")
        XCTAssertEqual(scheduled.delays, [1])
        clock.advance(1)
        scheduled.fire()
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 26)
        XCTAssertEqual(PullRequestStatus.readsPerMinute, 24)
    }

    // MARK: - pulls.changed

    func testPullsChangedOnAChangedAnswerOnly() {
        let log = EventLog()
        let status = makeStatus(eventLog: log)
        func events() -> [DaemonEvent] { log.snapshot(since: 0, session: nil).events.filter { $0.type == "pulls.changed" } }
        status.refreshIfDue(repository: repository, project: "hub")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(events().map(\.data), [["project": "hub"]], "not read yet, then a list: a change")
        clock.advance(200)
        status.refreshIfDue(repository: repository, project: "hub")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 2)
        XCTAssertEqual(events().count, 1, "the same list again is no change")
        runner.output = pulls(merged)
        clock.advance(200)
        status.refreshIfDue(repository: repository, project: "hub")
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(events().count, 2)
        XCTAssertEqual(events().last?.data, ["project": "hub"])
        XCTAssertNil(events().last?.session)
    }

    func testEveryProjectThatAskedForTheRepositoryIsNamed() {
        let log = EventLog()
        let status = makeStatus(eventLog: log)
        status.refreshIfDue(repository: repository, project: "hub")
        PullRequestStatus.queue.sync {}
        clock.advance(200)
        status.refreshIfDue(repository: repository, project: "twin")
        runner.output = pulls(merged)
        PullRequestStatus.queue.sync {}
        clock.advance(200)
        status.refreshIfDue(repository: repository, project: "hub")
        PullRequestStatus.queue.sync {}
        let projects = log.snapshot(since: 0, session: nil).events.filter { $0.type == "pulls.changed" }.map { $0.data["project"] }
        XCTAssertEqual(projects, ["hub", "hub", "twin"], "the first read names hub; the changed one names both, sorted")
    }

    func testAFailedReadThatKeepsTheListIsAChangeOnce() {
        let log = EventLog()
        let runner = self.runner!
        final class Flag: @unchecked Sendable {
            let lock = NIOLock()
            var failing = false
        }
        let flag = Flag()
        let status = PullRequestStatus(
            searchPath: gh.searchPath,
            run: { executable, args, keepOutput in
                if flag.lock.withLock({ flag.failing }), args.first == "pr" {
                    _ = runner.run(executable, args, keepOutput)
                    return PullRequestStatus.RunResult(status: 1, error: "boom")
                }
                return runner.run(executable, args, keepOutput)
            },
            clock: { [clock] in clock!.now }, schedule: { [scheduled] in scheduled!.add($0, $1) }, eventLog: log
        )
        status.refreshIfDue(repository: repository, project: "hub")
        PullRequestStatus.queue.sync {}
        flag.lock.withLock { flag.failing = true }
        clock.advance(200)
        status.refreshIfDue(repository: repository, project: "hub")
        PullRequestStatus.queue.sync {}
        clock.advance(200)
        status.refreshIfDue(repository: repository, project: "hub")
        PullRequestStatus.queue.sync {}
        let count = log.snapshot(since: 0, session: nil).events.filter { $0.type == "pulls.changed" }.count
        XCTAssertEqual(count, 2, "the list, then the reason; the same reason again is no change")
        XCTAssertEqual(status.snapshot(repository: repository).reason, "gh pr list exited 1: boom")
    }
}
