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

    func testSessionsAreIndependent(){
        let handoff = ControlHandoff()
        let a = UUID()
        let b = UUID()
        handoff.setController(a) {}
        XCTAssertNil(handoff.takeStepDown(b))
        XCTAssertNotNil(handoff.takeStepDown(a))
    }
}
