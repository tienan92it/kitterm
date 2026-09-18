import Foundation
import XCTest

@testable import KittermDaemon

/// The per-model split `UsageRollup` keeps since `agent-dashboard` round 5:
/// the bill's `modelUsage` map on each record, the split per day and per
/// range in the report, and what a rollup file written before the map was
/// kept does when the new code reads it.
final class UsageRollupModelTests: XCTestCase {
    static let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

    private var scratch: URL!
    private var root: URL!
    private var dir: URL!
    private var file: URL!
    private var projects: ProjectStore!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-usage-rollup-model-\(UUID().uuidString)", isDirectory: true)
        root = scratch.appendingPathComponent("projects", isDirectory: true)
        file = scratch.appendingPathComponent("state/usage-daily.json")
        dir = root.appendingPathComponent("-nonexistent-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["one-day", "midnight", "unbilled"] {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: TranscriptBillTests.fixture("\(name).jsonl")),
                to: dir.appendingPathComponent("\(name).jsonl")
            )
        }
        projects = ProjectStore(url: scratch.appendingPathComponent("projects.json"))
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func store() -> UsageRollup {
        UsageRollup(file: file, transcriptsRoot: root, projects: projects, zone: Self.saigon)
    }

    /// A session on two models that spans midnight in Saigon: 3000 tokens
    /// on the 10th and 1000 on the 11th, billed $6 to Fable and $2 to
    /// Opus 1M, so the 10th takes three quarters of each.
    private func writeTwoModelTranscript() throws {
        let session = "55555555-5555-4555-8555-555555555555"
        func turn(_ request: String, _ stamp: String, cacheRead: Int) -> String {
            #"{"type":"assistant","requestId":"\#(request)","timestamp":"\#(stamp)","cwd":"/nonexistent/fixture-project","sessionId":"\#(session)","message":{"model":"claude-fable-5-1","role":"assistant","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":\#(cacheRead),"output_tokens":0}}}"#
        }
        let bill = #"{"type":"cost-state","sessionId":"\#(session)","totalCostUSD":8.0,"totalAPIDuration":1,"totalLinesAdded":0,"totalLinesRemoved":0,"totalDuration":2,"startTime":1789061400000,"modelUsage":{"claude-fable-5-1":{"inputTokens":0,"outputTokens":400,"thinkingTokens":0,"cacheReadInputTokens":3600,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":6.0},"claude-opus-5[1m]":{"inputTokens":0,"outputTokens":100,"thinkingTokens":0,"cacheReadInputTokens":400,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":2.0}},"hasUnknownModelCost":false}"#
        let lines = [
            turn("req_a", "2026-09-10T10:00:00.000Z", cacheRead: 3000),
            turn("req_b", "2026-09-10T17:30:00.000Z", cacheRead: 1000),
            bill,
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func assertSplitSums(_ day: UsageRollup.Day, file: StaticString = #filePath, line: UInt = #line) {
        let split = day.models.reduce(0) { $0 + $1.costUSD }
        XCTAssertEqual(split + day.unsplitUSD, day.costUSD, accuracy: 1e-9, "\(day.day)", file: file, line: line)
    }

    // MARK: - The split

    func testADaysPerModelSplitSumsToThatDaysTotal() throws {
        try writeTwoModelTranscript()
        let rollup = store()
        rollup.refresh()
        let report = rollup.daily(from: DayKey("2026-09-09")!, to: DayKey("2026-09-12")!)
        for day in report.days { assertSplitSums(day) }
        XCTAssertEqual(report.totals.unsplitUSD, 0, "every record on disk carries its map")
        XCTAssertEqual(report.models.reduce(0) { $0 + $1.costUSD }, report.totals.costUSD, accuracy: 1e-9)

        // The 10th: $3 one-day, $3 of midnight, and $6 of the two-model session.
        let tenth = report.days[1]
        XCTAssertEqual(tenth.costUSD, 12.0, accuracy: 1e-9)
        XCTAssertEqual(tenth.models.map(\.model), ["claude-fable-5-1", "claude-opus-5[1m]"])
        XCTAssertEqual(tenth.models[0].costUSD, 10.5, accuracy: 1e-9)
        XCTAssertEqual(tenth.models[1].costUSD, 1.5, accuracy: 1e-9)
        XCTAssertEqual(tenth.models[1].name, "Opus 5 · 1M", "the 1M variant is its own row")
        XCTAssertEqual(tenth.models[1].apportionedUSD, 1.5, accuracy: 1e-9)
        XCTAssertEqual(tenth.models[1].cacheReadInputTokens, 300, accuracy: 1e-9)
        XCTAssertEqual(tenth.models[0].sessions, 3)

        // The 11th: $1 of midnight and $2 of the two-model session.
        let eleventh = report.days[2]
        XCTAssertEqual(eleventh.costUSD, 3.0, accuracy: 1e-9)
        XCTAssertEqual(eleventh.models[0].costUSD, 2.5, accuracy: 1e-9)
        XCTAssertEqual(eleventh.models[1].costUSD, 0.5, accuracy: 1e-9)

        // The range: dearest first, and a session on two days is one session.
        XCTAssertEqual(report.models.map(\.name), ["Fable 5.1", "Opus 5 · 1M"])
        XCTAssertEqual(report.models[0].costUSD, 13.0, accuracy: 1e-9)
        XCTAssertEqual(report.models[0].sessions, 3)
        XCTAssertEqual(report.models[1].costUSD, 2.0, accuracy: 1e-9)
        XCTAssertEqual(report.models[1].sessions, 1)
        XCTAssertEqual(report.models[1].outputTokens, 100, accuracy: 1e-9)

        // The unbilled day has no split and nothing unsplit.
        let twelfth = report.days[3]
        XCTAssertEqual(twelfth.unbilledSessions, 1)
        XCTAssertTrue(twelfth.models.isEmpty)
        XCTAssertEqual(twelfth.unsplitUSD, 0)
    }

    func testTheRecordKeepsTheBillsMap() throws {
        let rollup = store()
        rollup.refresh()
        let record = try XCTUnwrap(rollup.records["-nonexistent-fixture-project/one-day.jsonl"])
        XCTAssertEqual(record.models?.keys.sorted(), ["claude-fable-5-1"])
        XCTAssertEqual(record.models?["claude-fable-5-1"]?.costUSD, 3.0)
        let unbilled = try XCTUnwrap(rollup.records["-nonexistent-fixture-project/unbilled.jsonl"])
        XCTAssertNil(unbilled.models)

        // The file round-trips the map.
        let reloaded = store()
        XCTAssertEqual(reloaded.records["-nonexistent-fixture-project/one-day.jsonl"]?.models?["claude-fable-5-1"]?.costUSD, 3.0)
    }

    // MARK: - A file from before

    /// The shape `usage-daily.json` had before the map was kept: version 1,
    /// no `models` key on any record. The record whose transcript is gone
    /// loads, reports its day whole, and shows that day's dollars as
    /// unsplit, so the split still sums to the total.
    func testARollupFileWrittenBeforeThisChangeStillReads() throws {
        let gone = "-gone-project/aaaaaaaa-0000-4000-8000-000000000000.jsonl"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"version":1,"timeZone":"Asia/Ho_Chi_Minh","refreshedAt":1767600000000,"sessions":{
          "\(gone)":{
            "sessionId":"aaaaaaaa-0000-4000-8000-000000000000","cwd":"/gone/project",
            "project":{"id":"project","name":"project","root":"/gone/project","registered":false},
            "size":1234,"mtime":1767571200000,"subagentFiles":0,"subagentBytes":0,
            "billed":true,"totalCostUSD":9.5,"startDay":"2026-01-05",
            "days":{"2026-01-05":{"input":10,"output":500,"cacheCreation":2000,"cacheRead":40000,"requests":7}}}}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let rollup = store()
        let record = try XCTUnwrap(rollup.records[gone], "the file loaded")
        XCTAssertNil(record.models)
        XCTAssertEqual(rollup.refresh().retained, 1)

        let january = rollup.daily(from: DayKey("2026-01-05")!, to: DayKey("2026-01-05")!)
        XCTAssertEqual(january.days[0].costUSD, 9.5)
        XCTAssertEqual(january.days[0].unsplitUSD, 9.5)
        XCTAssertTrue(january.days[0].models.isEmpty)
        assertSplitSums(january.days[0])
        XCTAssertEqual(january.totals.unsplitUSD, 9.5)
        XCTAssertTrue(january.models.isEmpty)

        // Written back and read again, it is still whole and still unsplit.
        let reloaded = store()
        XCTAssertEqual(reloaded.records[gone]?.totalCostUSD, 9.5)
        XCTAssertNil(reloaded.records[gone]?.models)
        XCTAssertEqual(reloaded.daily(from: DayKey("2026-01-05")!, to: DayKey("2026-01-05")!).totals.unsplitUSD, 9.5)
    }

    /// A billed record from before whose transcript is still on disk is
    /// read once more, fingerprint unchanged, so its split fills in.
    func testABilledRecordWithNoMapIsReadAgainWhileItsTranscriptIsOnDisk() throws {
        store().refresh()
        // Strip every `models` key: the file as the old code wrote it.
        var shape = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var sessions = try XCTUnwrap(shape["sessions"] as? [String: [String: Any]])
        for key in sessions.keys { sessions[key]?.removeValue(forKey: "models") }
        shape["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: shape).write(to: file)

        let rollup = store()
        XCTAssertNil(rollup.records["-nonexistent-fixture-project/one-day.jsonl"]?.models)
        let report = rollup.refresh()
        XCTAssertEqual(report.read, 2, "the two billed records; the unbilled one has no map to fill")
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(rollup.records["-nonexistent-fixture-project/one-day.jsonl"]?.models?["claude-fable-5-1"]?.costUSD, 3.0)
        XCTAssertEqual(rollup.refresh().read, 0, "and only once")
    }
}
