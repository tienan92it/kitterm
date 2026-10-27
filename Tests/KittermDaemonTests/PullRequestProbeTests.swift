import Foundation
import NIOConcurrencyHelpers
import XCTest

@testable import KittermDaemon

/// The change probe (`sessions-workflow` round 9,
/// `corpus/04-change-probe.md`): `PullRequestStatus.watch`, `parseProbe`,
/// `probeArguments`, the 5 s cadence, the 30 s watch window, the 60 s
/// back-off and its reset, and that a probe never runs while a list read of
/// the same repository is in flight. `TestClock` and `FakeGH` come from
/// `PullRequestStatusTests.swift`; `gh` is a closure, so no process runs.
final class PullRequestProbeParseTests: XCTestCase {
    func testAStatusLineAndAnETag() {
        let output = "HTTP/2.0 200 OK\r\nDate: Tue, 27 Oct 2026 00:00:00 GMT\r\nETag: \"abc123\"\r\nContent-Type: application/json\r\n\r\n[]"
        let result = PullRequestStatus.parseProbe(Data(output.utf8))
        XCTAssertEqual(result?.status, 200)
        XCTAssertEqual(result?.etag, "\"abc123\"")
    }

    func testA304KeepsItsETagWithNoBody() {
        let output = "HTTP/2.0 304 Not Modified\r\nETag: \"abc123\"\r\n\r\n"
        let result = PullRequestStatus.parseProbe(Data(output.utf8))
        XCTAssertEqual(result?.status, 304)
        XCTAssertEqual(result?.etag, "\"abc123\"")
    }

    func testAWeakETagIsKeptWhole() {
        let output = "HTTP/1.1 200 OK\nETag: W/\"abc\"\n\n[]"
        XCTAssertEqual(PullRequestStatus.parseProbe(Data(output.utf8))?.etag, "W/\"abc\"")
    }

    func testAMissingETagAnswersNilNotAFailure() {
        let output = "HTTP/1.1 200 OK\nContent-Type: application/json\n\n[]"
        let result = PullRequestStatus.parseProbe(Data(output.utf8))
        XCTAssertEqual(result?.status, 200)
        XCTAssertNil(result?.etag)
    }

    func testAnHTTP1Dot1Line() {
        let output = "HTTP/1.1 200 OK\nETag: \"x\"\n\n[]"
        XCTAssertEqual(PullRequestStatus.parseProbe(Data(output.utf8))?.status, 200)
    }

    func testTheHeaderNameIsCaseInsensitive() {
        let output = "HTTP/2.0 200 OK\r\netag: \"x\"\r\n\r\n[]"
        XCTAssertEqual(PullRequestStatus.parseProbe(Data(output.utf8))?.etag, "\"x\"")
    }

    func testNoStatusLineAnswersNil() {
        XCTAssertNil(PullRequestStatus.parseProbe(Data("not an http response".utf8)))
        XCTAssertNil(PullRequestStatus.parseProbe(Data()))
    }

    func testProbeArgumentsWithAndWithoutAnETag() {
        XCTAssertEqual(
            PullRequestStatus.probeArguments(repository: "o/r", etag: nil),
            ["api", "-i", "repos/o/r/pulls?state=all&sort=updated&direction=desc&per_page=5"]
        )
        XCTAssertEqual(
            PullRequestStatus.probeArguments(repository: "o/r", etag: "\"abc\""),
            ["api", "-i", "-H", "If-None-Match: \"abc\"", "repos/o/r/pulls?state=all&sort=updated&direction=desc&per_page=5"]
        )
    }
}

final class PullRequestProbeScheduleTests: XCTestCase {
    private var gh: FakeGH!
    private var clock: TestClock!
    private var probed: Scheduled!
    private var listScheduled: Scheduled!
    private var runner: FakeProbeRunner!
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

    /// `gh` as a closure: `pr list` counts its calls and can hold open
    /// (`holdList`/`releaseList`); `api` answers the queued probe outcomes
    /// in order, a plain `200` with no `ETag` when none is queued.
    private final class FakeProbeRunner: @unchecked Sendable {
        private let lock = NIOLock()
        private var listRuns = 0
        private var probeRuns = 0
        private var probeAnswers: [PullRequestStatus.RunResult] = []
        private let gate = DispatchSemaphore(value: 0)
        private var holding = false

        var listCalls: Int { lock.withLock { listRuns } }
        var probeCalls: Int { lock.withLock { probeRuns } }

        func queueProbe(status: Int, etag: String?) {
            var head = "HTTP/2.0 \(status) \(status == 304 ? "Not Modified" : "OK")\r\n"
            if let etag { head += "ETag: \(etag)\r\n" }
            head += "\r\n[]"
            lock.withLock { probeAnswers.append(PullRequestStatus.RunResult(status: 0, output: Data(head.utf8))) }
        }
        func queueProbeFailure() {
            lock.withLock { probeAnswers.append(PullRequestStatus.RunResult(status: 1, error: "boom")) }
        }
        func hold() { lock.withLock { holding = true } }
        func release() {
            lock.withLock { holding = false }
            gate.signal()
        }

        func list(_ executable: String, _ args: [String], _ keepOutput: Bool) -> PullRequestStatus.RunResult? {
            let wait: Bool = lock.withLock {
                listRuns += 1
                return holding
            }
            if wait { gate.wait() }
            return PullRequestStatus.RunResult(status: 0, output: Data("[]".utf8))
        }

        func probe(_ executable: String, _ args: [String], _ keepOutput: Bool) -> PullRequestStatus.RunResult? {
            lock.withLock {
                probeRuns += 1
                if probeAnswers.isEmpty {
                    return PullRequestStatus.RunResult(status: 0, output: Data("HTTP/2.0 200 OK\r\n\r\n[]".utf8))
                }
                return probeAnswers.removeFirst()
            }
        }
    }

    override func setUpWithError() throws {
        gh = try FakeGH()
        clock = TestClock()
        probed = Scheduled()
        listScheduled = Scheduled()
        runner = FakeProbeRunner()
    }

    override func tearDownWithError() throws {
        // Let a probe or a read still on its queue end before the script goes.
        PullRequestStatus.probeQueue.sync {}
        PullRequestStatus.queue.sync {}
        gh.remove()
    }

    private func makeStatus() -> PullRequestStatus {
        let clock = self.clock!, probed = self.probed!, listScheduled = self.listScheduled!, runner = self.runner!
        return PullRequestStatus(
            searchPath: gh.searchPath,
            run: { runner.list($0, $1, $2) },
            probeRun: { runner.probe($0, $1, $2) },
            clock: { clock.now },
            schedule: { listScheduled.add($0, $1) },
            probeSchedule: { probed.add($0, $1) }
        )
    }

    // MARK: - the schedule

    func testWatchSchedulesAProbeAtFiveSecondsAndKeepsTheCadence() {
        let status = makeStatus()
        status.watch(repository: repository)
        XCTAssertEqual(probed.delays, [5], "the first probe is 5 s out")
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        XCTAssertEqual(runner.probeCalls, 1)
        XCTAssertEqual(probed.delays, [5], "a success (here a plain 200) keeps the 5 s cadence")
    }

    /// `runProbe` always dispatches a tick onto `PullRequestStatus.probeQueue`
    /// (`probeSchedule`'s default); every test above hands it a fake
    /// scheduler instead, so none of them exercises the real queue. This
    /// test does, directly: a repository whose `gh` call blocks must not
    /// delay another repository's tick, because `gh` takes about 0.8 s to
    /// start and a fleet view can watch several repositories at once
    /// (`sessions-workflow` round 9, the foreman's correction). `probeQueue`
    /// is `.concurrent` for exactly this; `probeArmed` is the rule that
    /// still holds a single tick per repository.
    func testProbeQueueRunsTwoRepositoriesConcurrentlySoASlowOneNeverDelaysAnother() {
        let slowStarted = DispatchSemaphore(value: 0)
        let releaseSlow = DispatchSemaphore(value: 0)
        let fastDone = DispatchSemaphore(value: 0)
        PullRequestStatus.probeQueue.async {
            slowStarted.signal()
            releaseSlow.wait()
        }
        XCTAssertEqual(slowStarted.wait(timeout: .now() + 2), .success, "the slow tick claimed a thread")
        PullRequestStatus.probeQueue.async {
            fastDone.signal()
        }
        XCTAssertEqual(
            fastDone.wait(timeout: .now() + 2), .success,
            "a second repository's tick ran while the first still blocks: the queue is concurrent, not serial"
        )
        releaseSlow.signal()
    }

    func testTheWindowStopsTheProbeAfterThirtySecondsWithNoFurtherWatch() {
        let status = makeStatus()
        status.watch(repository: repository)
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        XCTAssertEqual(runner.probeCalls, 2)
        clock.advance(20) // 5 + 5 + 20 = 30 s since watch(): the window just closed
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        XCTAssertEqual(runner.probeCalls, 2, "the window closed before the tick, so no gh call")
        XCTAssertEqual(probed.count, 0, "nothing scheduled again")
    }

    func testWatchingAgainWhileArmedExtendsTheWindowWithoutASecondSchedule() {
        let status = makeStatus()
        status.watch(repository: repository)
        XCTAssertEqual(probed.count, 1)
        clock.advance(1)
        status.watch(repository: repository)
        XCTAssertEqual(probed.count, 1, "already armed: the window just extends, nothing new is scheduled")
    }

    func testAProbeSkipsWithNoGhCallWhileAListReadIsInFlight() {
        let status = makeStatus()
        runner.hold()
        XCTAssertTrue(status.refreshIfDue(repository: repository), "claims the read; its state turns running synchronously")
        status.watch(repository: repository)
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        XCTAssertEqual(runner.probeCalls, 0, "a list read is in flight: the tick is skipped, not run")
        XCTAssertEqual(probed.delays, [5], "it tries again at the same interval")
        runner.release()
        PullRequestStatus.queue.sync {}
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        XCTAssertEqual(runner.probeCalls, 1, "the read ended: the probe runs")
    }

    // MARK: - the back-off and its reset

    func testAFailureBacksOffAndALaterSuccessResetsTheCadence() {
        runner.queueProbeFailure()
        let status = makeStatus()
        status.watch(repository: repository)
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        XCTAssertEqual(runner.probeCalls, 1)
        XCTAssertEqual(probed.delays, [60], "a failure backs the repository off to 60 s")
        clock.advance(60)
        status.watch(repository: repository) // the page keeps asking: the window extends past this tick
        runner.queueProbe(status: 200, etag: "\"a\"")
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        XCTAssertEqual(runner.probeCalls, 2)
        XCTAssertEqual(probed.delays, [5], "a later success resets the 5 s cadence")
    }

    // MARK: - the nudge

    func testTheFirstTwoHundredOnlyStoresTheTagAndDoesNotNudge() {
        runner.queueProbe(status: 200, etag: "\"a\"")
        let status = makeStatus()
        status.watch(repository: repository)
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 0, "the first 200 only stores the tag")
    }

    func testAChangedTagNudgesExactlyOnce() {
        runner.queueProbe(status: 200, etag: "\"a\"")
        runner.queueProbe(status: 200, etag: "\"b\"")
        runner.queueProbe(status: 200, etag: "\"b\"")
        let status = makeStatus()
        status.watch(repository: repository)
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 0)
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 1, "a changed tag starts a list read")
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 1, "the same tag again: no second nudge")
    }

    func testA304OrAnUnchangedTagNeverNudges() {
        runner.queueProbe(status: 200, etag: "\"a\"")
        runner.queueProbe(status: 304, etag: "\"a\"")
        runner.queueProbe(status: 200, etag: "\"a\"")
        let status = makeStatus()
        status.watch(repository: repository)
        for _ in 0..<3 {
            clock.advance(5)
            probed.fire()
            PullRequestStatus.probeQueue.sync {}
        }
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 0, "the tag never changed: never a nudge")
    }

    func testAMissingETagOnA200NeitherStoresNorNudges() {
        runner.queueProbe(status: 200, etag: "\"a\"")
        runner.queueProbe(status: 200, etag: nil)
        runner.queueProbe(status: 200, etag: "\"a\"")
        let status = makeStatus()
        status.watch(repository: repository)
        for _ in 0..<3 {
            clock.advance(5)
            probed.fire()
            PullRequestStatus.probeQueue.sync {}
        }
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 0, "a 200 with no ETag cannot be compared, so it changes nothing")
    }

    // MARK: - the ceiling still bounds a probe's own nudge

    func testAProbeNudgeStillWaitsForASlotUnderTheCeiling() {
        let status = makeStatus()
        for index in 0..<24 {
            XCTAssertTrue(status.refreshIfDue(repository: "o/r\(index)"))
            clock.advance(1)
        }
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 24)
        runner.queueProbe(status: 200, etag: "\"a\"")
        runner.queueProbe(status: 200, etag: "\"b\"")
        status.watch(repository: repository)
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 24, "the first 200 only stores the tag")
        clock.advance(5)
        probed.fire()
        PullRequestStatus.probeQueue.sync {}
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(runner.listCalls, 24, "a changed tag nudges, but the ceiling makes the read wait")
        XCTAssertFalse(listScheduled.delays.isEmpty, "the nudge's read is queued for a slot, not run at once")
    }
}
