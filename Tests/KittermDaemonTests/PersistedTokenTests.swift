import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// Tokens outlive the daemon, so a share link already on a phone survives a
/// restart. That only holds if a stored token is read back faithfully — and
/// only if a damaged or over-shared one is replaced rather than trusted.
final class PersistedTokenTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("token")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func generateCount() -> (() -> String, () -> Int) {
        var calls = 0
        return ({ calls += 1; return AccessPolicy.generateToken() }, { calls })
    }

    /// The point of the change: restarting must not revoke anything.
    func testASecondStartReusesTheStoredToken() throws {
        let (generate, calls) = generateCount()
        let first = try PersistedToken.loadOrCreate(at: file, generate: generate)
        let second = try PersistedToken.loadOrCreate(at: file, generate: generate)
        XCTAssertEqual(first, second)
        XCTAssertEqual(calls(), 1, "the second start must not mint a token")
    }

    func testRotateReplacesIt() throws {
        let first = try PersistedToken.loadOrCreate(at: file, generate: AccessPolicy.generateToken)
        let rotated = try PersistedToken.loadOrCreate(
            at: file, rotate: true, generate: AccessPolicy.generateToken
        )
        XCTAssertNotEqual(first, rotated)
        XCTAssertEqual(
            try PersistedToken.loadOrCreate(at: file, generate: AccessPolicy.generateToken),
            rotated,
            "the rotated token is what persists afterwards"
        )
    }

    func testWrittenTokensAreOwnerOnly() throws {
        _ = try PersistedToken.loadOrCreate(at: file, generate: AccessPolicy.generateToken)
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        XCTAssertEqual((perms as? NSNumber)?.int16Value, 0o600)
    }

    /// A credential the rest of the machine can read is not one to keep using.
    func testAWorldReadableTokenIsReplaced() throws {
        let original = try PersistedToken.loadOrCreate(at: file, generate: AccessPolicy.generateToken)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: file.path
        )
        XCTAssertNil(PersistedToken.read(from: file), "loosened permissions must not be trusted")
        let replacement = try PersistedToken.loadOrCreate(
            at: file, generate: AccessPolicy.generateToken
        )
        XCTAssertNotEqual(replacement, original)
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        XCTAssertEqual((perms as? NSNumber)?.int16Value, 0o600, "and the mode is repaired")
    }

    /// Anything that is not a token this daemon wrote fails closed.
    func testDamagedContentIsReplacedRatherThanUsed() throws {
        for junk in ["", "   ", "not-a-token", "zzzz", String(repeating: "a", count: 500)] {
            try PersistedToken.write(junk, to: file)
            XCTAssertNil(PersistedToken.read(from: file), "\(junk.prefix(12)) should be rejected")
            let fresh = try PersistedToken.loadOrCreate(at: file, generate: AccessPolicy.generateToken)
            XCTAssertTrue(PersistedToken.looksLikeToken(fresh))
        }
    }

    func testMissingFileMintsOne() throws {
        XCTAssertNil(PersistedToken.read(from: file))
        let created = try PersistedToken.loadOrCreate(at: file, generate: AccessPolicy.generateToken)
        XCTAssertTrue(PersistedToken.looksLikeToken(created))
    }

    /// Both shapes the daemon writes must survive a round trip.
    func testBothTokenShapesAreRecognised() throws {
        XCTAssertTrue(PersistedToken.looksLikeToken(AccessPolicy.generateToken()))
        XCTAssertTrue(PersistedToken.looksLikeToken(TokenStore.generate(grade: .watch)))
        try PersistedToken.write(TokenStore.generate(grade: .watch), to: file)
        XCTAssertTrue(PersistedToken.read(from: file)?.hasPrefix("ktw_") ?? false)
    }

    /// Trailing whitespace from an editor should not invalidate a token.
    func testSurroundingWhitespaceIsTolerated() throws {
        let token = AccessPolicy.generateToken()
        try PersistedToken.write("\n\(token)\n", to: file)
        XCTAssertEqual(PersistedToken.read(from: file), token)
    }
}
