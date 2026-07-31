import Foundation
import XCTest

@testable import KittermDaemon

/// The store's whole job is answering "give me the bytes at stream offsets
/// [a,b)" long after the ring dropped them, which makes its offset arithmetic
/// the only thing that matters. A file does not start at stream offset zero —
/// a shell prints its banner before the session has an id to name a file after
/// — and getting that wrong returns plausible-looking wrong bytes rather than
/// an error, so it is tested directly.
final class SessionLogStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-logstore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(origin: UInt64, maxBytes: Int = 1024) throws -> SessionLogStore {
        try XCTUnwrap(
            SessionLogStore(directory: dir, sessionID: UUID(), maxBytes: maxBytes, origin: origin)
        )
    }

    /// Drain the store's queue, which is where every read and write lands.
    private func read(_ store: SessionLogStore, from: UInt64, to: UInt64) -> (Data, UInt64) {
        var result = (Data(), UInt64(0))
        let done = expectation(description: "read")
        store.read(from: from, to: to) { data, start in
            result = (data, start)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    func testReadsBackWhatItWrote() throws {
        let store = try store(origin: 0)
        store.append(Data("hello world".utf8))
        let (data, start) = read(store, from: 6, to: 11)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "world")
        XCTAssertEqual(start, 6)
    }

    /// The regression: a store attached after the shell already printed sees
    /// its first byte at a nonzero stream offset, so file position and stream
    /// offset differ by `origin`.
    func testTranslatesStreamOffsetsWhenTheFileStartsMidStream() throws {
        let origin: UInt64 = 500
        let store = try store(origin: origin)
        store.append(Data("NEEDLE".utf8))
        let (data, start) = read(store, from: origin, to: origin + 6)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self), "NEEDLE",
            "reading at the stream offset must not read at that file position"
        )
        XCTAssertEqual(start, origin)
    }

    func testOffsetsBeforeTheStoreExistedReportWhatItActuallyHas() throws {
        let store = try store(origin: 1000)
        store.append(Data("later".utf8))
        // Asking for bytes from before the store started: it answers with what
        // it has and says where that begins, rather than silently misaligning.
        let (data, start) = read(store, from: 0, to: 1005)
        XCTAssertEqual(start, 1000)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "later")
    }

    func testRotationDropsTheFrontAndStillTranslates() throws {
        let store = try store(origin: 0, maxBytes: 512)
        // Push past the cap so the front is dropped.
        for i in 0..<20 {
            store.append(Data(String(repeating: "\(i % 10)", count: 100).utf8))
        }
        // 20 appends of 100 bytes, so the next byte written is at offset 2000.
        let needleOffset: UInt64 = 2000
        store.append(Data("TAILNEEDLE".utf8))
        let (data, start) = read(store, from: needleOffset, to: needleOffset + 10)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "TAILNEEDLE")
        XCTAssertEqual(start, needleOffset)

        // Early bytes are gone, and the caller is told where the data begins
        // instead of getting the wrong bytes.
        let (_, earlyStart) = read(store, from: 0, to: 50)
        XCTAssertGreaterThan(earlyStart, 0)
    }

    func testFilePermissionsAreOwnerOnly() throws {
        let store = try store(origin: 0)
        store.append(Data("x".utf8))
        _ = read(store, from: 0, to: 1)  // drains the queue
        let file = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).first
        )
        let perms = try FileManager.default
            .attributesOfItem(atPath: dir.appendingPathComponent(file).path)[.posixPermissions]
        XCTAssertEqual((perms as? NSNumber)?.int16Value, 0o600, "shell output is not world-readable")
    }

    func testCloseDeletesTheFile() throws {
        let store = try store(origin: 0)
        store.append(Data("gone soon".utf8))
        _ = read(store, from: 0, to: 1)
        store.close()
        let drained = expectation(description: "close drained")
        store.read(from: 0, to: 1) { _, _ in drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
            "retained output must not outlive the session"
        )
    }
}
