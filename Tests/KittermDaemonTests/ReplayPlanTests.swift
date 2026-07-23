import KittermProtocol
import XCTest

@testable import KittermDaemon

/// `WebSocketSessionHandler.resolveReplay` decides how a controller's screen is
/// rebuilt on attach. The one case worth pinning is a fresh shell spawned
/// because a requested session was gone (a daemon restart): the client's stale
/// `since` offset must be ignored and a resync forced, or a mid-stream slice of
/// the new shell gets spliced onto the old screen — the garbled-input regression
/// these tests guard against.
final class ReplayPlanTests: XCTestCase {
    func testRestartRespawnIgnoresSinceOffsetAndForcesResync() {
        // Reattach requested (old session id + since offset), but the daemon
        // spawned a new shell in its place.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshlySpawned: true,
            reattaching: true,
            sinceOffset: 4096,
            freshClient: false
        )
        XCTAssertEqual(plan.request, .fromDetachPoint)
        XCTAssertTrue(plan.forceResync)
    }

    func testBrandNewTabReplaysFromStartWithoutForcedResync() {
        // A new tab: fresh spawn, no reattach. Its terminal is already empty,
        // so nothing to resync, and there is no offset to honor.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshlySpawned: true,
            reattaching: false,
            sinceOffset: nil,
            freshClient: true
        )
        XCTAssertEqual(plan.request, .fromDetachPoint)
        XCTAssertFalse(plan.forceResync)
    }

    func testLiveReattachHonorsSinceOffset() {
        // Transient disconnect (sleep/wake, reload): the session is still alive,
        // so the client's offset drives an exact gap replay.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshlySpawned: false,
            reattaching: true,
            sinceOffset: 4096,
            freshClient: false
        )
        XCTAssertEqual(plan.request, .sinceOffset(4096))
        XCTAssertFalse(plan.forceResync)
    }

    func testFreshClientReattachReplaysTail() {
        // Reload with no screen state and no counted offset: replay the tail.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshlySpawned: false,
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

    func testOfflessReattachReplaysFromDetachPoint() {
        // Old client: no offset, no fresh flag — replay the detach-point gap.
        let plan = WebSocketSessionHandler.resolveReplay(
            freshlySpawned: false,
            reattaching: true,
            sinceOffset: nil,
            freshClient: false
        )
        XCTAssertEqual(plan.request, .fromDetachPoint)
        XCTAssertFalse(plan.forceResync)
    }
}
