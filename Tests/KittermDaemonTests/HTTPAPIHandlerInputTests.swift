import KittermProtocol
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import KittermDaemon

/// The synchronous reject paths of `POST /api/sessions/<id>/input`, driven
/// through an `EmbeddedChannel`. Each returns before the async registry lookup,
/// so no event-loop task has to run — this exercises the `--agent-control` gate
/// and the request-body guards in isolation from a live session.
final class HTTPAPIHandlerInputTests: XCTestCase {
    private func makeChannel(agentControl: Bool, policy: AccessPolicy = .loopbackOnly) throws -> EmbeddedChannel {
        let handler = HTTPAPIHandler(
            registry: SessionRegistry(),
            policy: policy,
            agentControl: agentControl,
            staticRoot: nil
        )
        let channel = EmbeddedChannel(handler: handler)
        // A loopback peer so the access policy admits the request; the input
        // gate — not the policy — is what these tests are about.
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        return channel
    }

    /// Feed one POST as HTTP request parts and drain the response.
    private func post(
        _ channel: EmbeddedChannel,
        uri: String,
        body: [UInt8]?,
        host: String = "127.0.0.1"
    ) throws -> (status: HTTPResponseStatus, body: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: uri, headers: headers)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        if let body {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            try channel.writeInbound(HTTPServerRequestPart.body(buffer))
        }
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        var status: HTTPResponseStatus?
        var text = ""
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let responseHead):
                status = responseHead.status
            case .body(.byteBuffer(var buffer)):
                text += buffer.readString(length: buffer.readableBytes) ?? ""
            case .body(.fileRegion):
                break
            case .end:
                break
            }
        }
        return (status ?? .internalServerError, text)
    }

    private func validInputPath() -> String {
        "/api/sessions/\(UUID().uuidString)/input"
    }

    func testDisabledReturns403NamingTheFlag() throws {
        let channel = try makeChannel(agentControl: false)
        defer { _ = try? channel.finish() }
        let response = try post(channel, uri: validInputPath(), body: Array("hi".utf8))
        XCTAssertEqual(response.status, .forbidden)
        XCTAssertTrue(
            response.body.contains("--agent-control"),
            "403 should name the flag, got: \(response.body)"
        )
    }

    /// The first of the two refusals the fleet view's reply field can meet:
    /// a watch token. It is refused before the `--agent-control` gate, with
    /// the reason the page prints, and the same request with the full token
    /// gets past the grade check. Driven as a request naming a trusted host,
    /// because loopback is unconditionally full-grade.
    func testWatchGradeReturns403BeforeTheFlag() throws {
        let watch = "ktw_" + String(repeating: "e", count: 32)
        let full = String(repeating: "f", count: 32)
        let policy = AccessPolicy.proxied(token: full, watchToken: watch, trustedHosts: ["box.example.test"])
        let channel = try makeChannel(agentControl: true, policy: policy)
        defer { _ = try? channel.finish() }
        let path = validInputPath()

        let denied = try post(channel, uri: "\(path)?enter=1&token=\(watch)", body: Array("yes".utf8), host: "box.example.test")
        XCTAssertEqual(denied.status, .forbidden, denied.body)
        XCTAssertTrue(denied.body.contains("watch-only token"), "403 should name the grade, got: \(denied.body)")
        XCTAssertFalse(denied.body.contains("--agent-control"), "the grade is refused before the flag: \(denied.body)")

        // The full token passes the grade and the flag: the same request with
        // an empty body reaches the body guard, which answers synchronously.
        let admitted = try post(channel, uri: "\(path)?token=\(full)", body: nil, host: "box.example.test")
        XCTAssertEqual(admitted.status, .badRequest, admitted.body)
        XCTAssertTrue(admitted.body.contains("empty body"), admitted.body)
    }

    /// The second refusal: the daemon runs without `--agent-control`. The
    /// body names the flag, which is what the reply field holds every
    /// control with once it has seen it.
    func testDisabledNamesTheFlagWithEnter() throws {
        let channel = try makeChannel(agentControl: false)
        defer { _ = try? channel.finish() }
        let response = try post(channel, uri: "\(validInputPath())?enter=1", body: Array("yes".utf8))
        XCTAssertEqual(response.status, .forbidden)
        XCTAssertEqual(
            response.body,
            #"{"ok":false,"error":"agent control disabled; start the daemon with --agent-control"}"#
        )
    }

    func testEnabledEmptyBodyReturns400() throws {
        let channel = try makeChannel(agentControl: true)
        defer { _ = try? channel.finish() }
        let response = try post(channel, uri: validInputPath(), body: nil)
        XCTAssertEqual(response.status, .badRequest)
    }

    func testEnabledOversizeBodyReturns413() throws {
        let channel = try makeChannel(agentControl: true)
        defer { _ = try? channel.finish() }
        let big = [UInt8](repeating: UInt8(ascii: "a"), count: KittermConstants.maxInputBytes + 1)
        let response = try post(channel, uri: validInputPath(), body: big)
        XCTAssertEqual(response.status, .payloadTooLarge)
    }

    func testEnabledMalformedSessionIdReturns404() throws {
        let channel = try makeChannel(agentControl: true)
        defer { _ = try? channel.finish() }
        let response = try post(channel, uri: "/api/sessions/not-a-uuid/input", body: Array("hi".utf8))
        XCTAssertEqual(response.status, .notFound)
    }
}
