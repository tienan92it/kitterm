import Foundation
import XCTest

@testable import KittermDaemon

final class ControlHandoffTests: XCTestCase {
    func testTakeRemovesAndReturnsTheStepDown() {
        let handoff = ControlHandoff()
        let id = UUID()
        var stepped = false
        handoff.setController(id) { stepped = true }

        let stepDown = handoff.takeStepDown(id)
        XCTAssertNotNil(stepDown)
        stepDown?()
        XCTAssertTrue(stepped)
        // Removed on take: a second transfer in the same window finds nobody
        // to demote (the requester registers itself next).
        XCTAssertNil(handoff.takeStepDown(id))
    }

    func testTakeWithNoControllerIsNil() {
        XCTAssertNil(ControlHandoff().takeStepDown(UUID()))
    }

    func testClearRemovesTheEntry() {
        let handoff = ControlHandoff()
        let id = UUID()
        handoff.setController(id) {}
        handoff.clearController(id)
        XCTAssertNil(handoff.takeStepDown(id))
    }

    func testReRegisterReplacesTheStepDown() {
        let handoff = ControlHandoff()
        let id = UUID()
        var first = false
        var second = false
        handoff.setController(id) { first = true }
        handoff.setController(id) { second = true }
        handoff.takeStepDown(id)?()
        XCTAssertFalse(first)
        XCTAssertTrue(second)
    }

    /// The property that keeps a takeover's claimControl from being overtaken
    /// by an earlier teardown's markDetached: ops apply in enqueue order even
    /// when an early op is slow.
    func testBookkeepingAppliesInEnqueueOrder() async throws {
        actor Log {
            var order: [Int] = []
            func add(_ n: Int) { order.append(n) }
        }
        let handoff = ControlHandoff()
        let log = Log()
        for i in 0..<20 {
            handoff.enqueueBookkeeping {
                if i == 0 {
                    // The first op stalls; later ops must still wait their turn.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                await log.add(i)
            }
        }
        for _ in 0..<200 {
            if await log.order.count == 20 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let order = await log.order
        XCTAssertEqual(order, Array(0..<20))
    }

    func testSessionsAreIndependent(){
        let handoff = ControlHandoff()
        let a = UUID()
        let b = UUID()
        handoff.setController(a) {}
        XCTAssertNil(handoff.takeStepDown(b))
        XCTAssertNotNil(handoff.takeStepDown(a))
    }
}
