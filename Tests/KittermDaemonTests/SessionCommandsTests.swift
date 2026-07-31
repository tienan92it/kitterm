import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// Pairing marks into command output ranges for the agent-facing API.
final class SessionCommandsTests: XCTestCase {
    private func mark(_ kind: MarkKind, offset: UInt64, exit: Int32? = nil, command: String? = nil) -> SessionMark {
        SessionMark(offset: offset, kind: kind, exit: exit, command: command)
    }

    func testNoMarksIsEmpty() {
        XCTAssertTrue(SessionCommands.pair(from: []).isEmpty)
    }

    func testPairsAFinishedCommand() {
        let cmds = SessionCommands.pair(from: [
            mark(.promptStart, offset: 0),
            mark(.commandStart, offset: 5),
            mark(.preExec, offset: 12, command: "ls -la"),
            mark(.commandEnd, offset: 340, exit: 0),
        ])
        XCTAssertEqual(cmds.count, 1)
        let c = cmds[0]
        XCTAssertEqual(c.index, 1)
        XCTAssertEqual(c.command, "ls -la")
        XCTAssertEqual(c.exit, 0)
        XCTAssertEqual(c.startOffset, 12)
        XCTAssertEqual(c.endOffset, 340)
        XCTAssertFalse(c.running)
    }

    func testMultipleCommandsAreIndexedInOrder() {
        let cmds = SessionCommands.pair(from: [
            mark(.preExec, offset: 10, command: "true"),
            mark(.commandEnd, offset: 20, exit: 0),
            mark(.preExec, offset: 30, command: "false"),
            mark(.commandEnd, offset: 40, exit: 1),
        ])
        XCTAssertEqual(cmds.map(\.index), [1, 2])
        XCTAssertEqual(cmds.map(\.command), ["true", "false"])
        XCTAssertEqual(cmds.map(\.exit), [0, 1])
        XCTAssertEqual(cmds[1].startOffset, 30)
        XCTAssertEqual(cmds[1].endOffset, 40)
    }

    func testTrailingStartIsTheRunningCommand() {
        let cmds = SessionCommands.pair(from: [
            mark(.preExec, offset: 10, command: "true"),
            mark(.commandEnd, offset: 20, exit: 0),
            mark(.preExec, offset: 30, command: "sleep 30"),
        ])
        XCTAssertEqual(cmds.count, 2)
        let running = cmds[1]
        XCTAssertTrue(running.running)
        XCTAssertNil(running.exit)
        XCTAssertNil(running.endOffset)
        XCTAssertEqual(running.startOffset, 30)
        XCTAssertEqual(running.command, "sleep 30")
    }

    func testCommandEndWithoutStartIsIgnored() {
        let cmds = SessionCommands.pair(from: [
            mark(.commandEnd, offset: 5, exit: 0), // stray end (marks rotated)
            mark(.preExec, offset: 10, command: "ls"),
            mark(.commandEnd, offset: 20, exit: 0),
        ])
        XCTAssertEqual(cmds.count, 1)
        XCTAssertEqual(cmds[0].command, "ls")
    }

    /// Two starts naming *different* commands are two commands; the first
    /// simply never reported an end.
    func testBackToBackStartsOfDifferentCommandsCloseTheFirstAsRunning() {
        let cmds = SessionCommands.pair(from: [
            mark(.preExec, offset: 10, command: "a"),
            mark(.preExec, offset: 30, command: "b"),
            mark(.commandEnd, offset: 40, exit: 0),
        ])
        XCTAssertEqual(cmds.count, 2)
        XCTAssertTrue(cmds[0].running) // first never got an end
        XCTAssertNil(cmds[0].endOffset)
        XCTAssertFalse(cmds[1].running)
        XCTAssertEqual(cmds[1].endOffset, 40)
    }

    /// A shell carrying two integrations announces each command twice. The
    /// earlier start never gets an end, and emitting it as a permanently
    /// "running" command would give callers an index that can never be waited
    /// on — so the duplicate collapses instead.
    func testDuplicateStartsCollapseIntoOneCommand() {
        let marks = [
            SessionMark(offset: 10, kind: .preExec, exit: nil, command: "make test"),
            SessionMark(offset: 14, kind: .preExec, exit: nil, command: nil),
            SessionMark(offset: 900, kind: .commandEnd, exit: 0, command: nil),
        ]
        let commands = SessionCommands.pair(from: marks)
        XCTAssertEqual(commands.count, 1, "one real command, not one real plus a phantom")
        XCTAssertFalse(commands[0].running)
        XCTAssertEqual(commands[0].exit, 0)
        XCTAssertEqual(commands[0].command, "make test", "the text must survive the collapse")
    }

    func testTrailingStartIsStillTheRunningCommand() {
        let marks = [
            SessionMark(offset: 10, kind: .preExec, exit: nil, command: "sleep 30"),
        ]
        let commands = SessionCommands.pair(from: marks)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].running)
    }
}
