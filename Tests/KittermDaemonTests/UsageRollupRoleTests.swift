import Foundation
import XCTest

@testable import KittermDaemon

/// The role split, the hours of model time and the low-cache exceptions
/// `UsageRollup` reports since `agent-dashboard` round 6: the role reader
/// over a worktree path, a root path and a path outside every project; a
/// range whose roles sum to its totals with the API time apportioned across
/// midnight; a record read before the rollup kept the duration, whose
/// dollars are in the total and in no rate; and the $5 floor and 95%
/// threshold of the exception list.
final class UsageRollupRoleTests: XCTestCase {
    static let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

    private var scratch: URL!
    private var root: URL!
    private var dir: URL!
    private var file: URL!
    private var projects: ProjectStore!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-usage-rollup-role-\(UUID().uuidString)", isDirectory: true)
        root = scratch.appendingPathComponent("projects", isDirectory: true)
        file = scratch.appendingPathComponent("state/usage-daily.json")
        dir = root.appendingPathComponent("-nonexistent-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        projects = ProjectStore(url: scratch.appendingPathComponent("projects.json"))
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func store() -> UsageRollup {
        UsageRollup(file: file, transcriptsRoot: root, projects: projects, zone: Self.saigon)
    }

    // MARK: - the role reader

    func testTheRoleIsReadFromTheDirectory() {
        XCTAssertEqual(UsageRollup.SessionRole.of(cwd: "/Users/antran/Workspace/kitterm/.claude/worktrees/spend-bought"), .crew)
        XCTAssertEqual(UsageRollup.SessionRole.of(cwd: "/home/u/proj/.claude/worktrees/x/Web/terminal"), .crew, "a subdirectory of a worktree")
        XCTAssertEqual(UsageRollup.SessionRole.of(cwd: "/Users/antran/Workspace/kitterm"), .root)
        XCTAssertEqual(UsageRollup.SessionRole.of(cwd: "/Users/antran/Workspace/kitterm/Web/terminal"), .root)
        XCTAssertEqual(UsageRollup.SessionRole.of(cwd: "/Users/antran"), .root, "outside every project is a root session, as the research counted it")
        XCTAssertEqual(UsageRollup.SessionRole.of(cwd: "/tmp/worktrees/not-claude"), .root)
        XCTAssertEqual(UsageRollup.SessionRole.of(cwd: nil), .root)
    }

    // MARK: - fixtures

    /// One session: `cost` dollars, `apiMs` of API time, `lines` added, turns
    /// on the given UTC stamps with `cacheRead` and `input` tokens each.
    private func write(
        session: String, cwd: String, cost: Double, apiMs: Int, lines: Int,
        turns: [(stamp: String, input: Int, cacheRead: Int)], withDuration: Bool = true
    ) throws {
        var out: [String] = []
        for (index, turn) in turns.enumerated() {
            out.append(#"{"type":"assistant","requestId":"req_\#(session.prefix(4))_\#(index)","timestamp":"\#(turn.stamp)","cwd":"\#(cwd)","sessionId":"\#(session)","message":{"model":"claude-fable-5-1","role":"assistant","usage":{"input_tokens":\#(turn.input),"cache_creation_input_tokens":0,"cache_read_input_tokens":\#(turn.cacheRead),"output_tokens":0}}}"#)
        }
        let usage = #"{"claude-fable-5-1":{"inputTokens":1,"outputTokens":1,"thinkingTokens":0,"cacheReadInputTokens":1,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":\#(cost)}}"#
        let duration = withDuration ? #""totalAPIDuration":\#(apiMs),"# : ""
        out.append(#"{"type":"cost-state","sessionId":"\#(session)","totalCostUSD":\#(cost),\#(duration)"totalLinesAdded":\#(lines),"totalLinesRemoved":0,"totalDuration":2,"startTime":1789061400000,"modelUsage":\#(usage),"hasUnknownModelCost":false}"#)
        try (out.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8
        )
    }

    private let crewSession = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let rootSession = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let homeSession = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    // MARK: - the split

    func testRolesSumToTheTotalsAndTheHoursAreApportionedByTokenShare() throws {
        // A crew on two days: 3000 tokens on the 10th and 1000 on the 11th
        // in Saigon, $8, 4000 ms of API time, 40 lines.
        try write(
            session: crewSession, cwd: "/nonexistent/fixture-project/.claude/worktrees/crew", cost: 8, apiMs: 4000, lines: 40,
            turns: [("2026-09-10T10:00:00.000Z", 0, 3000), ("2026-09-10T17:30:00.000Z", 0, 1000)]
        )
        // A root session on one day: $6, 6000 ms, 12 lines, and 90% cached.
        try write(
            session: rootSession, cwd: "/nonexistent/fixture-project", cost: 6, apiMs: 6000, lines: 12,
            turns: [("2026-09-10T03:00:00.000Z", 100, 900)]
        )
        // A job session in the home directory: a root session too, $1.
        try write(
            session: homeSession, cwd: "/Users/someone", cost: 1, apiMs: 500, lines: 0,
            turns: [("2026-09-11T03:00:00.000Z", 0, 100)]
        )
        let rollup = store()
        rollup.refresh()

        let report = rollup.daily(from: DayKey("2026-09-10")!, to: DayKey("2026-09-11")!)
        XCTAssertEqual(report.roles.map(\.role), [.root, .crew], "both roles, in one order, always")
        let root = report.roles[0], crew = report.roles[1]
        XCTAssertEqual(root.costUSD + crew.costUSD, report.totals.costUSD, accuracy: 1e-9)
        XCTAssertEqual(root.sessions + crew.sessions, report.totals.sessions)
        XCTAssertEqual(crew.costUSD, 8, accuracy: 1e-9)
        XCTAssertEqual(crew.sessions, 1, "a session on two days is one session")
        XCTAssertEqual(crew.apiMs, 4000)
        XCTAssertEqual(crew.linesAdded, 40)
        XCTAssertEqual(crew.measuredUSD, 8, accuracy: 1e-9)
        XCTAssertEqual(root.costUSD, 7, accuracy: 1e-9)
        XCTAssertEqual(root.sessions, 2)
        XCTAssertEqual(root.apiMs, 6500)
        XCTAssertEqual(root.linesAdded, 12)
        XCTAssertEqual(report.totals.apiMs, 10500)
        XCTAssertEqual(report.totals.measuredUSD, 15, accuracy: 1e-9)

        // The 10th takes three quarters of the crew's time, the 11th a quarter.
        XCTAssertEqual(report.days[0].apiMs, 3000 + 6000)
        XCTAssertEqual(report.days[1].apiMs, 1000 + 500)
        XCTAssertEqual(report.days[0].apiMs + report.days[1].apiMs, report.totals.apiMs)

        // A range holding only the 11th sees the crew's quarter and the job.
        let eleventh = rollup.daily(from: DayKey("2026-09-11")!, to: DayKey("2026-09-11")!)
        XCTAssertEqual(eleventh.roles[1].apiMs, 1000)
        XCTAssertEqual(eleventh.roles[1].costUSD, 2, accuracy: 1e-9)
        XCTAssertEqual(eleventh.roles[0].sessions, 1)
    }

    func testARecordWithoutADurationIsInTheTotalAndInNoRate() throws {
        try write(
            session: rootSession, cwd: "/nonexistent/fixture-project", cost: 6, apiMs: 0, lines: 0,
            turns: [("2026-09-10T03:00:00.000Z", 0, 1000)], withDuration: false
        )
        let rollup = store()
        rollup.refresh()
        // The bill is malformed without `totalAPIDuration`, so the session
        // is unbilled: nothing measured. The retained-record case below is
        // the one that matters, a bill read before the duration was kept.
        let report = rollup.daily(from: DayKey("2026-09-10")!, to: DayKey("2026-09-10")!)
        XCTAssertEqual(report.totals.apiMs, 0)
        XCTAssertEqual(report.totals.measuredUSD, 0)
    }

    func testARetainedRecordReadBeforeTheDurationWasKeptCountsDollarsButNoHours() throws {
        let retained = """
        {"version":1,"timeZone":"Asia/Ho_Chi_Minh","refreshedAt":1767600000000,"sessions":{
          "-gone-project/dddddddd-0000-4000-8000-000000000000.jsonl":{
            "sessionId":"dddddddd-0000-4000-8000-000000000000","cwd":"/gone/project/.claude/worktrees/old",
            "project":{"id":"project","name":"project","root":"/gone/project","registered":false},
            "size":1234,"mtime":1767571200000,"subagentFiles":0,"subagentBytes":0,
            "billed":true,"totalCostUSD":9.5,"startDay":"2026-01-05",
            "days":{"2026-01-05":{"input":10,"output":500,"cacheCreation":2000,"cacheRead":40000,"requests":7}}}}}
        """
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try retained.write(to: file, atomically: true, encoding: .utf8)
        let rollup = store()
        rollup.refresh()
        let report = rollup.daily(from: DayKey("2026-01-05")!, to: DayKey("2026-01-05")!)
        XCTAssertEqual(report.totals.costUSD, 9.5)
        XCTAssertEqual(report.totals.apiMs, 0)
        XCTAssertEqual(report.totals.measuredUSD, 0, "no duration on the record, so its dollars price no hour")
        XCTAssertEqual(report.roles[1].role, .crew)
        XCTAssertEqual(report.roles[1].costUSD, 9.5)
        XCTAssertEqual(report.roles[1].measuredUSD, 0)
        XCTAssertNil(rollup.records.values.first?.apiDurationMs)
    }

    func testABilledRecordWithoutTheDurationIsReadAgainOnce() throws {
        try write(
            session: rootSession, cwd: "/nonexistent/fixture-project", cost: 6, apiMs: 6000, lines: 12,
            turns: [("2026-09-10T03:00:00.000Z", 100, 900)]
        )
        let rollup = store()
        rollup.refresh()
        let records = rollup.records
        let key = try XCTUnwrap(records.keys.first)
        XCTAssertEqual(records[key]?.apiDurationMs, 6000)
        XCTAssertEqual(records[key]?.linesAdded, 12)
        // Strip the duration the way a pre-change file lacks it, and
        // refresh: the record is read once more and the field fills in.
        let shape = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        var sessions = try XCTUnwrap(shape?["sessions"] as? [String: Any])
        var record = try XCTUnwrap(sessions[key] as? [String: Any])
        record.removeValue(forKey: "apiDurationMs")
        sessions[key] = record
        var rewritten = try XCTUnwrap(shape)
        rewritten["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: rewritten).write(to: file)
        let reloaded = store()
        XCTAssertNil(reloaded.records[key]?.apiDurationMs)
        XCTAssertEqual(reloaded.refresh().read, 1, "read again for the duration")
        XCTAssertEqual(reloaded.records[key]?.apiDurationMs, 6000)
        XCTAssertEqual(reloaded.refresh().read, 0, "and then skipped")
    }

    // MARK: - the exceptions

    func testTheLowCacheListHoldsBilledSessionsOverTheFloorUnderTheThreshold() throws {
        // 90% cached and $6: an exception.
        try write(
            session: rootSession, cwd: "/nonexistent/fixture-project", cost: 6, apiMs: 100, lines: 0,
            turns: [("2026-09-10T03:00:00.000Z", 100, 900)]
        )
        // 50% cached and $4: under the floor, not listed.
        try write(
            session: homeSession, cwd: "/Users/someone", cost: 4, apiMs: 100, lines: 0,
            turns: [("2026-09-10T04:00:00.000Z", 500, 500)]
        )
        // 96% cached and $20: over the floor, over the threshold, not listed.
        try write(
            session: crewSession, cwd: "/nonexistent/fixture-project/.claude/worktrees/crew", cost: 20, apiMs: 100, lines: 0,
            turns: [("2026-09-10T05:00:00.000Z", 40, 960)]
        )
        let rollup = store()
        rollup.refresh()
        let report = rollup.daily(from: DayKey("2026-09-10")!, to: DayKey("2026-09-10")!)
        XCTAssertEqual(report.lowCache.count, 1)
        XCTAssertEqual(report.lowCache[0].sessionId, rootSession)
        XCTAssertEqual(report.lowCache[0].project, "fixture-project")
        XCTAssertEqual(report.lowCache[0].costUSD, 6)
        XCTAssertEqual(report.lowCache[0].cacheShare, 0.9, accuracy: 1e-9)
        XCTAssertEqual(UsageRollup.lowCacheFloorUSD, 5)
        XCTAssertEqual(UsageRollup.lowCacheThreshold, 0.95)
        // Out of range, out of the list.
        XCTAssertEqual(rollup.daily(from: DayKey("2026-09-11")!, to: DayKey("2026-09-12")!).lowCache, [])
    }
}
