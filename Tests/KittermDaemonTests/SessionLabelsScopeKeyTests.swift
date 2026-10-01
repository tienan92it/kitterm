import Foundation
import XCTest

@testable import KittermDaemon

/// `scope` is a key the goal loop reserves (`docs/goals/LOOP.md`, Labels):
/// the foreman sets `scope:<path>` on its own pane, so `kitterm foreman
/// catch-up` and a fresh foreman can read the scope back from the label
/// (`foreman-scope` round 3). The pattern follows
/// `SessionLabelsPullRequestKeyTests`, written for `pr` in `foreman-flow`
/// round 1.
final class SessionLabelsScopeKeyTests: XCTestCase {
    func testScopeIsAReservedKey() {
        XCTAssertEqual(SessionLabels.scopeKey, "scope")
        let reserved = [
            SessionLabels.projectKey, SessionLabels.goalKey, SessionLabels.roundKey,
            SessionLabels.prKey, SessionLabels.scopeKey,
        ]
        XCTAssertEqual(Set(reserved).count, reserved.count, "one key per reserved name")
    }

    func testScopeKeyPassesValidation() {
        XCTAssertTrue(SessionLabels.isValidKey(SessionLabels.scopeKey))
        XCTAssertTrue(SessionLabels.isValidValue("/Users/antran/Workspace/kitterm"))
        XCTAssertTrue(SessionLabels.isValidFilter("\(SessionLabels.scopeKey):/Users/antran/Workspace/kitterm"))
    }

    /// The label as the foreman sets it on its own pane, beside `crew:foreman`.
    func testScopeLabelParsesAndFilters() {
        let labels = SessionLabels.parse("crew:foreman,scope:/Users/antran/Workspace/kitterm")
        XCTAssertEqual(labels[SessionLabels.scopeKey], "/Users/antran/Workspace/kitterm")
        XCTAssertTrue(labels.matches(filter: "scope:/Users/antran/Workspace/kitterm"))
        XCTAssertFalse(labels.matches(filter: "scope:/Users/antran/Workspace/NgheNhanTrading"))
    }
}
