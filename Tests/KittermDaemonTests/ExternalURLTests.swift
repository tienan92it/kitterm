import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import KittermDaemon

/// `GET /api/lan` tells the client where other devices should connect, and the
/// ⧉ / 👁 share buttons paste exactly that. A wrong scheme or a missing port
/// here hands out links that cannot connect, which is invisible until someone
/// opens one on a phone — so each deployment shape gets a test.
final class ExternalURLTests: XCTestCase {
    private func lanResponse(
        policy: AccessPolicy, port: Int, tlsPort: Int?,
        host: String = "127.0.0.1", uri: String = "/api/lan"
    ) throws -> String {
        let handler = HTTPAPIHandler(
            registry: SessionRegistry(),
            policy: policy,
            port: port,
            tlsPort: tlsPort,
            staticRoot: nil
        )
        let channel = EmbeddedChannel(handler: handler)
        // Loopback caller: tokens are only disclosed to the local user.
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        defer { _ = try? channel.finish() }

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        var text = ""
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            if case .body(.byteBuffer(var buffer)) = part {
                text += buffer.readString(length: buffer.readableBytes) ?? ""
            }
        }
        return text
    }

    /// TLS listener: the certificate is issued for the name, so the link must
    /// use the name and the TLS port — never the LAN IP.
    func testTLSAdvertisesTheCertificateNameAndPort() throws {
        let body = try lanResponse(
            policy: .lan(token: "t", trustedHosts: ["mac.tailnet.ts.net"]),
            port: 3418,
            tlsPort: 3419
        )
        XCTAssertTrue(
            body.contains(#""url":"https://mac.tailnet.ts.net:3419""#),
            "expected the TLS name and port, got \(body)"
        )
    }

    /// The case a live tailnet test caught: a public name bound externally with
    /// no certificate is plain HTTP on our own port. Advertising `https://name`
    /// there produces links that fail to connect.
    func testPublicNameWithoutTLSAdvertisesPlainHTTPAndPort() throws {
        let body = try lanResponse(
            policy: .lan(token: "t", trustedHosts: ["genos.tail1234.ts.net"]),
            port: 4917,
            tlsPort: nil
        )
        XCTAssertTrue(
            body.contains(#""url":"http://genos.tail1234.ts.net:4917""#),
            "expected plain HTTP on the daemon's own port, got \(body)"
        )
    }

    /// Loopback-bound but answering to a public name means something fronts
    /// us; the proxy owns the scheme and port.
    func testProxiedNameAdvertisesTheBareHTTPSName() throws {
        let body = try lanResponse(
            policy: .proxied(token: "t", trustedHosts: ["kitterm.example.com"]),
            port: 3418,
            tlsPort: nil
        )
        XCTAssertTrue(
            body.contains(#""url":"https://kitterm.example.com""#),
            "expected the bare proxied name, got \(body)"
        )
    }

    // MARK: - The tokens go to the grade, not to the peer

    /// A watch token through a `--trusted-host` proxy: the peer is loopback
    /// (the proxy), the grade is watch. The route used to check the peer and
    /// hand this caller the control token, which spawns a shell. It gets the
    /// URL and `enabled` and neither token, the shape the page reads as a
    /// link with no token in it.
    func testWatchGradeThroughTheProxyGetsNoToken() throws {
        let body = try lanResponse(
            policy: .lan(token: "ctl", watchToken: "ktw_w", trustedHosts: ["mac.tailnet.ts.net"]),
            port: 3418, tlsPort: nil,
            host: "mac.tailnet.ts.net", uri: "/api/lan?token=ktw_w"
        )
        XCTAssertEqual(body, #"{"ok":true,"enabled":true,"url":"http://mac.tailnet.ts.net:3418"}"#)
    }

    /// The full token through the same proxy: today's answer, both tokens.
    func testFullGradeThroughTheProxyGetsBothTokens() throws {
        let body = try lanResponse(
            policy: .lan(token: "ctl", watchToken: "ktw_w", trustedHosts: ["mac.tailnet.ts.net"]),
            port: 3418, tlsPort: nil,
            host: "mac.tailnet.ts.net", uri: "/api/lan?token=ctl"
        )
        XCTAssertEqual(
            body,
            #"{"ok":true,"enabled":true,"url":"http://mac.tailnet.ts.net:3418","token":"ctl","watchToken":"ktw_w"}"#
        )
    }

    /// The local human, loopback peer and loopback `Host`, no token: full
    /// grade, both tokens, as the share buttons rely on.
    func testTheLocalUserGetsBothTokens() throws {
        let body = try lanResponse(
            policy: .lan(token: "ctl", watchToken: "ktw_w", trustedHosts: ["mac.tailnet.ts.net"]),
            port: 3418, tlsPort: nil
        )
        XCTAssertEqual(
            body,
            #"{"ok":true,"enabled":true,"url":"http://mac.tailnet.ts.net:3418","token":"ctl","watchToken":"ktw_w"}"#
        )
    }

    /// No public name configured: unchanged behaviour, the LAN IP path.
    func testNoTrustedHostFallsBackToTheLanIP() throws {
        let body = try lanResponse(policy: .lan(token: "t"), port: 3418, tlsPort: nil)
        XCTAssertTrue(
            body.contains(#""enabled":true"#) || body.contains(#""enabled":false"#),
            "expected the legacy LAN shape, got \(body)"
        )
        XCTAssertFalse(body.contains("https://"), "no certificate, so no https link: \(body)")
    }
}
