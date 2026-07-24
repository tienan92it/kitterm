import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// Mark-derived session state — the fleet view's "running / idle / waiting".
final class SessionStateTests: XCTestCase {
    private func mark(_ kind: MarkKind, exit: Int32? = nil, command: String? = nil, offset: UInt64 = 0) -> SessionMark {
        SessionMark(offset: offset, kind: kind, exit: exit, command: command)
    }

    func testNoMarksIsUnknown() {
        let d = DerivedSessionState.derive(from: [])
        XCTAssertEqual(d.state, .unknown)
        XCTAssertNil(d.lastCommand)
        XCTAssertNil(d.lastExit)
    }

    func testRunningWhenPreExecHasNoCommandEnd() {
        let d = DerivedSessionState.derive(from: [
            mark(.promptStart),
            mark(.commandStart),
            mark(.preExec, command: "sleep 30"),
        ])
        XCTAssertEqual(d.state, .running)
        XCTAssertEqual(d.lastCommand, "sleep 30")
        XCTAssertNil(d.lastExit)
    }

    func testIdleAfterCommandFinishes() {
        let d = DerivedSessionState.derive(from: [
            mark(.preExec, command: "ls"),
            mark(.commandEnd, exit: 0),
            mark(.promptStart),
        ])
        XCTAssertEqual(d.state, .idle)
        XCTAssertEqual(d.lastCommand, "ls")
        XCTAssertEqual(d.lastExit, 0)
    }

    func testLastExitReflectsMostRecentFailure() {
        let d = DerivedSessionState.derive(from: [
            mark(.preExec, command: "true"),
            mark(.commandEnd, exit: 0),
            mark(.preExec, command: "false"),
            mark(.commandEnd, exit: 1),
        ])
        XCTAssertEqual(d.state, .idle)
        XCTAssertEqual(d.lastCommand, "false")
        XCTAssertEqual(d.lastExit, 1)
    }

    func testRunningAgainAfterAPriorCommandFinished() {
        let d = DerivedSessionState.derive(from: [
            mark(.preExec, command: "true"),
            mark(.commandEnd, exit: 0),
            mark(.preExec, command: "npm run build"),
        ])
        XCTAssertEqual(d.state, .running)
        XCTAssertEqual(d.lastCommand, "npm run build")
        // The last finished command's exit is still reported for context.
        XCTAssertEqual(d.lastExit, 0)
    }

    func testPromptOnlyIsIdle() {
        let d = DerivedSessionState.derive(from: [mark(.promptStart)])
        XCTAssertEqual(d.state, .idle)
    }
}
