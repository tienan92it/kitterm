import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/archives/<id>/cost` against a real handler: a hook names a
/// fixture transcript, the session is archived through the archive route,
/// and the archive's cost route reads the bill the archive's join names.
/// The order matters and the test pins it: once archived, the live route
/// answers 404 and the archive route answers the bill.
final class ArchiveCostRouteTests: XCTestCase {
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
    private static let run = "e89e7ec8-9e61-4900-800f-aa72ed555d63"

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: ArchiveCostRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-archive-cost-\(UUID().uuidString)", isDirectory: true)
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
                            agentControl: true,
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

    // MARK: - The proof from plan.md row 4

    /// Archive, then read: the archived session's bill comes back in the
    /// shape of the session route, with the transcript's own numbers, and
    /// the live route no longer answers for the session.
    func testTheBillOfAnArchivedSession() async throws {
        let id = try await spawn()
        let transcript = TranscriptBillTests.fixture("bill.jsonl")
        try await hook(id, transcript: transcript)

        let live = try await request("GET", "/api/sessions/\(id.uuidString)/cost")
        XCTAssertEqual(live.status, 200, live.body)

        let archived = try await request("POST", "/api/sessions/\(id.uuidString)/archive")
        XCTAssertEqual(archived.status, 200, archived.body)
        XCTAssertEqual(try json(archived.body)["ok"] as? Bool, true)

        let gone = try await request("GET", "/api/sessions/\(id.uuidString)/cost")
        XCTAssertEqual(gone.status, 404, "the live route after archiving: \(gone.body)")
        XCTAssertEqual(try json(gone.body)["error"] as? String, "no such session")

        let answer = try await request("GET", "/api/archives/\(id.uuidString)/cost")
        XCTAssertEqual(answer.status, 200, answer.body)
        XCTAssertTrue(answer.body.contains("2.6361237500000003"), "unrounded on the wire: \(answer.body)")
        let json = try json(answer.body)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["hasBill"] as? Bool, true)
        XCTAssertNil(json["reason"])
        XCTAssertEqual(json["agentSessionId"] as? String, Self.run)
        XCTAssertEqual(json["agentTranscript"] as? String, transcript)
        let bill = try XCTUnwrap(json["bill"] as? [String: Any])
        XCTAssertEqual(bill["totalCostUSD"] as? Double, 2.6361237500000003)
        XCTAssertEqual(bill["totalDuration"] as? Int, 347686)
        XCTAssertEqual(bill["totalAPIDuration"] as? Int, 244888)
        let usage = try XCTUnwrap(bill["modelUsage"] as? [String: [String: Any]])
        XCTAssertEqual(Set(usage.keys), ["claude-fable-5-1", "claude-haiku-4-5-20251001"])
        XCTAssertEqual(usage["claude-fable-5-1"]?["cacheReadInputTokens"] as? Int, 1022235)
        XCTAssertEqual(
            Set(json.keys), Set(try self.json(live.body).keys),
            "the same shape as the session route"
        )
    }

    /// A finished session whose bill sits behind the `queue-operation`
    /// lines Claude Code appends at exit answers the bill, not "no bill
    /// yet" (round 19 of `agent-dashboard`; archive `F64B8927…` on the
    /// real machine read as unbilled for that).
    func testABillBehindTrailingLinesIsABill() async throws {
        let transcript = stateDir.appendingPathComponent("trailing.jsonl")
        let fixture = try String(contentsOfFile: TranscriptBillTests.fixture("bill.jsonl"), encoding: .utf8)
        try (fixture + TranscriptBillTests.queueEnqueue + "\n" + TranscriptBillTests.queueDequeue + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let id = try await spawn()
        try await hook(id, transcript: transcript.path)
        _ = try await request("POST", "/api/sessions/\(id.uuidString)/archive")

        let answer = try await request("GET", "/api/archives/\(id.uuidString)/cost")
        XCTAssertEqual(answer.status, 200, answer.body)
        let json = try json(answer.body)
        XCTAssertEqual(json["hasBill"] as? Bool, true, answer.body)
        XCTAssertEqual(json["estimated"] as? Bool, false)
        XCTAssertNil(json["reason"])
        let bill = try XCTUnwrap(json["bill"] as? [String: Any])
        XCTAssertEqual(bill["totalCostUSD"] as? Double, 2.6361237500000003)
    }

    /// A transcript cut mid-line is "no bill yet" on the archive route too.
    func testATruncatedTranscriptIsNoBillYet() async throws {
        let id = try await spawn()
        try await hook(id, transcript: TranscriptBillTests.fixture("truncated.jsonl"))
        _ = try await request("POST", "/api/sessions/\(id.uuidString)/archive")

        let answer = try await request("GET", "/api/archives/\(id.uuidString)/cost")
        XCTAssertEqual(answer.status, 200, answer.body)
        let json = try json(answer.body)
        XCTAssertEqual(json["hasBill"] as? Bool, false)
        XCTAssertEqual(json["reason"] as? String, "lastLineIncomplete")
        XCTAssertNil(json["bill"])
    }

    // MARK: - The 404s

    /// An archive of a session that never ran `claude` has no transcript;
    /// an id with no archive is no such archive; a malformed id is 404.
    func testAnArchiveWithNoJoinIs404() async throws {
        let quiet = try await spawn()
        _ = try await request("POST", "/api/sessions/\(quiet.uuidString)/archive")
        let answer = try await request("GET", "/api/archives/\(quiet.uuidString)/cost")
        XCTAssertEqual(answer.status, 404, answer.body)
        XCTAssertEqual(try json(answer.body)["error"] as? String, "no transcript")

        let unknown = try await request("GET", "/api/archives/\(UUID().uuidString)/cost")
        XCTAssertEqual(unknown.status, 404, unknown.body)
        XCTAssertEqual(try json(unknown.body)["error"] as? String, "no such archive")

        let malformed = try await request("GET", "/api/archives/not-a-uuid/cost")
        XCTAssertEqual(malformed.status, 404, malformed.body)
    }

    /// A transcript deleted after the archive is a path that no longer
    /// resolves: 404 with the path, like the session route.
    func testADeletedTranscriptIs404WithThePath() async throws {
        let id = try await spawn()
        let gone = stateDir.appendingPathComponent("gone.jsonl").path
        try await hook(id, transcript: gone)
        _ = try await request("POST", "/api/sessions/\(id.uuidString)/archive")

        let answer = try await request("GET", "/api/archives/\(id.uuidString)/cost")
        XCTAssertEqual(answer.status, 404, answer.body)
        let json = try json(answer.body)
        XCTAssertEqual(json["error"] as? String, "transcript not found")
        XCTAssertEqual(json["agentTranscript"] as? String, gone)
    }

    // MARK: - The grade

    /// A watch token gets 403; the full token through the same proxy gets
    /// the bill. The archive detail route stays readable at any grade, so
    /// the 403 is the cost route's own.
    func testAWatchTokenIs403AndAFullTokenIsNot() async throws {
        let id = try await spawn()
        try await hook(id, transcript: TranscriptBillTests.fixture("bill.jsonl"))
        _ = try await request("POST", "/api/sessions/\(id.uuidString)/archive")

        try? channel.close().wait()
        channel = try makeServer(
            policy: .proxied(token: Self.full, watchToken: Self.watch, trustedHosts: [Self.trustedHost])
        )
        port = channel.localAddress?.port

        let watched = try raw("GET", "/api/archives/\(id.uuidString)/cost?token=\(Self.watch)")
        XCTAssertEqual(watched.status, 403, watched.body)
        XCTAssertTrue(watched.body.contains("watch-only"), watched.body)

        let detail = try raw("GET", "/api/archives/\(id.uuidString)?token=\(Self.watch)")
        XCTAssertEqual(detail.status, 200, detail.body)

        let full = try raw("GET", "/api/archives/\(id.uuidString)/cost?token=\(Self.full)")
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
    private func hook(_ id: UUID, transcript: String) async throws {
        let body = #"{"hook_event_name":"Notification","session_id":"\#(Self.run)","transcript_path":"\#(transcript)","message":"Claude is waiting for your input"}"#
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
