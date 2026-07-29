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
    private func lanResponse(policy: AccessPolicy, port: Int, tlsPort: Int?) throws -> String {
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
        headers.add(name: "Host", value: "127.0.0.1")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/api/lan", headers: headers)
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
