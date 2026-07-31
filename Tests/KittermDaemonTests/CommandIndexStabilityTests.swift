import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// A command's number must mean the same command for a session's whole life.
///
/// Callers count the commands, write input, then wait on the index they
/// computed, and `outputUrl` embeds one in a link followed later. The mark
/// window is bounded, so a long session slides it — and numbering from 1 again
/// would return a different command's exit code instead of an error.
final class CommandIndexStabilityTests: XCTestCase {
    /// One command's worth of marks: prompt, start, end.
    private func appendCommand(_ store: inout SessionMarkStore, _ n: Int, offset: inout UInt64) {
        store.append(SessionMark(offset: offset, kind: .promptStart, exit: nil, command: nil))
        store.append(SessionMark(offset: offset, kind: .preExec, exit: nil, command: "cmd\(n)"))
        offset += 10
        store.append(SessionMark(offset: offset, kind: .commandEnd, exit: Int32(n), command: nil))
        offset += 1
    }

    private func commands(_ store: SessionMarkStore) -> [SessionCommand] {
        SessionCommands.pair(from: store.marks, firstIndex: store.firstRetainedIndex)
    }

    /// The regression: the first three age out, survivors keep their numbers.
    func testNumbersSurviveTheWindowSliding() {
        var store = SessionMarkStore(cap: 8)
        var offset: UInt64 = 0
        for n in 1...6 { appendCommand(&store, n, offset: &offset) }

        let retained = commands(store)
        XCTAssertEqual(
            retained.map(\.index), [4, 5, 6],
            "a command must keep its number when older ones age out"
        )
        // The number and the command it names must not come apart.
        for cmd in retained {
            XCTAssertEqual(cmd.command, "cmd\(cmd.index)")
            XCTAssertEqual(cmd.exit, Int32(cmd.index))
        }
    }

    /// Numbers keep climbing across many evictions rather than wrapping.
    func testNumbersAreMonotonicAcrossRepeatedEviction() {
        var store = SessionMarkStore(cap: 9)
        var offset: UInt64 = 0
        var highest = 0
        for n in 1...40 {
            appendCommand(&store, n, offset: &offset)
            let last = commands(store).last
            XCTAssertEqual(last?.index, n, "the newest command is always the nth")
            XCTAssertGreaterThan(last?.index ?? 0, highest)
            highest = last?.index ?? 0
        }
    }

    /// The window slides between a command's start and end, leaving an orphan
    /// end. That command still owns its number, so later ones do not shift.
    func testACommandWhoseStartAgedOutStillSpendsItsNumber() {
        var store = SessionMarkStore(cap: 4)
        var offset: UInt64 = 0
        // Two whole commands, then a third, leaving an orphaned end in front.
        for n in 1...3 { appendCommand(&store, n, offset: &offset) }
        // Force the window to cut mid-command by appending a bare start+end.
        store.append(SessionMark(offset: offset, kind: .preExec, exit: nil, command: "cmd4"))
        offset += 10
        store.append(SessionMark(offset: offset, kind: .commandEnd, exit: 4, command: nil))

        let retained = commands(store)
        XCTAssertEqual(retained.last?.command, "cmd4")
        XCTAssertEqual(
            retained.last?.index, 4,
            "a partially evicted command must not shift the ones after it"
        )
        XCTAssertEqual(
            retained.map(\.index), retained.map(\.index).sorted(),
            "numbers must never go backwards"
        )
    }

    func testFirstRetainedIndexReportsWhatAgedOut() {
        var store = SessionMarkStore(cap: 8)
        var offset: UInt64 = 0
        XCTAssertEqual(store.firstRetainedIndex, 1, "nothing dropped yet")
        for n in 1...6 { appendCommand(&store, n, offset: &offset) }
        XCTAssertEqual(
            store.firstRetainedIndex, 4,
            "callers use this to answer 'gone' rather than 'never existed'"
        )
    }

    /// An uncapped session numbers from 1, exactly as before.
    func testUnevictedSessionsAreUnchanged() {
        var store = SessionMarkStore(cap: 1000)
        var offset: UInt64 = 0
        for n in 1...5 { appendCommand(&store, n, offset: &offset) }
        XCTAssertEqual(commands(store).map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(store.firstRetainedIndex, 1)
    }
}
