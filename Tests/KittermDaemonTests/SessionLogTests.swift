import Foundation
import XCTest

@testable import KittermDaemon

/// Offset accounting and wrap behaviour of the session output ring.
final class SessionLogTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testHeadAndBaseTrackAppendedBytes() {
        var log = SessionLog(capacity: 8)
        XCTAssertEqual(log.head, 0)
        XCTAssertEqual(log.base, 0)

        log.append(data("abc"))
        XCTAssertEqual(log.head, 3)
        XCTAssertEqual(log.base, 0)

        log.append(data("defghij")) // 10 total, capacity 8
        XCTAssertEqual(log.head, 10)
        XCTAssertEqual(log.base, 2, "the two oldest bytes rotated out")
    }

    func testSnapshotFromOffsetReturnsExactBytes() {
        var log = SessionLog(capacity: 16)
        log.append(data("hello-world"))

        let snap = log.snapshot(from: 6)
        XCTAssertEqual(snap.data, data("world"))
        XCTAssertEqual(snap.start, 6)
        XCTAssertFalse(snap.pruned)
    }

    func testSnapshotAtHeadIsEmpty() {
        var log = SessionLog(capacity: 16)
        log.append(data("abc"))

        let snap = log.snapshot(from: 3)
        XCTAssertTrue(snap.data.isEmpty)
        XCTAssertEqual(snap.start, 3)
        XCTAssertFalse(snap.pruned)
    }

    func testSnapshotReassemblesAcrossTheWrapSeam() {
        var log = SessionLog(capacity: 8)
        log.append(data("abcdef"))   // writeIndex 6
        log.append(data("ghij"))     // wraps: storage holds ij…cdefgh

        XCTAssertEqual(log.head, 10)
        XCTAssertEqual(log.base, 2)
        let snap = log.snapshot(from: 2)
        XCTAssertEqual(snap.data, data("cdefghij"), "two slices joined in stream order")
    }

    func testPrunedOffsetReturnsFullRing() {
        var log = SessionLog(capacity: 4)
        log.append(data("abcdefgh")) // base 4

        let snap = log.snapshot(from: 1)
        XCTAssertTrue(snap.pruned)
        XCTAssertEqual(snap.start, 4)
        XCTAssertEqual(snap.data, data("efgh"))
    }

    func testOffsetBeyondHeadIsTreatedAsPruned() {
        var log = SessionLog(capacity: 8)
        log.append(data("abc"))

        let snap = log.snapshot(from: 99)
        XCTAssertTrue(snap.pruned)
        XCTAssertEqual(snap.start, 0)
        XCTAssertEqual(snap.data, data("abc"))
    }

    func testChunkLargerThanCapacityKeepsTheSuffix() {
        var log = SessionLog(capacity: 4)
        log.append(data("abcdefgh"))

        XCTAssertEqual(log.head, 8)
        XCTAssertEqual(log.base, 4)
        XCTAssertEqual(log.snapshot(from: 4).data, data("efgh"))
    }

    func testTailCapsAtMaxBytes() {
        var log = SessionLog(capacity: 16)
        log.append(data("0123456789"))

        let snap = log.tail(maxBytes: 4)
        XCTAssertEqual(snap.data, data("6789"))
        XCTAssertEqual(snap.start, 6)
        XCTAssertFalse(snap.pruned)
    }

    func testTailShorterThanMaxReturnsEverything() {
        var log = SessionLog(capacity: 16)
        log.append(data("abc"))

        let snap = log.tail(maxBytes: 100)
        XCTAssertEqual(snap.data, data("abc"))
        XCTAssertEqual(snap.start, 0)
    }

    // MARK: - range(from:to:)

    func testRangeReturnsExactSlice() {
        var log = SessionLog(capacity: 32)
        log.append(data("hello-world"))

        let snap = log.range(from: 6, to: 11) // "world"
        XCTAssertEqual(snap.data, data("world"))
        XCTAssertEqual(snap.start, 6)
        XCTAssertFalse(snap.pruned)
    }

    func testRangeInTheMiddle() {
        var log = SessionLog(capacity: 32)
        log.append(data("0123456789"))

        let snap = log.range(from: 2, to: 5) // "234"
        XCTAssertEqual(snap.data, data("234"))
        XCTAssertEqual(snap.start, 2)
    }

    func testRangeAcrossTheWrapSeam() {
        var log = SessionLog(capacity: 8)
        log.append(data("abcdef")) // writeIndex 6
        log.append(data("ghij")) // wraps; retained [2,10) = "cdefghij"

        XCTAssertEqual(log.base, 2)
        // A slice straddling the seam: offsets 4..8 = "efgh".
        let snap = log.range(from: 4, to: 8)
        XCTAssertEqual(snap.data, data("efgh"))
        XCTAssertEqual(snap.start, 4)
        XCTAssertFalse(snap.pruned)
    }

    func testRangeClampsAPrunedStart() {
        var log = SessionLog(capacity: 4)
        log.append(data("abcdefgh")) // base 4, retained "efgh"

        // Asked from 1 (pruned) to 6 → clamped to [4,6) = "ef".
        let snap = log.range(from: 1, to: 6)
        XCTAssertTrue(snap.pruned)
        XCTAssertEqual(snap.start, 4)
        XCTAssertEqual(snap.data, data("ef"))
    }

    func testRangeClampsEndToHead() {
        var log = SessionLog(capacity: 32)
        log.append(data("abcde"))

        let snap = log.range(from: 3, to: 99) // clamp to head=5 → "de"
        XCTAssertEqual(snap.data, data("de"))
        XCTAssertEqual(snap.start, 3)
    }

    func testEmptyRange() {
        var log = SessionLog(capacity: 32)
        log.append(data("abc"))

        XCTAssertTrue(log.range(from: 2, to: 2).data.isEmpty)
        XCTAssertTrue(log.range(from: 3, to: 1).data.isEmpty) // inverted → empty
    }
}
