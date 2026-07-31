import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOWebSocket
import XCTest

@testable import KittermDaemon

/// Opening a session over a connection that already served an API request.
///
/// NIO's upgrade handler is one-shot per connection, and browsers never notice
/// because a WebSocket gets its own socket. A pooled HTTP client does: `GET
/// /ws` lands on a warm connection with no upgrader left and 404s.
///
/// These drive raw bytes through the real pipeline, since the bug was in
/// pipeline composition and nothing above that layer can see it.
final class UpgradeOnReusedConnectionTests: XCTestCase {
    /// Performs the handshake but installs nothing, so these test the pipeline
    /// without spawning a shell.
    private func makeUpgrader() -> NIOWebSocketServerUpgrader {
        NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeSucceededVoidFuture()
            }
        )
    }

    /// The daemon's real pipeline shape: `configureHTTPServerPipeline` with an
    /// upgrade configuration, then the API handler behind it.
    private func makeChannel(wireUpgraderIntoAPIHandler: Bool) throws -> EmbeddedChannel {
        let upgrader = makeUpgrader()
        let httpHandler = HTTPAPIHandler(
            registry: SessionRegistry(),
            policy: .loopbackOnly,
            staticRoot: nil,
            webSocketUpgrader: wireUpgraderIntoAPIHandler ? upgrader : nil
        )
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        let upgradeConfig = NIOHTTPServerUpgradeConfiguration(
            upgraders: [upgrader as any HTTPServerProtocolUpgrader],
            completionHandler: { context in
                _ = context.pipeline.removeHandler(httpHandler)
            }
        )
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
            withServerUpgrade: upgradeConfig
        )
        try channel.pipeline.syncOperations.addHandler(httpHandler)
        return channel
    }

    /// Write a raw request and read back whatever the server wrote, as text.
    @discardableResult
    private func exchange(_ channel: EmbeddedChannel, _ request: String) throws -> String {
        var inbound = channel.allocator.buffer(capacity: request.utf8.count)
        inbound.writeString(request)
        try channel.writeInbound(inbound)
        // The upgrade handshake completes through futures on this loop, so
        // drain it before reading. Everything here stays on the calling
        // thread — see `plainRequest` for why that constrains the route.
        channel.embeddedEventLoop.run()

        var response = ""
        while var out = try channel.readOutbound(as: ByteBuffer.self) {
            response += out.readString(length: out.readableBytes) ?? ""
        }
        return response
    }

    /// Consumes the connection's one-shot upgrader. The route has to keep the
    /// connection alive (error paths answer `Connection: close`) and answer on
    /// the calling thread — the registry routes complete from a concurrency
    /// thread, which `EmbeddedEventLoop` rejects. `/api/lan` does both.
    private let plainRequest = """
        GET /api/lan HTTP/1.1\r
        Host: 127.0.0.1\r
        \r

        """

    private let upgradeRequest = """
        GET /ws HTTP/1.1\r
        Host: 127.0.0.1\r
        Connection: Upgrade\r
        Upgrade: websocket\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        \r

        """

    /// The regression: an upgrade arriving second on a keep-alive connection.
    func testUpgradeSucceedsAfterAnAPIRequestOnTheSameConnection() throws {
        let channel = try makeChannel(wireUpgraderIntoAPIHandler: true)
        defer { _ = try? channel.finish() }

        let plain = try exchange(channel, plainRequest)
        XCTAssertTrue(plain.contains("200 OK"), "expected the first request to be served, got: \(plain)")

        let upgrade = try exchange(channel, upgradeRequest)
        XCTAssertTrue(
            upgrade.contains("101 Switching Protocols"),
            """
            a session must open on a connection that already served the API — \
            this is what a pooled HTTP client does. Got: \(upgrade)
            """
        )
        XCTAssertTrue(
            upgrade.lowercased().contains("sec-websocket-accept"),
            "the handshake must be completed, not merely acknowledged"
        )
    }

    /// Several API calls first — the orchestrator shape.
    func testUpgradeSucceedsAfterSeveralAPIRequests() throws {
        let channel = try makeChannel(wireUpgraderIntoAPIHandler: true)
        defer { _ = try? channel.finish() }

        for _ in 0..<3 {
            XCTAssertTrue(try exchange(channel, plainRequest).contains("200 OK"))
        }
        XCTAssertTrue(try exchange(channel, upgradeRequest).contains("101 Switching Protocols"))
    }

    /// The unchanged path: a first-request upgrade never touches the reinstall.
    func testUpgradeAsFirstRequestStillWorks() throws {
        let channel = try makeChannel(wireUpgraderIntoAPIHandler: true)
        defer { _ = try? channel.finish() }
        XCTAssertTrue(try exchange(channel, upgradeRequest).contains("101 Switching Protocols"))
    }

    /// Pins the cause: without the reinstall, the second request 404s. If this
    /// starts failing, NIO changed and the reinstall may be redundant.
    func testWithoutReinstallTheSecondUpgrade404s() throws {
        let channel = try makeChannel(wireUpgraderIntoAPIHandler: false)
        defer { _ = try? channel.finish() }

        XCTAssertTrue(try exchange(channel, plainRequest).contains("200 OK"))
        let upgrade = try exchange(channel, upgradeRequest)
        XCTAssertFalse(upgrade.contains("101"), "unexpectedly upgraded: \(upgrade)")
        XCTAssertTrue(upgrade.contains("404"), "expected the fall-through 404, got: \(upgrade)")
    }
}
