import Foundation
import NIOCore
import NIOHTTP1
import XCTest

@testable import KittermDaemon

/// Grades: who gets in, and with what powers. The Host/Origin loopback rules
/// are covered by the daemon's live behavior; these tests pin the token paths.
final class AccessPolicyTests: XCTestCase {
    private let lanPeer = try! SocketAddress(ipAddress: "192.168.1.20", port: 50000)
    private let loopbackPeer = try! SocketAddress(ipAddress: "127.0.0.1", port: 50000)

    private func headers(_ pairs: [(String, String)] = []) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "192.168.1.10:3418")
        for (name, value) in pairs {
            headers.add(name: name, value: value)
        }
        return headers
    }

    func testLoopbackIsAlwaysFull() {
        let policy = AccessPolicy.lan(token: "ctl", watchToken: "ktw_w")
        var loopbackHeaders = HTTPHeaders()
        loopbackHeaders.add(name: "Host", value: "127.0.0.1:3418")
        XCTAssertEqual(
            policy.decide(remote: loopbackPeer, headers: loopbackHeaders, uri: "/"),
            .allow(.full)
        )
    }

    func testControlTokenGrantsFull() {
        let policy = AccessPolicy.lan(token: "ctl", watchToken: "ktw_w")
        XCTAssertEqual(
            policy.decide(remote: lanPeer, headers: headers(), uri: "/?token=ctl"),
            .allowSettingCookie(.full, cookie: "ctl")
        )
        XCTAssertEqual(
            policy.decide(
                remote: lanPeer,
                headers: headers([("cookie", "kitterm_token=ctl")]),
                uri: "/"
            ),
            .allow(.full)
        )
    }

    func testWatchTokenGrantsWatchAndCookiesItself() {
        let policy = AccessPolicy.lan(token: "ctl", watchToken: "ktw_w")
        // The cookie set must be the *watch* token — never the control token.
        XCTAssertEqual(
            policy.decide(remote: lanPeer, headers: headers(), uri: "/?token=ktw_w"),
            .allowSettingCookie(.watch, cookie: "ktw_w")
        )
        XCTAssertEqual(
            policy.decide(
                remote: lanPeer,
                headers: headers([("cookie", "kitterm_token=ktw_w")]),
                uri: "/"
            ),
            .allow(.watch)
        )
    }

    func testNamedTokensCarryTheirStoredGrade() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-policy-tokens-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let fullSecret = TokenStore.generate(grade: .full)
        let watchSecret = TokenStore.generate(grade: .watch)
        try TokenStore.save(
            [
                NamedToken(name: "mac", hash: TokenStore.hash(fullSecret), grade: .full, created: .init()),
                NamedToken(name: "eye", hash: TokenStore.hash(watchSecret), grade: .watch, created: .init()),
            ],
            to: file
        )
        let policy = AccessPolicy.lan(
            token: "ctl",
            watchToken: nil,
            namedTokens: CachedTokenStore(url: file)
        )
        XCTAssertEqual(
            policy.decide(remote: lanPeer, headers: headers(), uri: "/?token=\(fullSecret)"),
            .allowSettingCookie(.full, cookie: fullSecret)
        )
        XCTAssertEqual(
            policy.decide(remote: lanPeer, headers: headers(), uri: "/?token=\(watchSecret)"),
            .allowSettingCookie(.watch, cookie: watchSecret)
        )
    }

    func testUnknownTokenRejected() {
        let policy = AccessPolicy.lan(token: "ctl", watchToken: "ktw_w")
        XCTAssertEqual(
            policy.decide(remote: lanPeer, headers: headers(), uri: "/?token=nope"),
            .reject("missing or invalid token")
        )
        XCTAssertEqual(
            policy.decide(remote: lanPeer, headers: headers(), uri: "/"),
            .reject("missing or invalid token")
        )
    }

    func testNonLoopbackWithoutLanRejected() {
        XCTAssertEqual(
            AccessPolicy.loopbackOnly.decide(remote: lanPeer, headers: headers(), uri: "/"),
            .reject("loopback only")
        )
    }

    func testCrossOriginStillRejectedWithValidToken() {
        let policy = AccessPolicy.lan(token: "ctl", watchToken: nil)
        XCTAssertEqual(
            policy.decide(
                remote: lanPeer,
                headers: headers([("Origin", "http://evil.example")]),
                uri: "/?token=ctl"
            ),
            .reject("cross-origin")
        )
    }
}
