import Foundation
import XCTest

@testable import KittermDaemon

/// `pr` is a key the goal loop reserves (`docs/goals/LOOP.md`, Labels): the
/// foreman sets `pr:<N>` on a crew session from the pull request it opened
/// before the crew started (`foreman-flow` round 1).
final class SessionLabelsPullRequestKeyTests: XCTestCase {
    func testPrIsAReservedKey() {
        XCTAssertEqual(SessionLabels.prKey, "pr")
        let reserved = [SessionLabels.projectKey, SessionLabels.goalKey, SessionLabels.roundKey, SessionLabels.prKey]
        XCTAssertEqual(Set(reserved).count, reserved.count, "one key per reserved name")
    }

    func testPrKeyPassesValidation() {
        XCTAssertTrue(SessionLabels.isValidKey(SessionLabels.prKey))
        XCTAssertTrue(SessionLabels.isValidValue("176"))
        XCTAssertTrue(SessionLabels.isValidFilter("\(SessionLabels.prKey):176"))
    }

    /// The label as the foreman spawns it, beside the round's other labels.
    func testPrLabelParsesAndFilters() {
        let labels = SessionLabels.parse("crew:foreman-flow,goal:foreman-flow,round:1,task:the-pr-opens-first,pr:176")
        XCTAssertEqual(labels[SessionLabels.prKey], "176")
        XCTAssertTrue(labels.matches(filter: "pr:176"))
        XCTAssertFalse(labels.matches(filter: "pr:175"))
    }
}
