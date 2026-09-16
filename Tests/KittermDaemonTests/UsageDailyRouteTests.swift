import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/usage/daily` against a real handler over a rollup built from
/// the three apportionment fixtures and one retained record older than any
/// of them, the way `PushSubscriptionRouteTests` drives its store. The grade
/// case runs over a raw socket naming the trusted host, because loopback is
/// full grade unconditionally.
final class UsageDailyRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var scratch: URL!
    private var rollup: UsageRollup!
    private var port: Int!

    private static let full = String(repeating: "f", count: 32)
    private static let watch = "ktw_" + String(repeating: "e", count: 32)
    private static let trustedHost = "box.example.test"
    static let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-usage-route-\(UUID().uuidString)", isDirectory: true)
        let root = scratch.appendingPathComponent("projects", isDirectory: true)
        let dir = root.appendingPathComponent("-nonexistent-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["one-day", "midnight", "unbilled"] {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: TranscriptBillTests.fixture("\(name).jsonl")),
                to: dir.appendingPathComponent("\(name).jsonl")
            )
        }
        let file = scratch.appendingPathComponent("usage-daily.json")
        try """
        {"version":1,"timeZone":"Asia/Ho_Chi_Minh","refreshedAt":1767600000000,"sessions":{
          "-gone-project/aaaaaaaa-0000-4000-8000-000000000000.jsonl":{
            "sessionId":"aaaaaaaa-0000-4000-8000-000000000000","cwd":"/gone/project",
            "project":{"id":"project","name":"project","root":"/gone/project","registered":false},
            "size":1234,"mtime":1767571200000,"subagentFiles":0,"subagentBytes":0,
            "billed":true,"totalCostUSD":9.5,"startDay":"2026-01-05",
            "days":{"2026-01-05":{"input":10,"output":500,"cacheCreation":2000,"cacheRead":40000,"requests":7}}}}}
        """.write(to: file, atomically: true, encoding: .utf8)
        rollup = UsageRollup(
            file: file, transcriptsRoot: root,
            projects: ProjectStore(url: scratch.appendingPathComponent("projects.json")), zone: Self.saigon
        )
        rollup.refresh()

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channel = try makeServer(rollup: rollup)
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        try? channel?.close().wait()
        try? await group.shutdownGracefully()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeServer(rollup: UsageRollup?, policy: AccessPolicy = .loopbackOnly) throws -> Channel {
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
                            usageRollup: rollup
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    // MARK: - The range

    func testTheRangeAnswersOneEntryPerDayWithTheSplit() async throws {
        let answer = try await request("GET", "/api/usage/daily?from=2026-09-09&to=2026-09-12")
        XCTAssertEqual(answer.status, 200, answer.body)
        XCTAssertTrue(answer.body.contains("/nonexistent/fixture-project"), "roots keep their slashes: \(answer.body)")
        let json = try json(answer.body)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["timeZone"] as? String, "Asia/Ho_Chi_Minh")
        XCTAssertEqual(json["from"] as? String, "2026-09-09")
        XCTAssertEqual(json["to"] as? String, "2026-09-12")
        XCTAssertEqual(json["recordedSessions"] as? Int, 4)
        XCTAssertGreaterThan(json["refreshedAt"] as? Int ?? 0, 1767600000000)
        let days = try XCTUnwrap(json["days"] as? [[String: Any]])
        XCTAssertEqual(days.map { $0["day"] as? String }, ["2026-09-09", "2026-09-10", "2026-09-11", "2026-09-12"])
        XCTAssertEqual(days[0]["costUSD"] as? Double, 0)
        XCTAssertEqual(days[1]["costUSD"] as? Double ?? 0, 6.0, accuracy: 1e-12)
        XCTAssertEqual(days[1]["apportionedUSD"] as? Double ?? 0, 3.0, accuracy: 1e-12)
        XCTAssertEqual(days[1]["sessions"] as? Int, 2)
        let tokens = try XCTUnwrap(days[1]["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["cacheRead"] as? Int, 18000 + 3600)
        XCTAssertEqual(tokens["requests"] as? Int, 5)
        let projects = try XCTUnwrap(days[1]["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0]["id"] as? String, "fixture-project")
        XCTAssertEqual(projects[0]["registered"] as? Bool, false)
        XCTAssertEqual(days[2]["apportionedUSD"] as? Double ?? 0, 1.0, accuracy: 1e-12)
        XCTAssertEqual(days[3]["unbilledSessions"] as? Int, 1)
        XCTAssertEqual(days[3]["costUSD"] as? Double, 0)
        let totals = try XCTUnwrap(json["totals"] as? [String: Any])
        XCTAssertEqual(totals["costUSD"] as? Double ?? 0, 7.0, accuracy: 1e-12)
        XCTAssertEqual(totals["unbilledSessions"] as? Int, 1)
        let ranged = try XCTUnwrap(json["projects"] as? [[String: Any]])
        XCTAssertEqual(ranged.count, 1)
        XCTAssertEqual(ranged[0]["root"] as? String, "/nonexistent/fixture-project")
        XCTAssertEqual(ranged[0]["costUSD"] as? Double ?? 0, 7.0, accuracy: 1e-12)
    }

    /// The proof from `plan.md` row 4 and the corpus request: a range whose
    /// days are all before the oldest transcript still draws, from the
    /// rollup.
    func testARangeEntirelyBeforeTheOldestTranscriptDrawsFromTheRollup() async throws {
        let answer = try await request("GET", "/api/usage/daily?from=2026-01-01&to=2026-01-07")
        XCTAssertEqual(answer.status, 200, answer.body)
        let json = try json(answer.body)
        let days = try XCTUnwrap(json["days"] as? [[String: Any]])
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[4]["day"] as? String, "2026-01-05")
        XCTAssertEqual(days[4]["costUSD"] as? Double, 9.5)
        XCTAssertEqual(days[4]["apportionedUSD"] as? Double, 0)
        let projects = try XCTUnwrap(days[4]["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.first?["root"] as? String, "/gone/project")
        XCTAssertEqual((json["totals"] as? [String: Any])?["costUSD"] as? Double, 9.5)
        XCTAssertEqual((json["totals"] as? [String: Any])?["sessions"] as? Int, 1)
    }

    func testTheDefaultRangeIsTheLastThirtyDaysEndingToday() async throws {
        let answer = try await request("GET", "/api/usage/daily")
        XCTAssertEqual(answer.status, 200, answer.body)
        let json = try json(answer.body)
        let today = DayKey(Date(), in: Self.saigon)
        XCTAssertEqual(json["to"] as? String, today.description)
        XCTAssertEqual(json["from"] as? String, today.advanced(by: -29).description)
        XCTAssertEqual((json["days"] as? [[String: Any]])?.count, 30)
    }

    func testABadRangeIs400WithTheReason() async throws {
        for (query, reason) in [
            ("?from=2026-9-1", "from must be a day, YYYY-MM-DD"),
            ("?to=yesterday", "to must be a day, YYYY-MM-DD"),
            ("?from=2026-09-12&to=2026-09-10", "from must not be after to"),
            ("?from=2025-01-01&to=2026-09-16", "range must be at most 400 days"),
        ] {
            let answer = try await request("GET", "/api/usage/daily\(query)")
            XCTAssertEqual(answer.status, 400, query)
            XCTAssertEqual(try json(answer.body)["error"] as? String, reason, query)
        }
    }

    // MARK: - The grade, and no store

    func testAWatchTokenIs403AndAFullTokenIsNot() throws {
        try? channel.close().wait()
        channel = try makeServer(
            rollup: rollup,
            policy: .proxied(token: Self.full, watchToken: Self.watch, trustedHosts: [Self.trustedHost])
        )
        port = channel.localAddress?.port

        let watched = try raw("GET", "/api/usage/daily?token=\(Self.watch)")
        XCTAssertEqual(watched.status, 403, watched.body)
        XCTAssertTrue(watched.body.contains("watch-only"), watched.body)

        let full = try raw("GET", "/api/usage/daily?from=2026-09-10&to=2026-09-10&token=\(Self.full)")
        XCTAssertEqual(full.status, 200, full.body)
        XCTAssertEqual(try json(full.body)["ok"] as? Bool, true)
    }

    func testAHandlerWithoutARollupAnswers503() async throws {
        try? channel.close().wait()
        channel = try makeServer(rollup: nil)
        port = channel.localAddress?.port
        let answer = try await request("GET", "/api/usage/daily")
        XCTAssertEqual(answer.status, 503, answer.body)
        XCTAssertEqual(try json(answer.body)["error"] as? String, "usage rollup unavailable")
    }

    // MARK: - Helpers

    private func request(_ method: String, _ path: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

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
        let text = String(decoding: received, as: UTF8.self)
        let status = Int(text.split(separator: " ", maxSplits: 2).dropFirst().first ?? "") ?? 0
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return (status, body)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }
}
