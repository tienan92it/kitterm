import KittermProtocol
import XCTest

@testable import KittermDaemon

/// `WebSocketSessionHandler.resolveReplay` decides how a controller's screen
/// is rebuilt on attach. The case that needs a pin is a fresh shell spawned
/// because the requested session was gone (a daemon restart): the daemon
/// ignores the client's stale `since` offset and forces a resync. Without
/// that, a slice from the middle of the new shell lands on the old screen.
/// `RespawnResyncTests` proves the same rule end to end; these cases pin the
/// decision with no timing.
final class ReplayPlanTests: XCTestCase {
    func testRespawnIgnoresSinceOffsetAndForcesResync() {
        // The request named a session and an offset, and the daemon spawned
        // a new shell in its place.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshShell: true,
            reattaching: true,
            sinceOffset: 4096,
            freshClient: false
        )
        XCTAssertEqual(plan.request, .fromDetachPoint)
        XCTAssertTrue(plan.forceResync)
    }

    func testRespawnOfAFreshClientForcesResyncToo() {
        // A reload after a restart: no offset, no screen state. The replay
        // is the new shell from its first byte, not a tail.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshShell: true,
            reattaching: true,
            sinceOffset: nil,
            freshClient: true
        )
        XCTAssertEqual(plan.request, .fromDetachPoint)
        XCTAssertTrue(plan.forceResync)
    }

    func testNewTabReplaysFromStartWithoutForcedResync() {
        // A new tab: fresh spawn, no session in the request. Its terminal is
        // empty, so the daemon forces no resync.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshShell: true,
            reattaching: false,
            sinceOffset: nil,
            freshClient: true
        )
        XCTAssertEqual(plan.request, .fromDetachPoint)
        XCTAssertFalse(plan.forceResync)
    }

    func testNewTabWithASinceOffsetIgnoresIt() {
        // A fresh spawn with no session in the request and an offset: the
        // offset counts no stream of this shell, and the screen is empty.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshShell: true,
            reattaching: false,
            sinceOffset: 4096,
            freshClient: false
        )
        XCTAssertEqual(plan.request, .fromDetachPoint)
        XCTAssertFalse(plan.forceResync)
    }

    func testLiveReattachHonoursSinceOffset() {
        // Transient disconnect (sleep/wake, reload): the session is alive,
        // so the client's offset drives an exact gap replay.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshShell: false,
            reattaching: true,
            sinceOffset: 4096,
            freshClient: false
        )
        XCTAssertEqual(plan.request, .sinceOffset(4096))
        XCTAssertFalse(plan.forceResync)
    }

    func testLiveReattachPrefersSinceOffsetOverFresh() {
        let plan = WebSocketSessionHandler.resolveReplay(
            freshShell: false,
            reattaching: true,
            sinceOffset: 0,
            freshClient: true
        )
        XCTAssertEqual(plan.request, .sinceOffset(0))
        XCTAssertFalse(plan.forceResync)
    }

    func testFreshClientReattachReplaysTail() {
        // A reload with no screen state and no counted offset: the tail. The
        // handler sends resync for a tail replay itself.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshShell: false,
            reattaching: true,
            sinceOffset: nil,
            freshClient: true
        )
        XCTAssertEqual(
            plan.request,
            .tail(maxBytes: KittermConstants.sessionObserverReplayMaxBytes)
        )
        XCTAssertFalse(plan.forceResync)
    }

    func testReattachWithNoOffsetReplaysFromDetachPoint() {
        // An old client: no offset, no fresh flag. The detach-point gap.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshShell: false,
            reattaching: true,
            sinceOffset: nil,
            freshClient: false
        )
        XCTAssertEqual(plan.request, .fromDetachPoint)
        XCTAssertFalse(plan.forceResync)
    }
}
