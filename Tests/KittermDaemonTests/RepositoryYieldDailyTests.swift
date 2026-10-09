import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// The day-by-day counts the LIFETIME chart needs (`value-lifetime`,
/// capability 2): merged pull requests, merged lines and releases per day,
/// from `RepositoryYield.readDaily` and `GET /api/yield/daily`, by the same
/// rules and the same absent-means-no-source convention as `RepositoryYield`
/// and `GET /api/yield` already use.
final class RepositoryYieldDailyTests: XCTestCase {
    static let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-yield-daily-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - per-day counts, including across midnight in the zone

    /// Merges dated across several days, one of them a few minutes after
    /// local midnight so it lands on the next day in Saigon and the
    /// previous day in UTC, and a tag on one of those days: `readDaily`
    /// buckets each by committer day in the zone it is given, the same way
    /// `read`'s single total does, and zero-fills every day with nothing.
    func testReadDailyBucketsMergesAndTagsByCommitterDayInTheZone() throws {
        let root = try repo("daily")
        try git(root, ["remote", "add", "origin", "https://example.invalid/daily.git"])
        try commit(root, "Day one (#1)", lines: 10, at: "2026-09-01T10:00:00+07:00")
        try commit(root, "Day one again (#2)", lines: 5, at: "2026-09-01T18:00:00+07:00")
        // 23:50 on the 2nd in Saigon is 16:50Z on the 2nd, still the 2nd in
        // UTC too, so use a time that crosses midnight in Saigon but not in
        // UTC: 00:10+07 on the 3rd is 17:10Z on the 2nd.
        try commit(root, "Just after midnight (#3)", lines: 7, at: "2026-09-03T00:10:00+07:00")
        try git(root, ["tag", "v1.0.0"], at: "2026-09-03T01:00:00+07:00")
        try commit(root, "Day four (#4)", lines: 2, at: "2026-09-04T10:00:00+07:00")
        try git(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])

        let from = DayKey("2026-09-01")!, to = DayKey("2026-09-05")!
        let saigon = RepositoryYield.readDaily(root: root, from: from, to: to, zone: Self.saigon)
        XCTAssertEqual(saigon.map(\.day), ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05"])
        XCTAssertEqual(saigon[0].mergedPullRequests, 2, "both day-one merges")
        XCTAssertEqual(saigon[0].mergedLines, 15)
        XCTAssertEqual(saigon[0].releases, 0)
        XCTAssertEqual(saigon[1].mergedPullRequests, 0, "zero-filled, not absent")
        XCTAssertEqual(saigon[1].mergedLines, 0)
        XCTAssertEqual(saigon[2].mergedPullRequests, 1, "the midnight-crossing merge lands on the 3rd in Saigon")
        XCTAssertEqual(saigon[2].mergedLines, 7)
        XCTAssertEqual(saigon[2].releases, 1)
        XCTAssertEqual(saigon[3].mergedPullRequests, 1)
        XCTAssertEqual(saigon[3].mergedLines, 2)
        XCTAssertEqual(saigon[4].mergedPullRequests, 0)

        // The same commit reads a day earlier in UTC: 17:10Z on the 2nd.
        let utc = RepositoryYield.readDaily(root: root, from: from, to: to, zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(utc[1].mergedPullRequests, 1, "the midnight-crossing merge lands on the 2nd in UTC")
        XCTAssertEqual(utc[1].mergedLines, 7)
        XCTAssertEqual(utc[2].mergedPullRequests, 0, "nothing left on the 3rd in UTC")
    }

    func testReadDailyOnANonCheckoutIsEveryDayAbsent() throws {
        let root = scratch.appendingPathComponent("plain", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let series = RepositoryYield.readDaily(
            root: root, from: DayKey("2026-09-01")!, to: DayKey("2026-09-03")!, zone: Self.saigon
        )
        XCTAssertEqual(series.count, 3)
        for day in series {
            XCTAssertNil(day.mergedPullRequests)
            XCTAssertNil(day.mergedLines)
            XCTAssertNil(day.releases)
        }
    }

    func testReadDailyOnACheckoutWithNoRemoteCountsOnlyReleases() throws {
        let root = try repo("noremote")
        try commit(root, "Local merge (#9)", lines: 10, at: "2026-09-02T10:00:00+07:00")
        try git(root, ["tag", "v1.0.0"], at: "2026-09-02T11:00:00+07:00")
        let series = RepositoryYield.readDaily(
            root: root, from: DayKey("2026-09-01")!, to: DayKey("2026-09-03")!, zone: Self.saigon
        )
        XCTAssertNil(series[1].mergedPullRequests, "a pull request is the remote's concept")
        XCTAssertNil(series[1].mergedLines)
        XCTAssertEqual(series[1].releases, 1, "a release is the checkout's own tag, remote or not")
        XCTAssertEqual(series[0].releases, 0, "zero-filled on a day with no tag")
    }

    /// `readDaily`'s per-day counts sum to `read`'s one total over the same
    /// range, so the chart's per-day series and the tiles' totals can never
    /// disagree.
    func testReadDailySumsToReadsTotalOverTheSameRange() throws {
        let root = try repo("summed")
        try git(root, ["remote", "add", "origin", "https://example.invalid/summed.git"])
        try commit(root, "First (#1)", lines: 40, at: "2026-09-01T10:00:00+07:00")
        try commit(root, "Second (#2)", lines: 15, at: "2026-09-02T10:00:00+07:00")
        try commit(root, "Plain work", lines: 9, at: "2026-09-03T10:00:00+07:00")
        try commit(root, "Third (#3)", lines: 3, at: "2026-09-04T10:00:00+07:00")
        try git(root, ["tag", "v1.0.0"], at: "2026-09-02T12:00:00+07:00")
        try git(root, ["tag", "v1.1.0"], at: "2026-09-04T12:00:00+07:00")
        try git(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])

        let from = DayKey("2026-09-01")!, to = DayKey("2026-09-05")!
        let total = RepositoryYield.read(root: root, from: from, to: to, zone: Self.saigon)
        let daily = RepositoryYield.readDaily(root: root, from: from, to: to, zone: Self.saigon)
        XCTAssertEqual(daily.compactMap(\.mergedPullRequests).reduce(0, +), total.mergedPullRequests)
        XCTAssertEqual(daily.compactMap(\.mergedLines).reduce(0, +), total.mergedLines)
        XCTAssertEqual(daily.compactMap(\.releases).reduce(0, +), total.releases)
    }

    // MARK: - the report: zero-fill and the sum over projects

    func testDailyReportSumsOverProjectsAndZeroFillsAndKeepsAnAnswerFiveMinutes() throws {
        let counted = try repo("counted")
        try git(counted, ["remote", "add", "origin", "https://example.invalid/a.git"])
        try commit(counted, "Counted one (#1)", lines: 40, at: "2026-09-02T10:00:00+07:00")
        try git(counted, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        let other = try repo("other")
        try git(other, ["remote", "add", "origin", "https://example.invalid/b.git"])
        try commit(other, "Other one (#2)", lines: 5, at: "2026-09-02T11:00:00+07:00")
        try git(other, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        let plain = scratch.appendingPathComponent("plain2", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)

        var calls = 0
        let yields = RepositoryYields(zone: Self.saigon) { args in
            calls += 1
            return RepositoryYield.run(args: args)
        }
        let projects = [
            RepositoryYields.ProjectRef(id: "counted", name: "counted", root: counted, registered: true),
            RepositoryYields.ProjectRef(id: "other", name: "other", root: other, registered: true),
            RepositoryYields.ProjectRef(id: "plain", name: "plain", root: plain, registered: false),
        ]
        let from = DayKey("2026-09-01")!, to = DayKey("2026-09-03")!
        let start = Date()
        let report = yields.dailyReport(projects: projects, from: from, to: to, now: start)
        XCTAssertEqual(report.days.map(\.day), ["2026-09-01", "2026-09-02", "2026-09-03"])
        XCTAssertEqual(report.days[0].mergedPullRequests, 0, "zero-filled")
        XCTAssertEqual(report.days[0].mergedLines, 0)
        XCTAssertEqual(report.days[1].mergedPullRequests, 2, "summed over both counted projects")
        XCTAssertEqual(report.days[1].mergedLines, 45)
        XCTAssertEqual(report.days[2].mergedPullRequests, 0)
        let plainDay = try XCTUnwrap(report.days[1].projects.first { $0.id == "plain" })
        XCTAssertNil(plainDay.mergedPullRequests, "a root with no history contributes nothing to the sum, never a zero")
        let countedDay = try XCTUnwrap(report.days[1].projects.first { $0.id == "counted" })
        XCTAssertEqual(countedDay.mergedPullRequests, 1)
        XCTAssertEqual(countedDay.mergedLines, 40)

        let first = calls
        XCTAssertGreaterThan(first, 0)
        _ = yields.dailyReport(projects: projects, from: from, to: to, now: start.addingTimeInterval(60))
        XCTAssertEqual(calls, first, "inside the ttl nothing runs")
        _ = yields.dailyReport(projects: projects, from: from, to: to.advanced(by: 1), now: start.addingTimeInterval(60))
        XCTAssertGreaterThan(calls, first, "another range is another read")
        let again = calls
        _ = yields.dailyReport(projects: projects, from: from, to: to, now: start.addingTimeInterval(RepositoryYields.ttlSeconds + 1))
        XCTAssertGreaterThan(calls, again, "past the ttl the root is read again")
    }

    /// `report`'s totals cache and `dailyReport`'s daily cache are
    /// separate: reading one never counts as reading the other, so a page
    /// that only calls `/api/yield` never pays for the per-day bucketing
    /// and vice versa.
    func testTheDailyCacheIsSeparateFromTheTotalsCache() throws {
        let root = try repo("separate")
        try git(root, ["remote", "add", "origin", "https://example.invalid/sep.git"])
        try commit(root, "One (#1)", lines: 1, at: "2026-09-02T10:00:00+07:00")
        try git(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        var calls = 0
        let yields = RepositoryYields(zone: Self.saigon) { args in
            calls += 1
            return RepositoryYield.run(args: args)
        }
        let projects = [RepositoryYields.ProjectRef(id: "separate", name: "separate", root: root, registered: true)]
        let from = DayKey("2026-09-01")!, to = DayKey("2026-09-03")!
        let now = Date()
        _ = yields.report(projects: projects, from: from, to: to, now: now)
        let afterTotals = calls
        XCTAssertGreaterThan(afterTotals, 0)
        _ = yields.dailyReport(projects: projects, from: from, to: to, now: now)
        XCTAssertGreaterThan(calls, afterTotals, "the daily read is not served from the totals cache")
    }

    // MARK: - the route

    func testTheRouteAnswersPerDayCountsAndRefusesAWatchToken() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let root = try repo("served")
        try git(root, ["remote", "add", "origin", "https://example.invalid/s.git"])
        try commit(root, "Served (#5)", lines: 12, at: "2026-09-02T10:00:00+07:00")
        try git(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        let plain = scratch.appendingPathComponent("plain3", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("projects.json")
        try ProjectStore.save([
            Project(id: "served", name: "served", root: ProjectStore.canonicalRoot(root)),
            Project(id: "plain", name: "plain", root: ProjectStore.canonicalRoot(plain)),
        ], to: file)
        let store = ProjectStore(url: file)
        let yields = RepositoryYields(zone: Self.saigon)

        func server(policy: AccessPolicy, yields: RepositoryYields?) throws -> Channel {
            try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(HTTPAPIHandler(
                            registry: SessionRegistry(), policy: policy, agentControl: false, staticRoot: nil,
                            projects: store, repositoryYields: yields
                        ))
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        }
        func get(_ port: Int, _ path: String) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
        }

        let channel = try server(policy: .loopbackOnly, yields: yields)
        let port = channel.localAddress!.port!
        let (status, json) = try await get(port, "/api/yield/daily?from=2026-09-01&to=2026-09-03")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        let days = try XCTUnwrap(json["days"] as? [[String: Any]])
        XCTAssertEqual(days.map { $0["day"] as? String }, ["2026-09-01", "2026-09-02", "2026-09-03"])
        XCTAssertEqual(days[1]["mergedPullRequests"] as? Int, 1)
        XCTAssertEqual(days[1]["mergedLines"] as? Int, 12)
        XCTAssertEqual(days[0]["mergedPullRequests"] as? Int, 0, "zero-filled")
        let projects = try XCTUnwrap(days[1]["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.map { $0["id"] as? String }, ["plain", "served"])
        let plainDay = try XCTUnwrap(projects.first { $0["id"] as? String == "plain" })
        XCTAssertNil(plainDay["mergedPullRequests"], "absent, never zero, for a root with no history")

        let (bad, reason) = try await get(port, "/api/yield/daily?from=2026-09-12&to=2026-09-10")
        XCTAssertEqual(bad, 400)
        XCTAssertEqual(reason["error"] as? String, "from must not be after to")
        let (tooWide, wideReason) = try await get(port, "/api/yield/daily?from=2020-01-01&to=2026-09-03")
        XCTAssertEqual(tooWide, 400)
        XCTAssertEqual(wideReason["error"] as? String, "range must be at most 400 days")
        try channel.close().wait()

        let none = try server(policy: .loopbackOnly, yields: nil)
        let (unavailable, why) = try await get(none.localAddress!.port!, "/api/yield/daily")
        XCTAssertEqual(unavailable, 503)
        XCTAssertEqual(why["error"] as? String, "repository yield unavailable")
        try none.close().wait()

        let watch = "ktw_" + String(repeating: "e", count: 32)
        let full = String(repeating: "f", count: 32)
        let guarded = try server(policy: .proxied(token: full, watchToken: watch, trustedHosts: ["box.example.test"]), yields: yields)
        let guardedPort = guarded.localAddress!.port!
        XCTAssertEqual(try raw(guardedPort, "/api/yield/daily?token=\(watch)").status, 403)
        XCTAssertEqual(try raw(guardedPort, "/api/yield/daily?token=\(full)").status, 200)
        try guarded.close().wait()
        try await group.shutdownGracefully()
    }

    // MARK: - helpers

    private func repo(_ name: String) throws -> String {
        let root = scratch.appendingPathComponent(name, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git(root, ["init", "-q", "-b", "main"])
        try git(root, ["config", "user.email", "crew@example.test"])
        try git(root, ["config", "user.name", "crew"])
        try git(root, ["config", "commit.gpgsign", "false"])
        try git(root, ["config", "tag.gpgsign", "false"])
        return root
    }

    /// One commit adding `lines` lines to a fresh file, authored and
    /// committed at `at`.
    private func commit(_ root: String, _ subject: String, lines: Int, at: String) throws {
        let name = "f-\(UUID().uuidString.prefix(8)).txt"
        let body = (0..<lines).map { "line \($0)" }.joined(separator: "\n") + (lines > 0 ? "\n" : "")
        try body.write(toFile: root + "/" + name, atomically: true, encoding: .utf8)
        try git(root, ["add", name])
        try git(root, ["commit", "-q", "--allow-empty", "-m", subject], at: at)
    }

    private func git(_ root: String, _ args: [String], at: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root] + args
        var environment = ProcessInfo.processInfo.environment
        if let at {
            environment["GIT_AUTHOR_DATE"] = at
            environment["GIT_COMMITTER_DATE"] = at
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        waitForExit(of: process)
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }

    /// A request naming the trusted host, over a raw socket, because
    /// loopback is full grade unconditionally.
    private func raw(_ port: Int, _ path: String) throws -> (status: Int, body: String) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let collector = RawDailyCollector()
        let channel = try ClientBootstrap(group: group)
            .channelInitializer { channel in channel.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: port)
            .wait()
        let request = "GET \(path) HTTP/1.1\r\nHost: box.example.test\r\nConnection: close\r\n\r\n"
        try channel.writeAndFlush(ByteBuffer(string: request)).wait()
        try channel.closeFuture.wait()
        let text = collector.text
        let status = Int(text.split(separator: " ", maxSplits: 2).dropFirst().first ?? "0") ?? 0
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return (status, body)
    }

    private final class RawDailyCollector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private(set) var text = ""
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            text += buffer.readString(length: buffer.readableBytes) ?? ""
        }
    }
}
