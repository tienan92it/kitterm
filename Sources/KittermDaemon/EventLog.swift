import Foundation
import KittermProtocol
import NIOConcurrencyHelpers
import NIOCore

/// One daemon-wide, ordered feed of control-plane events, so a foreman waiting
/// on a dozen crew sessions holds one parked request instead of polling
/// `/api/sessions` N times a second.
///
/// A `note` an agent posts, a session's status change, a spawn, an exit — all
/// arrive here with a monotonic `seq`, and `GET /api/events?since=<seq>` either
/// returns what is newer or parks until it exists (the `/commands/<n>/wait`
/// shape, one loop, no streaming machinery).
///
/// **`NIOLock`-guarded, not loop-confined** — deliberately, and unlike
/// `ApprovalStore`. `SessionRegistry` is an actor that appends lifecycle events
/// from off-loop linger `Task`s, so the append path is not on the event loop;
/// completing a parked `EventLoopPromise` from another thread is
/// NIO-safe (it hops to its own loop). `PtySession.stateLock` is the precedent.
public struct DaemonEvent: Sendable, Equatable {
    public let seq: UInt64
    public let at: Date
    public let type: String
    public let session: UUID?
    /// A small string map — the event's payload, kept JSON-trivial so
    /// serialization on the loop is cheap.
    public let data: [String: String]

    /// The listing shape (`at` as epoch millis, `session` as a string).
    public func asJSON() -> [String: Any] {
        var item: [String: Any] = [
            "seq": seq,
            "at": Int(at.timeIntervalSince1970 * 1000),
            "type": type,
        ]
        if let session { item["session"] = session.uuidString }
        if !data.isEmpty { item["data"] = data }
        return item
    }
}

public final class EventLog: @unchecked Sendable {
    private let lock = NIOLock()
    /// Newest last. Bounded: the oldest is dropped past `capacity`, and
    /// `base` follows so a `since` below it is reported `pruned`.
    private var ring: [DaemonEvent] = []
    private var lastSeq: UInt64 = 0
    /// The oldest seq still retained (0 before anything is dropped).
    private var base: UInt64 = 0
    private let capacity: Int

    private struct Waiter {
        let id: UInt64
        let since: UInt64
        let session: UUID?
        let promise: EventLoopPromise<Void>
    }
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    private let maxWaiters: Int

    public init(
        capacity: Int = KittermConstants.eventLogCapacity,
        maxWaiters: Int = KittermConstants.eventLogMaxWaiters
    ) {
        self.capacity = capacity
        self.maxWaiters = maxWaiters
    }

    /// Append an event and wake every waiter it satisfies. The promises are
    /// completed outside the lock — a waiter's `whenComplete` re-enters this
    /// class to read the events it was waiting for.
    func append(type: String, session: UUID?, data: [String: String] = [:]) {
        let ready: [EventLoopPromise<Void>] = lock.withLock {
            lastSeq += 1
            let event = DaemonEvent(
                seq: lastSeq,
                at: Date(),
                type: type,
                session: session,
                data: data
            )
            ring.append(event)
            if base == 0 { base = event.seq }
            if ring.count > capacity {
                ring.removeFirst(ring.count - capacity)
                base = ring.first?.seq ?? lastSeq
            }
            // A waiter fires when an event newer than its cursor arrives — and,
            // when it filtered by session, only for that session's events.
            var fired: [EventLoopPromise<Void>] = []
            waiters.removeAll { waiter in
                guard event.seq > waiter.since else { return false }
                if let want = waiter.session, want != session { return false }
                fired.append(waiter.promise)
                return true
            }
            return fired
        }
        for promise in ready { promise.succeed(()) }
    }

    /// Events newer than `since` (optionally for one session), the next cursor
    /// to poll with, and whether `since` had aged out of the ring.
    func snapshot(since: UInt64, session: UUID?) -> (events: [DaemonEvent], next: UInt64, pruned: Bool) {
        lock.withLock { snapshotLocked(since: since, session: session) }
    }

    /// Caller holds `lock`.
    private func snapshotLocked(since: UInt64, session: UUID?) -> (events: [DaemonEvent], next: UInt64, pruned: Bool) {
        // Retained events are seq in [base, lastSeq]. The caller missed some
        // when the next one it wants, `since + 1`, has already been dropped —
        // i.e. `since < base - 1`. `base > 1` means eviction has actually
        // happened (an un-evicted log's base is its first seq, 1).
        let pruned = base > 1 && since < base - 1
        var events = ring.filter { $0.seq > since }
        if let session {
            events = events.filter { $0.session == session }
        }
        return (events, lastSeq, pruned)
    }

    enum PollOutcome {
        /// Something to return now: newer events, a pruned cursor, or a cursor
        /// already past the head (answered with no events and the true `next`
        /// so the caller corrects itself instead of parking to its deadline).
        case ready(events: [DaemonEvent], next: UInt64, pruned: Bool)
        /// Parked; the future completes when a matching event is appended.
        case waiting(id: UInt64, future: EventLoopFuture<Void>)
        /// At the waiter ceiling — the route answers 503.
        case tooManyWaiters
    }

    /// Read-or-park under **one** lock acquisition. Checking readiness and
    /// registering the waiter as two separate calls left a gap an off-loop
    /// append (the registry actor's lifecycle events) could land in, parking
    /// a request whose event was already in the ring — the same shape
    /// `PtySession.awaitCommandEnd` guards against.
    func poll(since: UInt64, session: UUID?, on loop: EventLoop) -> PollOutcome {
        lock.withLock {
            let snapshot = snapshotLocked(since: since, session: session)
            if !snapshot.events.isEmpty || snapshot.pruned || since > lastSeq {
                return .ready(events: snapshot.events, next: snapshot.next, pruned: snapshot.pruned)
            }
            guard waiters.count < maxWaiters else { return .tooManyWaiters }
            nextWaiterID += 1
            let id = nextWaiterID
            let promise = loop.makePromise(of: Void.self)
            waiters.append(Waiter(id: id, since: since, session: session, promise: promise))
            return .waiting(id: id, future: promise.futureResult)
        }
    }

    /// Give up on a parked poll (its deadline passed). Completing the promise —
    /// not dropping it — is required: NIO traps an uncompleted promise, and the
    /// caller answers from `snapshot` either way.
    func expire(id: UInt64) {
        let promise: EventLoopPromise<Void>? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index).promise
        }
        promise?.succeed(())
    }

    var waiterCount: Int { lock.withLock { waiters.count } }
}
