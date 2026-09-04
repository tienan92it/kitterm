import Foundation
import KittermProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest

@testable import KittermDaemon

/// The daemon-wide event feed and its long-poll: immediate reads, parking,
/// the pruned flag when a cursor ages out, the session filter, and the waiter
/// ceiling.
final class EventLogTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDownWithError() throws {
        try? group.syncShutdownGracefully()
    }

    private var loop: EventLoop { group.next() }

    func testAppendAssignsMonotonicSeq() {
        let log = EventLog()
        log.append(type: "a", session: nil)
        log.append(type: "b", session: nil)
        let snap = log.snapshot(since: 0, session: nil)
        XCTAssertEqual(snap.events.map(\.seq), [1, 2])
        XCTAssertEqual(snap.next, 2)
        XCTAssertFalse(snap.pruned)
    }

    func testSnapshotReturnsOnlyNewerThanCursor() {
        let log = EventLog()
        for _ in 0..<5 { log.append(type: "e", session: nil) }
        let snap = log.snapshot(since: 3, session: nil)
        XCTAssertEqual(snap.events.map(\.seq), [4, 5])
    }

    func testSessionFilterNarrowsTheFeed() {
        let log = EventLog()
        let a = UUID()
        let b = UUID()
        log.append(type: "x", session: a)
        log.append(type: "x", session: b)
        log.append(type: "x", session: a)
        let onlyA = log.snapshot(since: 0, session: a)
        XCTAssertEqual(onlyA.events.map(\.seq), [1, 3])
        // `next` is the global cursor, so a filtered poll still advances past
        // events it did not return.
        XCTAssertEqual(onlyA.next, 3)
    }

    func testPrunedWhenCursorAgedOut() {
        let log = EventLog(capacity: 4)
        for _ in 0..<10 { log.append(type: "e", session: nil) }
        // Only seq 7..10 remain; a caller still at seq 2 missed 3..6.
        let stale = log.snapshot(since: 2, session: nil)
        XCTAssertTrue(stale.pruned, "a cursor below the retained window is pruned")
        // A caller at the window edge is not pruned.
        let edge = log.snapshot(since: 6, session: nil)
        XCTAssertFalse(edge.pruned)
        XCTAssertEqual(edge.events.map(\.seq), [7, 8, 9, 10])
    }

    /// Set from the future's own loop when it completes, read from the test
    /// thread after a beat — the happens-before is the `Thread.sleep`.
    private func completionFlag(_ future: EventLoopFuture<Void>) -> NIOLockedValueBox<Bool> {
        let box = NIOLockedValueBox(false)
        future.whenComplete { _ in box.withLockedValue { $0 = true } }
        return box
    }

    func testRegisterWakesOnAMatchingAppend() throws {
        let log = EventLog()
        guard case .waiting(_, let future) = log.poll(since: 0, session: nil, on: loop) else {
            return XCTFail("an empty log parks the poll")
        }
        let done = completionFlag(future)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(done.withLockedValue { $0 }, "a waiter with no matching event stays parked")

        log.append(type: "wake", session: nil)
        try future.wait()  // completes, or this hangs the test
        let snap = log.snapshot(since: 0, session: nil)
        XCTAssertEqual(snap.events.first?.type, "wake")
    }

    func testWaiterOnlyWakesForItsSession() throws {
        let log = EventLog()
        let want = UUID()
        guard case .waiting(_, let future) = log.poll(since: 0, session: want, on: loop) else {
            return XCTFail("an empty log parks the poll")
        }
        let done = completionFlag(future)

        // An event for another session must not wake it.
        log.append(type: "other", session: UUID())
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(done.withLockedValue { $0 }, "a filtered waiter ignores other sessions")

        log.append(type: "mine", session: want)
        try future.wait()
    }

    func testWaiterCeiling() {
        let log = EventLog(maxWaiters: 2)
        guard case .waiting = log.poll(since: 0, session: nil, on: loop),
              case .waiting = log.poll(since: 0, session: nil, on: loop)
        else { return XCTFail("two waiters fit under the ceiling") }
        guard case .tooManyWaiters = log.poll(since: 0, session: nil, on: loop) else {
            return XCTFail("past the ceiling, the poll is refused so the route can 503")
        }
        // Complete the parked promises so NIO does not trap a leak.
        log.append(type: "drain", session: nil)
    }

    /// The read-or-park race: an event appended *between* a snapshot and a
    /// register used to park a request whose event was already in the ring.
    /// One lock acquisition makes that gap impossible — a cursor with newer
    /// events answers `.ready`, never `.waiting`.
    func testPollWithNewerEventsIsReadyNotWaiting() {
        let log = EventLog()
        log.append(type: "already-here", session: nil)
        guard case .ready(let events, let next, _) = log.poll(since: 0, session: nil, on: loop) else {
            return XCTFail("existing events must answer at once")
        }
        XCTAssertEqual(events.map(\.type), ["already-here"])
        XCTAssertEqual(next, 1)
    }

    /// A cursor past the head answers now, instead of parking to its deadline
    /// — the one way an any-grade caller could tie up a waiter slot with a
    /// request nothing will ever satisfy. This daemon never issued such a
    /// cursor, so it comes from an earlier daemon process: the caller is
    /// told `pruned` and reads this epoch from its start.
    func testCursorPastHeadIsPrunedAndReadsFromTheStart() {
        let log = EventLog()
        log.append(type: "e", session: nil)
        guard case .ready(let events, let next, let pruned) = log.poll(since: 999, session: nil, on: loop) else {
            return XCTFail("a cursor past the head must not park")
        }
        XCTAssertEqual(events.map(\.type), ["e"], "the caller missed this epoch's events; it gets them")
        XCTAssertEqual(next, 1, "the caller learns the real head and corrects itself")
        XCTAssertTrue(pruned, "a cursor this daemon never issued is a stale one")
        XCTAssertEqual(log.waiterCount, 0)
    }

    /// `markStarted` is the first event of an epoch and names it, so a
    /// foreman reading from a stale cursor sees the restart before any
    /// session it might still find.
    func testMarkStartedIsTheFirstEventAndCarriesTheEpoch() {
        let log = EventLog(epoch: "abc")
        log.markStarted(version: "0.0.0", pid: 42)
        log.append(type: "session.created", session: UUID())
        let snap = log.snapshot(since: 0, session: nil)
        XCTAssertEqual(snap.events.first?.type, "daemon.started")
        XCTAssertEqual(snap.events.first?.data["epoch"], "abc")
        XCTAssertEqual(snap.events.first?.data["version"], "0.0.0")
        XCTAssertEqual(snap.events.first?.data["pid"], "42")
        XCTAssertEqual(log.epoch, "abc")
    }

    /// A caller that sends the epoch it last saw is answered `pruned` the
    /// moment it no longer matches — even when its seq happens to fit inside
    /// the new daemon's ring, which a bare `since` could not detect.
    func testForeignEpochIsPrunedAndReadsFromTheStart() {
        let log = EventLog(epoch: "new")
        log.markStarted(version: "0.0.0", pid: 1)
        for _ in 0..<5 { log.append(type: "e", session: nil) }
        // A cursor of 3 from the old daemon fits inside [1, 6] here.
        let stale = log.snapshot(since: 3, epoch: "old", session: nil)
        XCTAssertTrue(stale.pruned)
        XCTAssertEqual(stale.events.first?.type, "daemon.started")
        XCTAssertEqual(stale.events.count, 6, "everything in this epoch, not just seq > 3")
        XCTAssertEqual(stale.next, 6)
        // The same cursor with the right epoch reads normally.
        let current = log.snapshot(since: 3, epoch: "new", session: nil)
        XCTAssertFalse(current.pruned)
        XCTAssertEqual(current.events.map(\.seq), [4, 5, 6])
        // A foreign epoch never parks, even on an otherwise quiet log.
        guard case .ready(_, _, let pruned) = log.poll(since: 6, epoch: "old", session: nil, on: loop) else {
            return XCTFail("a foreign epoch must answer at once")
        }
        XCTAssertTrue(pruned)
        XCTAssertEqual(log.waiterCount, 0)
    }

    /// Two logs never share an epoch by default: the id is what tells a
    /// restarted daemon from the one before it.
    func testEpochsAreDistinctByDefault() {
        XCTAssertNotEqual(EventLog().epoch, EventLog().epoch)
    }
}
