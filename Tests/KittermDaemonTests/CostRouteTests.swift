import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/sessions/<id>/cost` against a real handler with a real session
/// in the registry, the way `AgentJoinRouteTests` drives the hook route: a
/// hook names a fixture transcript, and the route reads its bill.
final class CostRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var approvals: ApprovalStore!
    private var eventLog: EventLog!
    private var stateDir: URL!
    private var sessions: [PtySession] = []
    private var port: Int!

    private static let full = String(repeating: "f", count: 32)
    private static let watch = "ktw_" + String(repeating: "e", count: 32)
    private static let trustedHost = "box.example.test"

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: CostRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-cost-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLog = EventLog()
        registry = SessionRegistry(eventLog: eventLog)
        approvals = ApprovalStore()
        channel = try makeServer(policy: .loopbackOnly)
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        for session in sessions { session.terminate() }
        sessions = []
        try? channel?.close().wait()
        try? await group.shutdownGracefully()
        unsetenv("KITTERM_STATE_DIR")
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private func makeServer(policy: AccessPolicy) throws -> Channel {
        let registry = self.registry!
        let approvals = self.approvals!
        let eventLog = self.eventLog!
        return try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
                            policy: policy,
                            agentControl: false,
                            approvals: approvals,
                            eventLog: eventLog,
                            staticRoot: nil
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    // MARK: - The proof from plan.md row 2

    /// A session whose hook named the bill fixture answers its numbers, as
    /// written in the transcript, under the transcript's own names.
    func testTheBillOfASessionThatRanClaude() async throws {
        let id = try await spawn()
        let transcript = TranscriptBillTests.fixture("bill.jsonl")
        try await hook(id, run: "e89e7ec8-9e61-4900-800f-aa72ed555d63", transcript: transcript)

        let answer = try await request("GET", "/api/sessions/\(id.uuidString)/cost")
        XCTAssertEqual(answer.status, 200, answer.body)
        // Unrounded on the wire, not only in the decoded double.
        XCTAssertTrue(answer.body.contains("2.6361237500000003"), answer.body)
        XCTAssertTrue(answer.body.contains(transcript), "the path is not slash-escaped: \(answer.body)")

        let json = try json(answer.body)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["hasBill"] as? Bool, true)
        XCTAssertNil(json["reason"])
        XCTAssertEqual(json["agentSessionId"] as? String, "e89e7ec8-9e61-4900-800f-aa72ed555d63")
        XCTAssertEqual(json["agentTranscript"] as? String, transcript)
        let bill = try XCTUnwrap(json["bill"] as? [String: Any])
        XCTAssertEqual(bill["totalCostUSD"] as? Double, 2.6361237500000003)
        XCTAssertEqual(bill["totalDuration"] as? Int, 347686)
        XCTAssertEqual(bill["totalAPIDuration"] as? Int, 244888)
        XCTAssertEqual(bill["totalLinesAdded"] as? Int, 0)
        XCTAssertEqual(bill["totalLinesRemoved"] as? Int, 0)
        XCTAssertEqual(bill["startTime"] as? Int, 1788922267579)
        let usage = try XCTUnwrap(bill["modelUsage"] as? [String: [String: Any]])
        XCTAssertEqual(Set(usage.keys), ["claude-fable-5-1", "claude-haiku-4-5-20251001"])
        let fable = try XCTUnwrap(usage["claude-fable-5-1"])
        XCTAssertEqual(fable["inputTokens"] as? Int, 450)
        XCTAssertEqual(fable["outputTokens"] as? Int, 17680)
        XCTAssertEqual(fable["thinkingTokens"] as? Int, 9245)
        XCTAssertEqual(fable["cacheReadInputTokens"] as? Int, 1022235)
        XCTAssertEqual(fable["cacheCreationInputTokens"] as? Int, 74427)
        XCTAssertEqual(fable["costUSD"] as? Double, 2.6325987500000005)
    }

    /// A zeroed line is a bill of zero: `hasBill` is true, the tokens are
    /// zero by absence, and the wall-clock is the transcript's.
    func testAZeroedTranscriptIsABillOfZero() async throws {
        let id = try await spawn()
        try await hook(id, run: "dc95adb5-e73f-4760-b2e8-252cbc18563b", transcript: TranscriptBillTests.fixture("zeroed.jsonl"))

        let answer = try await request("GET", "/api/sessions/\(id.uuidString)/cost")
        XCTAssertEqual(answer.status, 200, answer.body)
        let json = try json(answer.body)
        XCTAssertEqual(json["hasBill"] as? Bool, true)
        let bill = try XCTUnwrap(json["bill"] as? [String: Any])
        XCTAssertEqual(bill["totalCostUSD"] as? Double, 0)
        XCTAssertEqual(bill["totalDuration"] as? Int, 32860487)
        XCTAssertEqual((bill["modelUsage"] as? [String: Any])?.count, 0)
    }

    /// A transcript cut mid-line is "no bill yet": 200, `hasBill: false`,
    /// and the reason, with no `bill` to mistake for zeros.
    func testATruncatedTranscriptIsNoBillYet() async throws {
        let id = try await spawn()
        try await hook(id, run: "e89e7ec8-9e61-4900-800f-aa72ed555d63", transcript: TranscriptBillTests.fixture("truncated.jsonl"))

        let answer = try await request("GET", "/api/sessions/\(id.uuidString)/cost")
        XCTAssertEqual(answer.status, 200, answer.body)
        let json = try json(answer.body)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["hasBill"] as? Bool, false)
        XCTAssertEqual(json["reason"] as? String, "lastLineIncomplete")
        XCTAssertNil(json["bill"])
        XCTAssertEqual(json["agentSessionId"] as? String, "e89e7ec8-9e61-4900-800f-aa72ed555d63")
    }

    // MARK: - The 404s

    func testASessionWithNoJoinIs404() async throws {
        let quiet = try await spawn()
        let answer = try await request("GET", "/api/sessions/\(quiet.uuidString)/cost")
        XCTAssertEqual(answer.status, 404, answer.body)
        XCTAssertEqual(try json(answer.body)["error"] as? String, "no transcript")

        let unknown = try await request("GET", "/api/sessions/\(UUID().uuidString)/cost")
        XCTAssertEqual(unknown.status, 404, unknown.body)
        XCTAssertEqual(try json(unknown.body)["error"] as? String, "no such session")

        let malformed = try await request("GET", "/api/sessions/not-a-uuid/cost")
        XCTAssertEqual(malformed.status, 404, malformed.body)
    }

    /// A transcript deleted after the session is a path that no longer
    /// resolves. That is 404 too, and the body names the path.
    func testADeletedTranscriptIs404WithThePath() async throws {
        let id = try await spawn()
        let gone = stateDir.appendingPathComponent("gone.jsonl").path
        try await hook(id, run: "e89e7ec8-9e61-4900-800f-aa72ed555d63", transcript: gone)

        let answer = try await request("GET", "/api/sessions/\(id.uuidString)/cost")
        XCTAssertEqual(answer.status, 404, answer.body)
        let json = try json(answer.body)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["error"] as? String, "transcript not found")
        XCTAssertEqual(json["agentTranscript"] as? String, gone)
        XCTAssertTrue((json["detail"] as? String)?.contains("No such file") == true, answer.body)
    }

    // MARK: - The grade

    /// A watch token gets 403; the full token through the same proxy gets
    /// the bill, which proves the 403 is about the grade and not the route.
    func testAWatchTokenIs403AndAFullTokenIsNot() async throws {
        let id = try await spawn()
        try await hook(id, run: "e89e7ec8-9e61-4900-800f-aa72ed555d63", transcript: TranscriptBillTests.fixture("bill.jsonl"))

        try? channel.close().wait()
        channel = try makeServer(
            policy: .proxied(token: Self.full, watchToken: Self.watch, trustedHosts: [Self.trustedHost])
        )
        port = channel.localAddress?.port

        let watched = try raw("GET", "/api/sessions/\(id.uuidString)/cost?token=\(Self.watch)")
        XCTAssertEqual(watched.status, 403, watched.body)
        XCTAssertTrue(watched.body.contains("watch-only"), watched.body)

        let full = try raw("GET", "/api/sessions/\(id.uuidString)/cost?token=\(Self.full)")
        XCTAssertEqual(full.status, 200, full.body)
        XCTAssertEqual(try json(full.body)["hasBill"] as? Bool, true)
    }

    // MARK: - Helpers

    private func spawn() async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        sessions.append(session)
        let id = await registry.register(session)
        return try XCTUnwrap(id)
    }

    /// A `Notification` hook, the shape Claude Code sends, naming a transcript.
    private func hook(_ id: UUID, run: String, transcript: String) async throws {
        let body = #"{"hook_event_name":"Notification","session_id":"\#(run)","transcript_path":"\#(transcript)","message":"Claude is waiting for your input"}"#
        let answer = try await request(
            "POST", "/api/hooks", body: body, headers: ["X-Kitterm-Session": id.uuidString]
        )
        XCTAssertEqual(answer.status, 200, answer.body)
    }

    private func request(
        _ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:]
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// One HTTP/1.1 request over a raw socket with `Host` set to the trusted
    /// host, so the policy reads it as a remote caller and grades the token.
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
