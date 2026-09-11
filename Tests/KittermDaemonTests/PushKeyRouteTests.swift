import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/push/vapid`: the public key a page subscribes with, and the
/// grade gate. The key is not a secret; the gate is the feature's boundary,
/// so a watch token gets the same 403 it gets from the subscription routes.
final class PushKeyRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private let keys = VAPIDKeys()

    private static let full = String(repeating: "f", count: 32)
    private static let watch = "ktw_" + String(repeating: "e", count: 32)
    private static let trustedHost = "box.example.test"

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channel = try makeServer(keys: keys)
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        try? channel.close().wait()
        try? await group.shutdownGracefully()
    }

    private func makeServer(keys: VAPIDKeys?, policy: AccessPolicy = .loopbackOnly) throws -> Channel {
        try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: SessionRegistry(),
                            policy: policy,
                            agentControl: false,
                            staticRoot: nil,
                            vapidKeys: keys
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    /// The answer is the same base64url the `k=` of every message carries,
    /// so the browser binds its subscription to the key the daemon signs with.
    func testAnswersThePublicKeyThePairSignsWith() async throws {
        let answer = try await request("GET", "/api/push/vapid")
        XCTAssertEqual(answer.status, 200, answer.body)
        let json = try self.json(answer.body)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["publicKey"] as? String, keys.publicKeyBase64URL)
        let raw = try XCTUnwrap(WebPush.base64URLDecode(keys.publicKeyBase64URL))
        XCTAssertEqual(raw.count, 65)
        XCTAssertEqual(raw.first, 0x04)
        let signed = try XCTUnwrap(keys.authorization(for: URL(string: "https://push.example.test/x")!))
        XCTAssertTrue(signed.hasSuffix("k=\(keys.publicKeyBase64URL)"), signed)
    }

    func testAHandlerWithoutAPairAnswers503() async throws {
        try? channel.close().wait()
        channel = try makeServer(keys: nil)
        port = channel.localAddress?.port
        let answer = try await request("GET", "/api/push/vapid")
        XCTAssertEqual(answer.status, 503, answer.body)
    }

    /// A watch client cannot subscribe, so it does not get the key to try.
    func testAWatchTokenIs403AndAFullTokenIsNot() throws {
        try? channel.close().wait()
        channel = try makeServer(
            keys: keys,
            policy: .proxied(token: Self.full, watchToken: Self.watch, trustedHosts: [Self.trustedHost])
        )
        port = channel.localAddress?.port

        let watch = try raw("GET", "/api/push/vapid?token=\(Self.watch)")
        XCTAssertEqual(watch.status, 403, watch.body)
        XCTAssertTrue(watch.body.contains("watch-only"), watch.body)
        XCTAssertFalse(watch.body.contains(keys.publicKeyBase64URL))

        let none = try raw("GET", "/api/push/vapid")
        XCTAssertEqual(none.status, 403, none.body)

        let full = try raw("GET", "/api/push/vapid?token=\(Self.full)")
        XCTAssertEqual(full.status, 200, full.body)
        XCTAssertTrue(full.body.contains(keys.publicKeyBase64URL), full.body)
    }

    // MARK: - Helpers

    /// One HTTP/1.1 request over a raw socket with `Host` set to the trusted
    /// host, so the policy reads it as a remote caller; URLSession will not
    /// set `Host`.
    private func raw(_ method: String, _ target: String) throws -> (status: Int, body: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connect failed: errno \(errno)")
        let lines = ["\(method) \(target) HTTP/1.1", "Host: \(Self.trustedHost)", "Connection: close"]
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        request.withUnsafeBytes { XCTAssertEqual(send(fd, $0.baseAddress, $0.count, 0), request.count) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        guard let split = received.range(of: Data("\r\n\r\n".utf8)) else {
            XCTFail("no header block in \(String(decoding: received, as: UTF8.self))")
            return (0, "")
        }
        let head = String(decoding: received[..<split.lowerBound], as: UTF8.self).split(separator: "\r\n")
        let status = Int(head.first?.split(separator: " ").dropFirst().first ?? "0") ?? 0
        return (status, String(decoding: received[split.upperBound...], as: UTF8.self))
    }

    private func request(_ method: String, _ path: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }
}
