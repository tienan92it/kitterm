import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/sessions/<id>/cost` for a running session: a transcript with
/// turns and no `cost-state` line answers the estimate under `estimated:
/// true`, a finished one answers the bill under `estimated: false`, and a
/// session that has not answered yet says `noTurns`. The harness is
/// `CostRouteTests`', with the estimate cache the server builds.
final class EstimateRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var stateDir: URL!
    private var sessions: [PtySession] = []
    private var port: Int!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: EstimateRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-estimate-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let registry = SessionRegistry(eventLog: EventLog())
        self.registry = registry
        let estimates = TranscriptEstimateCache()
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry, policy: .loopbackOnly, staticRoot: nil,
                            transcriptEstimates: estimates
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
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

    private func assistant(_ model: String, request: String, output: Int) -> String {
        #"{"requestId":"\#(request)","message":{"model":"\#(model)","role":"assistant","content":[],"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}},"type":"assistant","timestamp":"2026-09-20T01:00:01.000Z","sessionId":"s"}"#
    }

    /// A running session's transcript: two Opus 5 turns, no bill.
    func testARunningSessionAnswersTheEstimate() async throws {
        let id = try await spawn()
        let path = stateDir.appendingPathComponent("running.jsonl").path
        try (assistant("claude-opus-5", request: "r1", output: 100_000) + "\n" + assistant("claude-opus-5", request: "r2", output: 20_000) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        try await hook(id, transcript: path)

        let answer = try await request("GET", "/api/sessions/\(id.uuidString)/cost")
        XCTAssertEqual(answer.status, 200, answer.body)
        let json = try json(answer.body)
        XCTAssertEqual(json["hasBill"] as? Bool, false)
        XCTAssertEqual(json["reason"] as? String, "noCostStateLine")
        XCTAssertEqual(json["estimated"] as? Bool, true)
        XCTAssertNil(json["bill"])
        let estimate = try XCTUnwrap(json["estimate"] as? [String: Any])
        XCTAssertEqual(estimate["estimated"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(estimate["costUSD"] as? Double), 3.0, accuracy: 1e-9)
        XCTAssertEqual(estimate["turns"] as? Int, 2)
        XCTAssertEqual(estimate["outTokens"] as? Int, 120_000)
        XCTAssertEqual(estimate["inTokens"] as? Int, 0)
        XCTAssertEqual(estimate["startTime"] as? Int, 1_789_866_001_000)
        XCTAssertNotNil(estimate["asOf"] as? Int)
        let usage = try XCTUnwrap(estimate["modelUsage"] as? [String: [String: Any]])
        XCTAssertEqual(usage["claude-opus-5"]?["turns"] as? Int, 2)

        // The bill lands: it wins, and the estimate is gone.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"cost-state","sessionId":"s","totalCostUSD":3.1,"totalAPIDuration":1,"totalDuration":2,"totalLinesAdded":0,"totalLinesRemoved":0,"modelUsage":{}}"# + "\n").utf8))
        try handle.close()
        let billed = try await request("GET", "/api/sessions/\(id.uuidString)/cost")
        let after = try self.json(billed.body)
        XCTAssertEqual(after["hasBill"] as? Bool, true)
        XCTAssertEqual(after["estimated"] as? Bool, false)
        XCTAssertNil(after["estimate"])
        XCTAssertEqual((after["bill"] as? [String: Any])?["totalCostUSD"] as? Double, 3.1)
    }

    /// A session whose `claude` has not answered yet has neither, and the
    /// body says so.
    func testASessionWithNoTurnYetHasNoEstimate() async throws {
        let id = try await spawn()
        let path = stateDir.appendingPathComponent("fresh.jsonl").path
        try #"{"type":"user","message":{"role":"user","content":"hi"}}"#.appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        try await hook(id, transcript: path)

        let json = try json(try await request("GET", "/api/sessions/\(id.uuidString)/cost").body)
        XCTAssertEqual(json["hasBill"] as? Bool, false)
        XCTAssertEqual(json["estimated"] as? Bool, false)
        XCTAssertEqual(json["estimateReason"] as? String, "noTurns")
        XCTAssertNil(json["estimate"])
    }

    // MARK: - Helpers

    private func spawn() async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), spawnedByAPI: true)
        sessions.append(session)
        let id = await registry.register(session)
        return try XCTUnwrap(id)
    }

    private func hook(_ id: UUID, transcript: String) async throws {
        let body = #"{"hook_event_name":"Notification","session_id":"s","transcript_path":"\#(transcript)","message":"Claude is waiting for your input"}"#
        let answer = try await request("POST", "/api/hooks", body: body, headers: ["X-Kitterm-Session": id.uuidString])
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

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }
}
