import CryptoKit
import Foundation
import XCTest

@testable import KittermDaemon

/// The wire shape: a body a browser can open, a token a push service can
/// check, and a key pair that is the same one after a restart.
final class WebPushTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-webpush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private var keyFile: URL { stateDir.appendingPathComponent("vapid.json") }

    // MARK: - Encryption

    /// The browser's own decryption reads back exactly the payload, which is
    /// the only proof that the header layout and the two HKDF steps are the
    /// RFC's and not merely self-consistent.
    func testABrowserDecryptsWhatTheDaemonSealed() throws {
        let browser = FakeBrowser()
        let payload = Data(#"{"session":"abc","state":"needs-input"}"#.utf8)
        let body = try WebPush.encrypt(payload, p256dh: browser.p256dh, auth: browser.auth)
        XCTAssertEqual(try browser.decrypt(body), payload)
        // salt(16) rs(4) idlen(1) key(65) plaintext(+1 delimiter) tag(16)
        XCTAssertEqual(body.count, 16 + 4 + 1 + 65 + payload.count + 1 + 16)
    }

    func testEveryMessageUsesAFreshSaltAndKey() throws {
        let browser = FakeBrowser()
        let payload = Data("same".utf8)
        let first = try WebPush.encrypt(payload, p256dh: browser.p256dh, auth: browser.auth)
        let second = try WebPush.encrypt(payload, p256dh: browser.p256dh, auth: browser.auth)
        XCTAssertNotEqual(first.prefix(16), second.prefix(16), "the salt")
        XCTAssertNotEqual(first[21 ..< 86], second[21 ..< 86], "the ephemeral key")
        XCTAssertEqual(try browser.decrypt(second), payload)
    }

    func testAnotherBrowserCannotOpenIt() throws {
        let browser = FakeBrowser()
        let other = FakeBrowser()
        let body = try WebPush.encrypt(Data("secret".utf8), p256dh: browser.p256dh, auth: browser.auth)
        XCTAssertThrowsError(try other.decrypt(body))
    }

    func testBadKeysAreRefusedNotSent() {
        let browser = FakeBrowser()
        XCTAssertThrowsError(try WebPush.encrypt(Data("x".utf8), p256dh: "not-a-point", auth: browser.auth)) {
            XCTAssertEqual(($0 as? WebPush.EncryptionFailure)?.reason, "p256dh is not an uncompressed P-256 point")
        }
        XCTAssertThrowsError(try WebPush.encrypt(Data("x".utf8), p256dh: browser.p256dh, auth: "c2hvcnQ")) {
            XCTAssertEqual(($0 as? WebPush.EncryptionFailure)?.reason, "auth is not 16 bytes")
        }
        let oversized = Data(repeating: 0x41, count: Int(WebPush.recordSize))
        XCTAssertThrowsError(try WebPush.encrypt(oversized, p256dh: browser.p256dh, auth: browser.auth))
    }

    func testBase64URLRoundTripsWithAndWithoutPadding() {
        let bytes = Data([0xfb, 0xff, 0xbf, 0x00, 0x01])
        let text = WebPush.base64URL(bytes)
        XCTAssertFalse(text.contains("="))
        XCTAssertFalse(text.contains("+"))
        XCTAssertFalse(text.contains("/"))
        XCTAssertEqual(WebPush.base64URLDecode(text), bytes)
        XCTAssertEqual(WebPush.base64URLDecode(text + "=="), bytes, "a client that kept the padding")
    }

    // MARK: - VAPID

    /// The push service checks the token with the `k=` key of the same
    /// header, over the endpoint's origin only.
    func testTheAuthorizationHeaderVerifiesWithItsOwnKey() throws {
        let keys = VAPIDKeys()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let header = try XCTUnwrap(keys.authorization(
            for: URL(string: "https://fcm.googleapis.com/fcm/send/abc?x=1")!, now: now
        ))
        XCTAssertTrue(header.hasPrefix("vapid t="), header)
        let parts = header.dropFirst("vapid ".count).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let token = try XCTUnwrap(parts.first { $0.hasPrefix("t=") }).dropFirst(2)
        let key = try XCTUnwrap(parts.first { $0.hasPrefix("k=") }).dropFirst(2)
        XCTAssertEqual(String(key), keys.publicKeyBase64URL)

        let segments = token.split(separator: ".").map(String.init)
        XCTAssertEqual(segments.count, 3)
        let headerJSON = try json(segments[0])
        XCTAssertEqual(headerJSON["alg"] as? String, "ES256")
        XCTAssertEqual(headerJSON["typ"] as? String, "JWT")
        let claims = try json(segments[1])
        XCTAssertEqual(claims["aud"] as? String, "https://fcm.googleapis.com")
        XCTAssertEqual(claims["sub"] as? String, VAPIDKeys.subject)
        XCTAssertEqual(claims["exp"] as? Int, Int(now.timeIntervalSince1970) + 12 * 3600)

        let publicKey = try P256.Signing.PublicKey(x963Representation: try XCTUnwrap(WebPush.base64URLDecode(String(key))))
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: try XCTUnwrap(WebPush.base64URLDecode(segments[2]))
        )
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data("\(segments[0]).\(segments[1])".utf8)))
    }

    func testTheAudienceKeepsAnExplicitPort() throws {
        let header = try XCTUnwrap(VAPIDKeys().authorization(for: URL(string: "http://127.0.0.1:4321/push/1")!))
        let token = header.dropFirst("vapid t=".count).split(separator: ",")[0]
        let claims = try json(String(token.split(separator: ".")[1]))
        XCTAssertEqual(claims["aud"] as? String, "http://127.0.0.1:4321")
    }

    // MARK: - The key file

    func testThePairIsWrittenOnceOwnerOnlyAndReadBack() throws {
        let first = try VAPIDKeys.loadOrCreate(at: keyFile)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(mode & 0o777, 0o600)
        let second = try VAPIDKeys.loadOrCreate(at: keyFile)
        XCTAssertEqual(second.publicKeyBase64URL, first.publicKeyBase64URL, "the same pair after a restart")
        let shape = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: keyFile)) as? [String: Any]
        )
        XCTAssertEqual(shape["version"] as? Int, VAPIDKeys.formatVersion)
        XCTAssertEqual(Set(shape.keys), ["version", "privateKey"], "no subscription, no session, nothing else")
    }

    func testAFileOthersCanReadIsReplaced() throws {
        let first = try VAPIDKeys.loadOrCreate(at: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile.path)
        let second = try VAPIDKeys.loadOrCreate(at: keyFile)
        XCTAssertNotEqual(second.publicKeyBase64URL, first.publicKeyBase64URL)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testAnUnknownVersionIsReplaced() throws {
        try Data(#"{"version":2,"privateKey":"AAAA"}"#.utf8).write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        _ = try VAPIDKeys.loadOrCreate(at: keyFile)
        let shape = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: keyFile)) as? [String: Any]
        )
        XCTAssertEqual(shape["version"] as? Int, 1)
        XCTAssertNotEqual(shape["privateKey"] as? String, "AAAA")
    }

    private func json(_ base64url: String) throws -> [String: Any] {
        let data = try XCTUnwrap(WebPush.base64URLDecode(base64url))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
