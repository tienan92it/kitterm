import Foundation
import KittermProtocol
import NIOCore
import XCTest

@testable import KittermDaemon

/// `--retain-logs` end to end: output that has scrolled out of the in-memory
/// ring must still be readable through the session.
///
/// `SessionLogStoreTests` pins the store's own offset arithmetic in isolation.
/// What is not covered there is the join — `PtySession.outputRange` deciding
/// the ring has lost a range and translating the request onto a file that does
/// not begin at stream offset zero. That seam is where a wrong assumption
/// returns plausible-looking wrong bytes rather than an error, so it is worth
/// paying 5 MiB of test traffic to exercise for real.
final class RetainedOutputFallbackTests: XCTestCase {
    private var session: PtySession!
    private var directory: URL!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: RetainedOutputFallbackTests.self)
            .bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-retain-\(UUID().uuidString)")
        session = try PtySession.spawn(cwd: NSTemporaryDirectory())
    }

    override func tearDownWithError() throws {
        session?.terminate()
        session = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func feed(_ text: String) {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        session.handleRead(&buffer)
    }

    /// Read through the asynchronous overload, which is the one that consults
    /// the store.
    private func read(from: UInt64, to: UInt64) throws -> PtySession.OutputRange {
        var result: PtySession.OutputRange?
        let done = expectation(description: "range read")
        session.outputRange(from: from, to: to, maxBytes: 1024) { range in
            result = range
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result)
    }

    func testOutputBelowTheRingIsServedFromDisk() throws {
        // Attach the way the daemon does: the store's first byte is whatever
        // arrives next, which is already partway into the stream.
        let sessionID = UUID()
        let directory = self.directory!
        session.attachLogStore { origin in
            SessionLogStore(
                directory: directory,
                sessionID: sessionID,
                maxBytes: 16 * 1024 * 1024,
                origin: origin
            )
        }

        let needleOffset = session.logHead
        let needle = "NEEDLE-IN-THE-HAYSTACK"
        feed(needle)

        // Push the ring past the needle. The ring is 4 MiB and not injectable,
        // so this has to be real volume.
        let filler = String(repeating: "x", count: 64 * 1024)
        for _ in 0..<80 { feed(filler) }

        // The ring must genuinely have lost it, or this proves nothing.
        let fromRing = session.outputRange(
            from: needleOffset,
            to: needleOffset + UInt64(needle.utf8.count),
            maxBytes: 1024
        )
        XCTAssertTrue(fromRing.pruned, "the ring should have rotated past the needle")

        let range = try read(from: needleOffset, to: needleOffset + UInt64(needle.utf8.count))
        XCTAssertEqual(
            String(decoding: range.data, as: UTF8.self), needle,
            "retained output must come back byte-exact, at the offset asked for"
        )
        XCTAssertEqual(range.start, needleOffset)
        XCTAssertFalse(range.pruned, "the file still has it, so it is not pruned")
    }

    /// Without `--retain-logs` there is no store, and a lost range still
    /// reports itself lost rather than inventing bytes.
    func testWithoutAStoreALostRangeStaysPruned() throws {
        let needleOffset = session.logHead
        feed("EARLY")
        let filler = String(repeating: "y", count: 64 * 1024)
        for _ in 0..<80 { feed(filler) }

        let range = try read(from: needleOffset, to: needleOffset + 5)
        XCTAssertTrue(range.pruned, "no store means the bytes really are gone")
        XCTAssertNotEqual(String(decoding: range.data, as: UTF8.self), "EARLY")
    }

    /// Ranges still in the ring never touch the disk path.
    func testRecentOutputIsServedFromTheRing() throws {
        let sessionID = UUID()
        let directory = self.directory!
        session.attachLogStore { origin in
            SessionLogStore(
                directory: directory, sessionID: sessionID,
                maxBytes: 1024 * 1024, origin: origin
            )
        }
        let offset = session.logHead
        feed("RECENT-OUTPUT")
        let range = try read(from: offset, to: offset + 13)
        XCTAssertEqual(String(decoding: range.data, as: UTF8.self), "RECENT-OUTPUT")
        XCTAssertFalse(range.pruned)
    }
}
