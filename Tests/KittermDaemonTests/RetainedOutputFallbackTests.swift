import Foundation
import KittermProtocol
import NIOCore
import XCTest

@testable import KittermDaemon

/// `--retain-logs` end to end: output that scrolled out of the ring must still
/// be readable through the session.
///
/// `SessionLogStoreTests` covers the store's offset arithmetic alone. This
/// covers the join — `PtySession.outputRange` noticing the ring lost a range
/// and translating onto a file that starts mid-stream, where a wrong assumption
/// returns wrong bytes rather than an error.
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

    /// The async overload is the one that consults the store.
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
        // Attach as the daemon does: the first byte is already mid-stream.
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

        // The ring is 4 MiB and not injectable, so this needs real volume.
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

    /// With no store, a lost range reports itself lost rather than inventing.
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
