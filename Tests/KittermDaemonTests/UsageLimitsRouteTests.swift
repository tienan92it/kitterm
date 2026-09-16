import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `POST` and `GET /api/usage/limits` against a real handler over a
/// `UsageLimitsStore` in a scratch directory: the post, the read-back with
/// its age, the daemon that was never given a reading, the stale one, the
/// refusals, and the grade, the way `UsageDailyRouteTests` drives its
/// rollup. The grade case runs over a raw socket naming the trusted host,
/// because loopback is full grade unconditionally.
final class UsageLimitsRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var scratch: URL!
    private var store: UsageLimitsStore!
    private var port: Int!

    private static let full = String(repeating: "f", count: 32)
    private static let watch = "ktw_" + String(repeating: "e", count: 32)
    private static let trustedHost = "box.example.test"

    /// What `jq -c '.rate_limits'` prints from a statusline render.
    private static let body = #"""
        {"five_hour":{"used_percentage":23.5,"resets_at":1789000000},"seven_day":{"used_percentage":41.2,"resets_at":1789400000},"spend_limit":{"used_percentage":62.8,"resets_at":1790000000}}
        """#

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-limits-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = UsageLimitsStore(file: file)
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channel = try makeServer(store: store)
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        try? channel?.close().wait()
        try? await group.shutdownGracefully()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private var file: URL { scratch.appendingPathComponent("usage-limits.json") }

    private func makeServer(store: UsageLimitsStore?, policy: AccessPolicy = .loopbackOnly) throws -> Channel {
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
                            usageLimits: store
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    // MARK: - Post, then get

    func testAPostIsKeptAndReadBackWithItsAge() async throws {
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let posted = try await request("POST", "/api/usage/limits", body: Self.body)
        XCTAssertEqual(posted.status, 200, posted.body)
        let receipt = try json(posted.body)
        XCTAssertEqual(receipt["ok"] as? Bool, true)
        XCTAssertEqual(receipt["windows"] as? Int, 3)
        let receivedAt = try XCTUnwrap(receipt["receivedAt"] as? Int64)
        XCTAssertGreaterThanOrEqual(receivedAt, before)

        let read = try await request("GET", "/api/usage/limits")
        XCTAssertEqual(read.status, 200, read.body)
        let answer = try json(read.body)
        XCTAssertEqual(answer["ok"] as? Bool, true)
        XCTAssertEqual(answer["hasReading"] as? Bool, true)
        XCTAssertEqual(answer["receivedAt"] as? Int64, receivedAt)
        XCTAssertEqual(answer["stale"] as? Bool, false)
        XCTAssertLessThan(answer["ageSeconds"] as? Int ?? 99, 5)
        let limits = try XCTUnwrap(answer["rateLimits"] as? [String: [String: Any]])
        XCTAssertEqual(Set(limits.keys), ["five_hour", "seven_day", "spend_limit"])
        XCTAssertEqual(limits["five_hour"]?["used_percentage"] as? Double, 23.5)
        XCTAssertEqual(limits["five_hour"]?["resets_at"] as? Int, 1_789_000_000)
        XCTAssertEqual(limits["spend_limit"]?["used_percentage"] as? Double, 62.8)

        // The file carries what a restart reads back, owner-only.
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        let reloaded = UsageLimitsStore(file: file)
        XCTAssertEqual(reloaded.reading, store.reading)
    }

    /// The newest post wins, whichever session it came from: the quota is
    /// the account's, and a window the source dropped is gone.
    func testTheNewestPostReplacesTheLast() async throws {
        _ = try await request("POST", "/api/usage/limits", body: Self.body)
        let second = try await request(
            "POST", "/api/usage/limits", body: #"{"five_hour":{"used_percentage":30,"resets_at":1789000000}}"#
        )
        XCTAssertEqual(second.status, 200, second.body)
        let read = try json(try await request("GET", "/api/usage/limits").body)
        let limits = try XCTUnwrap(read["rateLimits"] as? [String: [String: Any]])
        XCTAssertEqual(Array(limits.keys), ["five_hour"])
        XCTAssertEqual(limits["five_hour"]?["used_percentage"] as? Double, 30)
    }

    /// An API-key account, or a session before its first response, is
    /// given no window. That is a reading too, and the page says so.
    func testAnEmptyObjectIsAReadingWithNoWindow() async throws {
        let posted = try await request("POST", "/api/usage/limits", body: "{}")
        XCTAssertEqual(posted.status, 200, posted.body)
        XCTAssertEqual(try json(posted.body)["windows"] as? Int, 0)
        let read = try json(try await request("GET", "/api/usage/limits").body)
        XCTAssertEqual(read["hasReading"] as? Bool, true)
        XCTAssertEqual((read["rateLimits"] as? [String: Any])?.count, 0)
    }

    // MARK: - Absent and stale

    func testADaemonNeverGivenAReadingSaysSo() async throws {
        let read = try await request("GET", "/api/usage/limits")
        XCTAssertEqual(read.status, 200, read.body)
        let answer = try json(read.body)
        XCTAssertEqual(answer["ok"] as? Bool, true)
        XCTAssertEqual(answer["hasReading"] as? Bool, false)
        XCTAssertNil(answer["rateLimits"])
        XCTAssertNil(answer["ageSeconds"])
        XCTAssertNil(answer["stale"])
    }

    /// A reading two hours old is served with its age and marked stale;
    /// the body is built from a fixed clock so the case is the same on any
    /// day. The route's own clock is `Date()`, so the store is driven
    /// directly here and the threshold is checked on both sides.
    func testAReadingPastAnHourIsStale() throws {
        let posted = Date(timeIntervalSince1970: 1_789_000_000)
        let reading = try XCTUnwrap(
            try UsageLimits.parse(
                JSONSerialization.jsonObject(with: Data(Self.body.utf8)) as! [String: Any], now: posted
            ).get()
        )
        store.record(reading)

        let fresh = try json(HTTPAPIHandler.usageLimitsBody(store.reading, now: posted.addingTimeInterval(240)))
        XCTAssertEqual(fresh["ageSeconds"] as? Int, 240)
        XCTAssertEqual(fresh["stale"] as? Bool, false)

        let edge = try json(HTTPAPIHandler.usageLimitsBody(store.reading, now: posted.addingTimeInterval(3600)))
        XCTAssertEqual(edge["stale"] as? Bool, false, "an hour exactly is not yet past an hour")

        let stale = try json(HTTPAPIHandler.usageLimitsBody(store.reading, now: posted.addingTimeInterval(7200)))
        XCTAssertEqual(stale["hasReading"] as? Bool, true)
        XCTAssertEqual(stale["ageSeconds"] as? Int, 7200)
        XCTAssertEqual(stale["stale"] as? Bool, true)
        XCTAssertEqual(((stale["rateLimits"] as? [String: Any])?["seven_day"] as? [String: Any])?["used_percentage"] as? Double, 41.2)

        // A restart keeps the reading and therefore its true age.
        let reloaded = UsageLimitsStore(file: file)
        XCTAssertEqual(reloaded.reading?.receivedAt, 1_789_000_000_000)
        XCTAssertEqual(reloaded.reading?.age(now: posted.addingTimeInterval(7200)), 7200)
    }

    // MARK: - Refusals

    func testABadBodyIs400WithTheReason() async throws {
        for (body, reason) in [
            ("[]", "body must be the rate_limits object"),
            ("not json", "body must be the rate_limits object"),
            (#"{"five_hour":5}"#, "five_hour must be {used_percentage, resets_at}"),
            (#"{"five_hour":{"used_percentage":-1,"resets_at":1789000000}}"#, "five_hour.used_percentage must be a non-negative number"),
            (#"{"five_hour":{"used_percentage":true,"resets_at":1789000000}}"#, "five_hour.used_percentage must be a non-negative number"),
            (#"{"five_hour":{"used_percentage":5}}"#, "five_hour.resets_at must be epoch seconds"),
            (#"{"five_hour":{"used_percentage":5,"resets_at":"soon"}}"#, "five_hour.resets_at must be epoch seconds"),
            (#"{"five_hour":{"used_percentage":5,"resets_at":1789000000000}}"#, "five_hour.resets_at must be epoch seconds"),
            (#"{"Five Hour":{"used_percentage":5,"resets_at":1789000000}}"#, "window keys are lowercase words, like five_hour"),
        ] {
            let answer = try await request("POST", "/api/usage/limits", body: body)
            XCTAssertEqual(answer.status, 400, body)
            XCTAssertEqual(try json(answer.body)["error"] as? String, reason, body)
        }
        let read = try json(try await request("GET", "/api/usage/limits").body)
        XCTAssertEqual(read["hasReading"] as? Bool, false, "a refused post leaves nothing behind")
    }

    func testABodyOverTheCapIs413() async throws {
        let padding = String(repeating: " ", count: UsageLimits.maxBodyBytes)
        let answer = try await request("POST", "/api/usage/limits", body: padding + "{}")
        XCTAssertEqual(answer.status, 413, answer.body)
    }

    func testAWatchTokenIs403OnBothAndAFullTokenIsNot() throws {
        try? channel.close().wait()
        channel = try makeServer(
            store: store,
            policy: .proxied(token: Self.full, watchToken: Self.watch, trustedHosts: [Self.trustedHost])
        )
        port = channel.localAddress?.port

        let watchedPost = try raw("POST", "/api/usage/limits?token=\(Self.watch)", body: Self.body)
        XCTAssertEqual(watchedPost.status, 403, watchedPost.body)
        XCTAssertTrue(watchedPost.body.contains("watch-only"), watchedPost.body)
        let watchedGet = try raw("GET", "/api/usage/limits?token=\(Self.watch)")
        XCTAssertEqual(watchedGet.status, 403, watchedGet.body)
        XCTAssertNil(store.reading, "a watch post stores nothing")

        let fullPost = try raw("POST", "/api/usage/limits?token=\(Self.full)", body: Self.body)
        XCTAssertEqual(fullPost.status, 200, fullPost.body)
        let fullGet = try raw("GET", "/api/usage/limits?token=\(Self.full)")
        XCTAssertEqual(fullGet.status, 200, fullGet.body)
        XCTAssertEqual(try json(fullGet.body)["hasReading"] as? Bool, true)
    }

    func testAHandlerWithoutAStoreAnswers503() async throws {
        try? channel.close().wait()
        channel = try makeServer(store: nil)
        port = channel.localAddress?.port
        let read = try await request("GET", "/api/usage/limits")
        XCTAssertEqual(read.status, 503, read.body)
        XCTAssertEqual(try json(read.body)["error"] as? String, "usage limits unavailable")
        let posted = try await request("POST", "/api/usage/limits", body: Self.body)
        XCTAssertEqual(posted.status, 503, posted.body)
    }

    // MARK: - Helpers

    private func request(_ method: String, _ path: String, body: String? = nil) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func raw(_ method: String, _ target: String, body: String? = nil) throws -> (status: Int, body: String) {
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
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(Self.trustedHost)", "Connection: close"]
        if let body {
            lines.append("Content-Type: application/json")
            lines.append("Content-Length: \(body.utf8.count)")
        }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + (body ?? "")).utf8)
        request.withUnsafeBytes { XCTAssertEqual(send(fd, $0.baseAddress, $0.count, 0), request.count) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        let text = String(decoding: received, as: UTF8.self)
        let status = Int(text.split(separator: " ", maxSplits: 2).dropFirst().first ?? "") ?? 0
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return (status, body)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }
}
