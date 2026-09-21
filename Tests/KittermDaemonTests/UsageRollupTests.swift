import Foundation
import XCTest

@testable import KittermDaemon

/// `UsageRollup` over a scratch transcript root shaped like
/// `~/.claude/projects/`: one project directory holding the three
/// apportionment fixtures, and a rollup file that already records a day no
/// transcript on disk can account for. The property `plan.md` row 4 names
/// is the second test: that day is still there after a refresh.
final class UsageRollupTests: XCTestCase {
    static let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    static let utc = TimeZone(identifier: "UTC")!

    private var scratch: URL!
    private var root: URL!
    private var file: URL!
    private var projects: ProjectStore!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-usage-rollup-\(UUID().uuidString)", isDirectory: true)
        root = scratch.appendingPathComponent("projects", isDirectory: true)
        file = scratch.appendingPathComponent("state/usage-daily.json")
        let dir = root.appendingPathComponent("-nonexistent-fixture-project", isDirectory: true)
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

    private func store(zone: TimeZone = UsageRollupTests.saigon) -> UsageRollup {
        UsageRollup(file: file, transcriptsRoot: root, projects: projects, zone: zone)
    }

    /// A rollup file holding one record whose transcript does not exist
    /// under `root`: a day older than anything on disk.
    private func writeFileWithAGoneSession(zone: String = "Asia/Ho_Chi_Minh") throws {
        let json = """
        {"version":1,"timeZone":"\(zone)","refreshedAt":1767600000000,"sessions":{
          "-gone-project/aaaaaaaa-0000-4000-8000-000000000000.jsonl":{
            "sessionId":"aaaaaaaa-0000-4000-8000-000000000000","cwd":"/gone/project",
            "project":{"id":"project","name":"project","root":"/gone/project","registered":false},
            "size":1234,"mtime":1767571200000,"subagentFiles":0,"subagentBytes":0,
            "billed":true,"totalCostUSD":9.5,"startDay":"2026-01-05",
            "days":{"2026-01-05":{"input":10,"output":500,"cacheCreation":2000,"cacheRead":40000,"requests":7}}}}}
        """
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - The refresh

    func testARefreshRecordsEverySessionAndTheNextOneSkipsThemAll() throws {
        let rollup = store()
        let first = rollup.refresh()
        XCTAssertEqual(first.scanned, 3)
        XCTAssertEqual(first.read, 3)
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.retained, 0)
        XCTAssertTrue(first.wrote)
        XCTAssertEqual(
            rollup.records.keys.sorted(),
            ["-nonexistent-fixture-project/midnight.jsonl", "-nonexistent-fixture-project/one-day.jsonl", "-nonexistent-fixture-project/unbilled.jsonl"]
        )
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        let second = rollup.refresh()
        XCTAssertEqual(second.read, 0)
        XCTAssertEqual(second.skipped, 3)
        XCTAssertFalse(second.wrote)

        let record = try XCTUnwrap(rollup.records["-nonexistent-fixture-project/one-day.jsonl"])
        XCTAssertEqual(record.sessionId, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(record.billed, true)
        XCTAssertEqual(record.totalCostUSD, 3.0)
        XCTAssertEqual(record.startDay, "2026-09-10")
        XCTAssertEqual(record.days["2026-09-10"]?.requests, 3)
        // Outside every checkout and registered root, the cwd is its own
        // project.
        XCTAssertEqual(record.project, UsageRollup.ProjectRef(
            id: "fixture-project", name: "fixture-project", root: "/nonexistent/fixture-project", registered: false
        ))
        let unbilled = try XCTUnwrap(rollup.records["-nonexistent-fixture-project/unbilled.jsonl"])
        XCTAssertEqual(unbilled.billed, false)
        XCTAssertEqual(unbilled.totalCostUSD, 0)
        XCTAssertNil(unbilled.startDay)
    }

    /// The proof from `plan.md` row 4: the file already holds 2026-01-05,
    /// no transcript on disk is older than September, and the day is still
    /// there after the refresh, in memory, on disk, and in the report.
    func testADayOlderThanAnySurvivingTranscriptSurvivesARefresh() throws {
        try writeFileWithAGoneSession()
        let rollup = store()
        let gone = "-gone-project/aaaaaaaa-0000-4000-8000-000000000000.jsonl"
        XCTAssertNotNil(rollup.records[gone], "the file was loaded")

        let report = rollup.refresh()
        XCTAssertEqual(report.scanned, 3)
        XCTAssertEqual(report.read, 3)
        XCTAssertEqual(report.retained, 1)
        XCTAssertEqual(rollup.records.count, 4)
        XCTAssertEqual(rollup.records[gone]?.days["2026-01-05"]?.cacheRead, 40000)

        let january = rollup.daily(from: DayKey("2026-01-01")!, to: DayKey("2026-01-07")!)
        XCTAssertEqual(january.days.count, 7)
        XCTAssertEqual(january.days[4].day, "2026-01-05")
        XCTAssertEqual(january.days[4].costUSD, 9.5)
        XCTAssertEqual(january.days[4].apportionedUSD, 0)
        XCTAssertEqual(january.days[4].sessions, 1)
        XCTAssertEqual(january.days[4].projects.first?.root, "/gone/project")
        XCTAssertEqual(january.totals.costUSD, 9.5)

        // A second refresh, and a fresh store from the file, still hold it.
        rollup.refresh()
        let reloaded = store()
        XCTAssertEqual(reloaded.records[gone]?.totalCostUSD, 9.5)
        XCTAssertEqual(reloaded.records.count, 4)
    }

    /// A record an older reader wrote is read once more while its transcript
    /// is on disk: the file reader 1 judged unbilled behind its trailing
    /// `queue-operation` lines (round 19) is billed on the first refresh
    /// after the upgrade, the next refresh skips it, and a record whose
    /// transcript is gone keeps what it has, reader version and all.
    func testARecordOfAnOlderReaderIsReadOnceMore() throws {
        let dir = root.appendingPathComponent("-nonexistent-fixture-project", isDirectory: true)
        let trailing = dir.appendingPathComponent("trailing.jsonl")
        let bill = try String(contentsOfFile: TranscriptBillTests.fixture("bill.jsonl"), encoding: .utf8)
        try (bill + TranscriptBillTests.queueEnqueue + "\n" + TranscriptBillTests.queueDequeue + "\n")
            .write(to: trailing, atomically: true, encoding: .utf8)
        let values = try trailing.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = try XCTUnwrap(values.fileSize)
        let mtime = Int64((try XCTUnwrap(values.contentModificationDate).timeIntervalSince1970 * 1000).rounded())
        // The record reader 1 wrote for that file: the fingerprint matches,
        // the judgment is "unbilled", and there is no reader version.
        let json = """
        {"version":1,"timeZone":"Asia/Ho_Chi_Minh","refreshedAt":1767600000000,"sessions":{
          "-gone-project/aaaaaaaa-0000-4000-8000-000000000000.jsonl":{
            "sessionId":"aaaaaaaa-0000-4000-8000-000000000000","cwd":"/gone/project",
            "size":1234,"mtime":1767571200000,"subagentFiles":0,"subagentBytes":0,
            "billed":false,"totalCostUSD":0,
            "days":{"2026-01-05":{"input":10,"output":500,"cacheCreation":2000,"cacheRead":40000,"requests":7}}},
          "-nonexistent-fixture-project/trailing.jsonl":{
            "sessionId":"e89e7ec8-9e61-4900-800f-aa72ed555d63","cwd":"/nonexistent/fixture-project",
            "size":\(size),"mtime":\(mtime),"subagentFiles":0,"subagentBytes":0,
            "billed":false,"totalCostUSD":0,
            "days":{"2026-09-08":{"input":1,"output":1,"cacheCreation":1,"cacheRead":1,"requests":1}}}}}
        """
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: file, atomically: true, encoding: .utf8)

        let rollup = store()
        XCTAssertNil(rollup.records["-nonexistent-fixture-project/trailing.jsonl"]?.readerVersion)
        let first = rollup.refresh()
        XCTAssertEqual(first.scanned, 4)
        XCTAssertEqual(first.read, 4, "the three new files and the one an older reader judged")
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.retained, 1)
        let record = try XCTUnwrap(rollup.records["-nonexistent-fixture-project/trailing.jsonl"])
        XCTAssertEqual(record.billed, true)
        XCTAssertEqual(record.totalCostUSD, 2.6361237500000003)
        XCTAssertEqual(record.readerVersion, TranscriptUsage.readerVersion)
        XCTAssertEqual(record.size, Int64(size))
        XCTAssertEqual(record.mtime, mtime)
        let gone = try XCTUnwrap(rollup.records["-gone-project/aaaaaaaa-0000-4000-8000-000000000000.jsonl"])
        XCTAssertEqual(gone.billed, false)
        XCTAssertNil(gone.readerVersion)
        XCTAssertEqual(gone.days["2026-01-05"]?.cacheRead, 40000)

        let second = rollup.refresh()
        XCTAssertEqual(second.read, 0)
        XCTAssertEqual(second.skipped, 4)
        XCTAssertFalse(second.wrote)
        // The report counts the session as billed.
        XCTAssertEqual(record.startDay, "2026-09-09")
        let day = rollup.daily(from: DayKey("2026-09-09")!, to: DayKey("2026-09-09")!)
        XCTAssertEqual(day.totals.unbilledSessions, 0)
        XCTAssertEqual(day.totals.sessions, 1)
        XCTAssertEqual(day.totals.costUSD, 2.6361237500000003, accuracy: 0.000001)
    }

    func testAChangedTranscriptIsReadAgainAndItsRecordReplaced() throws {
        let rollup = store()
        rollup.refresh()
        let unbilled = root.appendingPathComponent("-nonexistent-fixture-project/unbilled.jsonl")
        let bill = #"{"type":"cost-state","sessionId":"33333333-3333-4333-8333-333333333333","totalCostUSD":0.25,"totalAPIDuration":1,"totalLinesAdded":0,"totalLinesRemoved":0,"totalDuration":2,"startTime":1789174800000,"modelUsage":{}}"#
        let handle = try FileHandle(forWritingTo: unbilled)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((bill + "\n").utf8))
        try handle.close()

        let report = rollup.refresh()
        XCTAssertEqual(report.read, 1)
        XCTAssertEqual(report.skipped, 2)
        XCTAssertTrue(report.wrote)
        let record = try XCTUnwrap(rollup.records["-nonexistent-fixture-project/unbilled.jsonl"])
        XCTAssertEqual(record.billed, true)
        XCTAssertEqual(record.totalCostUSD, 0.25)
        XCTAssertEqual(record.days["2026-09-12"]?.requests, 2)
    }

    func testAZoneChangeRereadsWhatIsOnDiskAndKeepsWhatIsNot() throws {
        try writeFileWithAGoneSession(zone: "UTC")
        let utc = store(zone: Self.utc)
        utc.refresh()
        XCTAssertEqual(Array(utc.records["-nonexistent-fixture-project/midnight.jsonl"]!.days.keys), ["2026-09-10"])
        XCTAssertEqual(utc.refresh().read, 0)

        let saigon = store(zone: Self.saigon)
        let report = saigon.refresh()
        XCTAssertEqual(report.read, 3, "every transcript on disk is read into the new zone")
        XCTAssertEqual(report.retained, 1)
        XCTAssertEqual(saigon.records["-nonexistent-fixture-project/midnight.jsonl"]?.days.keys.sorted(), ["2026-09-10", "2026-09-11"])
        XCTAssertEqual(saigon.records["-gone-project/aaaaaaaa-0000-4000-8000-000000000000.jsonl"]?.days.keys.sorted(), ["2026-01-05"])
        XCTAssertEqual(saigon.refresh().read, 0)
    }

    func testAFileOfAnotherVersionIsIgnoredAndReplaced() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version":2,"timeZone":"UTC","refreshedAt":0,"sessions":{"x/y.jsonl":{}}}"#.write(to: file, atomically: true, encoding: .utf8)
        let rollup = store()
        XCTAssertTrue(rollup.records.isEmpty)
        XCTAssertTrue(rollup.refresh().wrote)
        XCTAssertEqual(store().records.count, 3)
    }

    /// A transcript whose cwd is a registered root is that project, by id,
    /// and a subagent file under `<session>/subagents/` counts for it.
    func testARegisteredRootNamesTheProjectAndSubagentsCountForTheSession() throws {
        let checkout = scratch.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let canonical = ProjectStore.canonicalRoot(checkout.path)
        try ProjectStore.save([Project(id: "my-checkout", name: "My Checkout", root: canonical)], to: scratch.appendingPathComponent("projects.json"))

        let dir = root.appendingPathComponent("-registered", isDirectory: true)
        let session = "44444444-4444-4444-8444-444444444444"
        let subagents = dir.appendingPathComponent(session, isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let turn = #"{"type":"assistant","requestId":"req_main","timestamp":"2026-09-14T03:00:00.000Z","cwd":"\#(canonical)","sessionId":"\#(session)","message":{"role":"assistant","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":100,"output_tokens":10}}}"#
        try (turn + "\n").write(to: dir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
        let sub = turn.replacingOccurrences(of: "req_main", with: "req_sub")
        try (sub + "\n").write(to: subagents.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)

        let rollup = store()
        rollup.refresh()
        let record = try XCTUnwrap(rollup.records["-registered/\(session).jsonl"])
        XCTAssertEqual(record.project?.id, "my-checkout")
        XCTAssertEqual(record.project?.name, "My Checkout")
        XCTAssertEqual(record.project?.registered, true)
        XCTAssertEqual(record.subagentFiles, 1)
        XCTAssertEqual(record.days["2026-09-14"]?.requests, 2)
        XCTAssertEqual(rollup.refresh().skipped, 4)
    }

    // MARK: - The report

    func testTheDailyReportSumsDaysAndProjectsAndSaysWhatIsApportioned() throws {
        let rollup = store()
        rollup.refresh()
        let report = rollup.daily(from: DayKey("2026-09-09")!, to: DayKey("2026-09-12")!)
        XCTAssertEqual(report.timeZone, "Asia/Ho_Chi_Minh")
        XCTAssertEqual(report.from, "2026-09-09")
        XCTAssertEqual(report.to, "2026-09-12")
        XCTAssertEqual(report.recordedSessions, 3)
        XCTAssertEqual(report.days.map(\.day), ["2026-09-09", "2026-09-10", "2026-09-11", "2026-09-12"])

        let quiet = report.days[0]
        XCTAssertEqual(quiet.costUSD, 0)
        XCTAssertEqual(quiet.sessions, 0)
        XCTAssertTrue(quiet.projects.isEmpty)

        // The one-day session's $3.00 exact plus the midnight session's
        // $3.00 share.
        let tenth = report.days[1]
        XCTAssertEqual(tenth.costUSD, 6.0, accuracy: 1e-12)
        XCTAssertEqual(tenth.apportionedUSD, 3.0, accuracy: 1e-12)
        XCTAssertEqual(tenth.sessions, 2)
        XCTAssertEqual(tenth.unbilledSessions, 0)
        XCTAssertEqual(tenth.tokens.requests, 5)
        XCTAssertEqual(tenth.tokens.total, 20106 + 6000)
        XCTAssertEqual(tenth.projects.count, 1)
        XCTAssertEqual(tenth.projects[0].id, "fixture-project")
        XCTAssertEqual(tenth.projects[0].costUSD, 6.0, accuracy: 1e-12)

        let eleventh = report.days[2]
        XCTAssertEqual(eleventh.costUSD, 1.0, accuracy: 1e-12)
        XCTAssertEqual(eleventh.apportionedUSD, 1.0, accuracy: 1e-12)

        let twelfth = report.days[3]
        XCTAssertEqual(twelfth.costUSD, 0)
        XCTAssertEqual(twelfth.sessions, 1)
        XCTAssertEqual(twelfth.unbilledSessions, 1)
        XCTAssertEqual(twelfth.tokens.total, 4208)

        XCTAssertEqual(report.totals.costUSD, 7.0, accuracy: 1e-12)
        XCTAssertEqual(report.totals.apportionedUSD, 4.0, accuracy: 1e-12)
        XCTAssertEqual(report.totals.sessions, 3)
        XCTAssertEqual(report.totals.unbilledSessions, 1)
        XCTAssertEqual(report.projects.count, 1)
        XCTAssertEqual(report.projects[0].root, "/nonexistent/fixture-project")
        XCTAssertEqual(report.projects[0].costUSD, 7.0, accuracy: 1e-12)
        XCTAssertEqual(report.projects[0].sessions, 3)
    }

    /// A day at the edge of the range takes only its own share: the
    /// midnight session's 11th is out when the range ends on the 10th.
    func testARangeCutsASessionAtItsDays() {
        let rollup = store()
        rollup.refresh()
        let report = rollup.daily(from: DayKey("2026-09-10")!, to: DayKey("2026-09-10")!)
        XCTAssertEqual(report.days.count, 1)
        XCTAssertEqual(report.totals.costUSD, 6.0, accuracy: 1e-12)
        XCTAssertEqual(report.totals.sessions, 2)
    }
}
