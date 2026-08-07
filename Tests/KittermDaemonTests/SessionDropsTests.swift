import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// Dropped files are named by whoever dropped them, and the path ends up in a
/// shell. So the name is rewritten before it is used, and the bytes only ever
/// land under kitterm's own directory.
final class SessionDropsTests: XCTestCase {
    private let sessionID = UUID()

    override func tearDownWithError() throws {
        SessionDrops.discard(sessionID: sessionID)
    }

    // MARK: - names

    func testOrdinaryNamesSurvive() {
        XCTAssertEqual(SessionDrops.sanitize(filename: "notes.md"), "notes.md")
        XCTAssertEqual(SessionDrops.sanitize(filename: "Screenshot-2026.png"), "Screenshot-2026.png")
        XCTAssertEqual(SessionDrops.sanitize(filename: "data_v2.csv"), "data_v2.csv")
    }

    /// Only the last component is considered, so a traversal cannot climb out.
    func testTraversalIsReducedToALeafName() {
        XCTAssertEqual(SessionDrops.sanitize(filename: "../../../../etc/passwd"), "passwd")
        XCTAssertEqual(SessionDrops.sanitize(filename: "/etc/shadow"), "shadow")
        XCTAssertEqual(SessionDrops.sanitize(filename: ".."), nil)
    }

    /// The path is going to be typed into a shell, so characters that would
    /// change what the shell sees do not survive.
    func testShellHostileCharactersAreNeutralised() throws {
        let cleaned = try XCTUnwrap(SessionDrops.sanitize(filename: "my file; rm -rf ~.txt"))
        XCTAssertFalse(cleaned.contains(";"))
        XCTAssertFalse(cleaned.contains(" "))
        XCTAssertFalse(cleaned.contains("~"))
        for hostile in ["a`b`.txt", "a$(id).txt", #"a"b".txt"#, "a'b'.txt", "a|b.txt", "a&b.txt"] {
            let safe = try XCTUnwrap(SessionDrops.sanitize(filename: hostile))
            XCTAssertTrue(
                safe.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) },
                "\(hostile) produced \(safe)"
            )
        }
    }

    func testHiddenAndEmptyNamesAreRejectedOrUnhidden() {
        XCTAssertEqual(SessionDrops.sanitize(filename: ".zshrc"), "zshrc")
        XCTAssertNil(SessionDrops.sanitize(filename: ""))
        XCTAssertNil(SessionDrops.sanitize(filename: "..."))
    }

    /// A long name is truncated but keeps its extension, which is how an agent
    /// decides how to read the file.
    func testLongNamesKeepTheirExtension() throws {
        let long = String(repeating: "a", count: 400) + ".png"
        let cleaned = try XCTUnwrap(SessionDrops.sanitize(filename: long))
        XCTAssertLessThanOrEqual(cleaned.count, KittermConstants.maxDropNameLength)
        XCTAssertTrue(cleaned.hasSuffix(".png"))
    }

    // MARK: - storing

    func testStoredFileIsReadableAtTheReturnedPath() throws {
        let url = try SessionDrops.store(
            data: Data("# context".utf8), filename: "notes.md", sessionID: sessionID
        )
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# context")
        XCTAssertTrue(
            url.path.hasPrefix(DaemonPaths.dropsDirectory.path),
            "bytes must land under kitterm's own directory, got \(url.path)"
        )
    }

    /// Two screenshots should be two files, not one overwritten.
    func testRepeatedNamesDoNotOverwrite() throws {
        let first = try SessionDrops.store(
            data: Data("one".utf8), filename: "shot.png", sessionID: sessionID
        )
        let second = try SessionDrops.store(
            data: Data("two".utf8), filename: "shot.png", sessionID: sessionID
        )
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
    }

    func testOversizeIsRefused() {
        let tooBig = Data(repeating: 0, count: KittermConstants.maxDropBytes + 1)
        XCTAssertThrowsError(
            try SessionDrops.store(data: tooBig, filename: "big.bin", sessionID: sessionID)
        )
    }

    func testFilesAreOwnerOnly() throws {
        let url = try SessionDrops.store(
            data: Data("x".utf8), filename: "a.txt", sessionID: sessionID
        )
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        XCTAssertEqual((perms as? NSNumber)?.int16Value, 0o600)
    }

    func testDiscardRemovesTheSessionsFiles() throws {
        _ = try SessionDrops.store(data: Data("x".utf8), filename: "a.txt", sessionID: sessionID)
        SessionDrops.discard(sessionID: sessionID)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: SessionDrops.directory(for: sessionID).path)
        )
    }
}
