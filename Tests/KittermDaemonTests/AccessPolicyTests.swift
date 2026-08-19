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

    // MARK: - Trusted hosts (reverse proxy / overlay network)

    private func proxyHeaders(host: String, _ pairs: [(String, String)] = []) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        for (name, value) in pairs { headers.add(name: name, value: value) }
        return headers
    }

    /// The rule the whole feature rests on: a request naming a public host is
    /// remote even though the proxy connects from loopback. Without this, the
    /// proxy leaks loopback's unauthenticated full access to the internet.
    func testProxiedRequestFromLoopbackStillNeedsAToken() {
        let policy = AccessPolicy.proxied(token: "ctl", trustedHosts: ["mac.tailnet.ts.net"])
        XCTAssertEqual(
            policy.decide(
                remote: loopbackPeer,
                headers: proxyHeaders(host: "mac.tailnet.ts.net"),
                uri: "/"
            ),
            .reject("missing or invalid token")
        )
        XCTAssertEqual(
            policy.decide(
                remote: loopbackPeer,
                headers: proxyHeaders(host: "mac.tailnet.ts.net"),
                uri: "/?token=ctl"
            ),
            .allowSettingCookie(.full, cookie: "ctl")
        )
    }

    /// A watch token stays watch-grade through the proxy.
    func testProxiedWatchTokenKeepsItsGrade() {
        let policy = AccessPolicy.proxied(
            token: "ctl",
            watchToken: "ktw_w",
            trustedHosts: ["mac.tailnet.ts.net"]
        )
        XCTAssertEqual(
            policy.decide(
                remote: loopbackPeer,
                headers: proxyHeaders(host: "mac.tailnet.ts.net"),
                uri: "/?token=ktw_w"
            ),
            .allowSettingCookie(.watch, cookie: "ktw_w")
        )
    }

    /// Genuine local use is untouched: same daemon, loopback Host, no token.
    func testLocalAccessUnaffectedByTrustedHosts() {
        let policy = AccessPolicy.proxied(token: "ctl", trustedHosts: ["mac.tailnet.ts.net"])
        XCTAssertEqual(
            policy.decide(
                remote: loopbackPeer,
                headers: proxyHeaders(host: "kitterm.localhost:3418"),
                uri: "/"
            ),
            .allow(.full)
        )
    }

    /// An unlisted Host is still refused — the allowlist is not a wildcard.
    func testUnknownHostStillRejected() {
        let policy = AccessPolicy.proxied(token: "ctl", trustedHosts: ["mac.tailnet.ts.net"])
        XCTAssertEqual(
            policy.decide(
                remote: loopbackPeer,
                headers: proxyHeaders(host: "evil.example"),
                uri: "/?token=ctl"
            ),
            .reject("non-loopback Host")
        )
    }

    func testTrustedHostMatchIgnoresPortAndCase() {
        let policy = AccessPolicy.proxied(token: "ctl", trustedHosts: ["Mac.Tailnet.TS.net"])
        XCTAssertEqual(
            policy.decide(
                remote: loopbackPeer,
                headers: proxyHeaders(host: "mac.tailnet.ts.net:8443"),
                uri: "/?token=ctl"
            ),
            .allowSettingCookie(.full, cookie: "ctl")
        )
    }

    /// Cross-origin protection survives the proxy path.
    func testProxiedCrossOriginRejected() {
        let policy = AccessPolicy.proxied(token: "ctl", trustedHosts: ["mac.tailnet.ts.net"])
        XCTAssertEqual(
            policy.decide(
                remote: loopbackPeer,
                headers: proxyHeaders(
                    host: "mac.tailnet.ts.net",
                    [("Origin", "http://evil.example")]
                ),
                uri: "/?token=ctl"
            ),
            .reject("cross-origin")
        )
    }

    /// Same-origin under the public name is what a real browser sends.
    func testProxiedSameOriginAccepted() {
        let policy = AccessPolicy.proxied(token: "ctl", trustedHosts: ["mac.tailnet.ts.net"])
        XCTAssertEqual(
            policy.decide(
                remote: loopbackPeer,
                headers: proxyHeaders(
                    host: "mac.tailnet.ts.net",
                    [("Origin", "https://mac.tailnet.ts.net")]
                ),
                uri: "/?token=ctl"
            ),
            .allowSettingCookie(.full, cookie: "ctl")
        )
    }

    /// With no --trusted-host configured, nothing changes from today.
    func testNoTrustedHostsKeepsLoopbackOnlyBehaviour() {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "mac.tailnet.ts.net")
        XCTAssertEqual(
            AccessPolicy.loopbackOnly.decide(remote: loopbackPeer, headers: headers, uri: "/"),
            .reject("non-loopback Host")
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

    // MARK: - The auth cookie's lifetime

    /// Without `Max-Age` this is a session cookie. A browser tab never showed
    /// the fault, because it keeps session cookies across a reload — but an
    /// installed app starts a new session on every launch and discards it, so
    /// it met a 403 each time with no address bar to present a token in.
    func testAuthCookieOutlivesTheBrowserSession() {
        let header = AccessPolicy.setCookieHeaderValue(for: "abc123")
        XCTAssertTrue(
            header.contains("Max-Age=\(AccessPolicy.cookieMaxAge)"),
            "a session cookie strands an installed app: \(header)"
        )
        XCTAssertGreaterThanOrEqual(AccessPolicy.cookieMaxAge, 60 * 60 * 24 * 7)
    }

    /// The lifetime must not cost the protections the cookie already carried.
    func testAuthCookieKeepsItsProtections() {
        let plain = AccessPolicy.setCookieHeaderValue(for: "abc123")
        XCTAssertTrue(plain.contains("HttpOnly"))
        XCTAssertTrue(plain.contains("SameSite=Strict"))
        XCTAssertTrue(plain.contains("Path=/"))
        XCTAssertFalse(plain.contains("Secure"), "plaintext must not claim Secure")

        let secure = AccessPolicy.setCookieHeaderValue(for: "abc123", secure: true)
        XCTAssertTrue(secure.contains("; Secure"))
        XCTAssertTrue(secure.contains("Max-Age=\(AccessPolicy.cookieMaxAge)"))
    }

    /// The cookie is still the token, so a round trip must survive the new
    /// attribute rather than parse it as part of the value.
    func testCookieStillParsesBackToItsToken() {
        var headers = HTTPHeaders()
        headers.add(name: "cookie", value: "\(AccessPolicy.cookieName)=abc123")
        XCTAssertEqual(AccessPolicy.cookieToken(headers), "abc123")
    }
}

/// The 403 an installed app meets.
///
/// A JSON body is a dead end where there is no address bar, so a navigation
/// gets a page with a token field instead. Everything else keeps the JSON
/// contract it has always had.
final class TokenPromptPageTests: XCTestCase {
    private func accept(_ value: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "accept", value: value)
        return headers
    }

    func testBrowserNavigationWantsHTML() {
        XCTAssertTrue(HTTPAPIHandler.wantsHTML(
            accept("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        ))
    }

    func testProgrammaticClientsStillGetJSON() {
        XCTAssertFalse(HTTPAPIHandler.wantsHTML(accept("application/json")))
        XCTAssertFalse(HTTPAPIHandler.wantsHTML(accept("*/*")))
        XCTAssertFalse(HTTPAPIHandler.wantsHTML(HTTPHeaders()))
    }

    func testPageCarriesAFieldThatSubmitsAToken() {
        let page = HTTPAPIHandler.tokenPromptPage(reason: "missing or invalid token")
        // A GET form to / puts the token in the query, which is the path that
        // already authenticates and sets the cookie.
        XCTAssertTrue(page.contains(#"method="get""#))
        XCTAssertTrue(page.contains(#"action="/""#))
        XCTAssertTrue(page.contains(#"name="token""#))
        // No script: this is what a locked-out client sees.
        XCTAssertFalse(page.lowercased().contains("<script"))
        XCTAssertTrue(page.contains("missing or invalid token"))
    }

    func testReasonIsEscapedIntoThePage() {
        let page = HTTPAPIHandler.tokenPromptPage(reason: "<img src=x onerror=alert(1)>")
        XCTAssertFalse(page.contains("<img"))
        XCTAssertTrue(page.contains("&lt;img"))
    }
}
