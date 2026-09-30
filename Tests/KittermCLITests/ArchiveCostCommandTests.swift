import Foundation
import XCTest

@testable import KittermCLI
@testable import KittermDaemon

/// `kitterm archive cost <id> [--line|--json]` over archives in a scratch
/// `KITTERM_STATE_DIR` (`foreman-flow` round 4, capability 4): the round
/// record's `- Cost:` line in `LOOP.md`'s shape from a bill, `none
/// recorded (<reason>)` without one, the route's JSON, and a non-zero exit
/// that names the id and the path when the archive cannot answer.
final class ArchiveCostCommandTests: XCTestCase {
    private var stateDir: URL!

    /// The bill fixture: $2.6361237500000003 over two models, 347,686 ms.
    /// `in` is 3390 + 450 + 1,022,235 + 74,427 = 1,100,502; cache read is
    /// 1,022,235 of it (92.9%); `out` is 27 + 17,680 = 17,707.
    private static let billTranscript = CLIFixture.repositoryRoot
        .appendingPathComponent("Tests/Fixtures/transcripts/bill.jsonl").path

    private static let billed = "B1B1B1B1-0000-4000-8000-000000000001"
    private static let running = "B2B2B2B2-0000-4000-8000-000000000002"
    private static let noJoin = "B3B3B3B3-0000-4000-8000-000000000003"
    private static let goneTranscript = "B4B4B4B4-0000-4000-8000-000000000004"
    private static let unknown = "B5B5B5B5-0000-4000-8000-000000000005"

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-archive-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)

        // A transcript with turns and no `cost-state` line: the session ran
        // on, or was resumed, after its last bill.
        let running = stateDir.appendingPathComponent("running.jsonl").path
        try Data("""
        {"type":"user","message":{"role":"user","content":"hi"},"sessionId":"r"}
        {"type":"assistant","requestId":"req_1","message":{"model":"claude-fable-5-1","usage":{"input_tokens":10,"output_tokens":5}},"sessionId":"r"}

        """.utf8).write(to: URL(fileURLWithPath: running))

        try writeArchive(Self.billed, run: "e89e7ec8-9e61-4900-800f-aa72ed555d63", transcript: Self.billTranscript)
        try writeArchive(Self.running, run: "r", transcript: running)
        try writeArchive(Self.noJoin, run: nil, transcript: nil)
        try writeArchive(Self.goneTranscript, run: "g", transcript: stateDir.appendingPathComponent("gone.jsonl").path)
    }

    override func tearDownWithError() throws {
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func writeArchive(_ id: String, run: String?, transcript: String?) throws {
        let dir = stateDir.appendingPathComponent("archive/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var json: [String: Any] = [
            "version": 1, "id": id, "cwd": "/tmp", "shell": "/bin/sh", "archivedAt": 1789468723037,
            "commands": [], "marks": [], "output": ["base": 0, "pruned": false, "bytes": 0],
        ]
        if let run, let transcript {
            json["agentSessionId"] = run
            json["agentTranscript"] = transcript
        }
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("archive.json"))
    }

    /// A bill as `TranscriptBill.read` decodes one, with the given totals
    /// and one model's usage.
    private func bill(costUSD: Double, durationMs: Int, usage: String = "{}") -> TranscriptBill {
        let json = """
        {"totalCostUSD":\(costUSD),"totalAPIDuration":0,"totalLinesAdded":0,"totalLinesRemoved":0,\
        "totalDuration":\(durationMs),"modelUsage":\(usage)}
        """
        return try! JSONDecoder().decode(TranscriptBill.self, from: Data(json.utf8))
    }

    private func run(_ args: [String]) throws -> [String] {
        var lines: [String] = []
        try ArchiveCommand.run(args) { lines.append($0) }
        return lines
    }

    // MARK: - The line

    func testBillPrintsTheRecordLineInLoopShape() throws {
        // $2.6361… to the cent; 1,100,502 in to whole thousands; 1,022,235 /
        // 1,100,502 = 92.9% → 93; 17,707 out → 18k; 347,686 ms → 5.8 min → 6.
        let expected = "- Cost: $2.64 · 1101k in (93% cached) · 18k out · 0h 06m"
        XCTAssertEqual(try run(["cost", Self.billed]), [expected])
        XCTAssertEqual(try run(["cost", Self.billed, "--line"]), [expected])
    }

    func testTheLineRollsMinutesIntoHours() {
        let bill = bill(
            costUSD: 5.886, durationMs: 82 * 60_000 + 29_000,
            usage: """
            {"claude-fable-5-1":{"inputTokens":1000,"outputTokens":76400,"thinkingTokens":0,\
            "cacheReadInputTokens":20900000,"cacheCreationInputTokens":243000,"costUSD":5.886}}
            """
        )
        XCTAssertEqual(
            ArchiveCommand.costLine(bill),
            "- Cost: $5.89 · 21144k in (99% cached) · 76k out · 1h 22m"
        )
    }

    func testAZeroedBillIsALineOfZeros() {
        XCTAssertEqual(ArchiveCommand.costLine(bill(costUSD: 0.41, durationMs: 412)), "- Cost: $0.41 · 0k in (0% cached) · 0k out · 0h 00m")
    }

    func testATranscriptWithNoCostStateLinePrintsNoneRecordedAndExitsZero() throws {
        XCTAssertEqual(try run(["cost", Self.running, "--line"]), ["- Cost: none recorded (noCostStateLine)"])
    }

    func testAnArchiveWithNoTranscriptJoinPrintsTheLineAndFails() {
        var lines: [String] = []
        XCTAssertThrowsError(try ArchiveCommand.run(["cost", Self.noJoin]) { lines.append($0) }) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(Self.noJoin), message)
            XCTAssertTrue(message.contains(stateDir.appendingPathComponent("archive").path), message)
            XCTAssertTrue(message.contains("no transcript"), message)
        }
        XCTAssertEqual(lines, ["- Cost: none recorded (no transcript)"])
    }

    func testATranscriptThatDoesNotOpenNamesItsPathAndFails() {
        var lines: [String] = []
        XCTAssertThrowsError(try ArchiveCommand.run(["cost", Self.goneTranscript]) { lines.append($0) }) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(Self.goneTranscript), message)
            XCTAssertTrue(message.contains("gone.jsonl"), message)
            XCTAssertTrue(message.contains("transcript not found"), message)
        }
        XCTAssertEqual(lines, ["- Cost: none recorded (transcript not found)"])
    }

    func testAnUnknownIdPrintsTheLineAndFails() {
        var lines: [String] = []
        XCTAssertThrowsError(try ArchiveCommand.run(["cost", Self.unknown]) { lines.append($0) }) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(Self.unknown), message)
            XCTAssertTrue(message.contains(stateDir.appendingPathComponent("archive").path), message)
        }
        XCTAssertEqual(lines, ["- Cost: none recorded (no such archive)"])
    }

    func testAnIdThatIsNotAUUIDIsAUsageError() {
        XCTAssertThrowsError(try run(["cost", "not-an-id"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("not-an-id"), error.localizedDescription)
        }
        XCTAssertThrowsError(try run(["cost"]))
        XCTAssertThrowsError(try run(["cost", Self.billed, "--csv"]))
        XCTAssertThrowsError(try run(["list"]))
    }

    // MARK: - The JSON

    func testJSONIsTheRoutesBodyWithTheTranscriptsFieldNamesUnrounded() throws {
        let lines = try run(["cost", Self.billed, "--json"])
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["hasBill"] as? Bool, true)
        XCTAssertEqual(object["agentSessionId"] as? String, "e89e7ec8-9e61-4900-800f-aa72ed555d63")
        XCTAssertEqual(object["agentTranscript"] as? String, Self.billTranscript)
        XCTAssertNil(object["reason"])
        let bill = try XCTUnwrap(object["bill"] as? [String: Any])
        XCTAssertEqual(bill["totalCostUSD"] as? Double, 2.6361237500000003)
        XCTAssertEqual(bill["totalDuration"] as? Int, 347_686)
        XCTAssertEqual(bill["totalAPIDuration"] as? Int, 244_888)
        let usage = try XCTUnwrap(bill["modelUsage"] as? [String: [String: Any]])
        XCTAssertEqual(usage["claude-fable-5-1"]?["cacheReadInputTokens"] as? Int, 1_022_235)
        XCTAssertEqual(usage["claude-haiku-4-5-20251001"]?["inputTokens"] as? Int, 3390)
        // The path's slashes are not escaped, as the route prints them.
        XCTAssertFalse(lines[0].contains("\\/"))
    }

    func testJSONWithoutABillCarriesTheReason() throws {
        let lines = try run(["cost", Self.running, "--json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["hasBill"] as? Bool, false)
        XCTAssertEqual(object["reason"] as? String, "noCostStateLine")
        XCTAssertNil(object["bill"])
    }

    func testJSONForAMissingArchiveIsTheRoutesError() throws {
        var lines: [String] = []
        XCTAssertThrowsError(try ArchiveCommand.run(["cost", Self.unknown, "--json"]) { lines.append($0) })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "no such archive")
    }
}
