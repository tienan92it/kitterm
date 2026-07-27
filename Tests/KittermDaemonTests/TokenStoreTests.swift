import Foundation
import XCTest

@testable import KittermDaemon

final class TokenStoreTests: XCTestCase {
    private var tempFile: URL!

    override func setUpWithError() throws {
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-tokens-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFile)
    }

    func testSaveLoadRoundTrip() throws {
        let created = Date(timeIntervalSince1970: 1_753_000_000)
        let tokens = [
            NamedToken(name: "phone", hash: TokenStore.hash("ktk_abc"), grade: .full, created: created),
            NamedToken(name: "review", hash: TokenStore.hash("ktw_def"), grade: .watch, created: created),
        ]
        try TokenStore.save(tokens, to: tempFile)
        XCTAssertEqual(TokenStore.load(from: tempFile), tokens)

        // Hashes only — the plaintext never touches disk.
        let raw = try String(contentsOf: tempFile, encoding: .utf8)
        XCTAssertFalse(raw.contains("ktk_abc"))
        XCTAssertFalse(raw.contains("ktw_def"))

        // Owner-only, like the ephemeral token file.
        let perms = try FileManager.default.attributesOfItem(atPath: tempFile.path)[.posixPermissions]
        XCTAssertEqual((perms as? NSNumber)?.int16Value, 0o600)
    }

    func testGeneratePrefixesByGrade() {
        XCTAssertTrue(TokenStore.generate(grade: .full).hasPrefix("ktk_"))
        XCTAssertTrue(TokenStore.generate(grade: .watch).hasPrefix("ktw_"))
        XCTAssertNotEqual(TokenStore.generate(grade: .full), TokenStore.generate(grade: .full))
    }

    func testMalformedEntriesAreSkipped() throws {
        try #"""
        { "tokens": [
          { "name": "ok", "hash": "\#(TokenStore.hash("t"))", "grade": "watch" },
          { "name": "bad grade", "hash": "\#(TokenStore.hash("t"))", "grade": "admin" },
          { "name": "shorthash", "hash": "abc", "grade": "full" },
          { "hash": "\#(TokenStore.hash("t"))", "grade": "full" }
        ] }
        """#.write(to: tempFile, atomically: true, encoding: .utf8)
        let tokens = TokenStore.load(from: tempFile)
        XCTAssertEqual(tokens.map(\.name), ["ok"])
        XCTAssertEqual(tokens.first?.grade, .watch)
    }

    func testCachedStoreVerifiesAndReloadsOnMtimeChange() throws {
        let secret = TokenStore.generate(grade: .watch)
        try TokenStore.save(
            [NamedToken(name: "w", hash: TokenStore.hash(secret), grade: .watch, created: .init())],
            to: tempFile
        )
        // Pin distinct mtimes so the reload check is deterministic.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: tempFile.path
        )

        let cached = CachedTokenStore(url: tempFile)
        XCTAssertEqual(cached.verify(secret), .watch)
        XCTAssertNil(cached.verify("wrong"))

        // Revoke (rewrite without the token, new mtime) — applies on next check.
        try TokenStore.save([], to: tempFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)],
            ofItemAtPath: tempFile.path
        )
        XCTAssertNil(cached.verify(secret))
    }

    func testCachedStoreWithNoFileRejectsEverything() {
        XCTAssertNil(CachedTokenStore(url: tempFile).verify("anything"))
    }
}
