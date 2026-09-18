import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// What a repository's history delivered (`agent-dashboard`, capability 7):
/// merged pull requests, merged lines and releases read with `git` from
/// scratch checkouts, the not-a-checkout and the no-remote cases, the
/// parser over a fixed log, and `GET /api/yield` over a real handler.
final class RepositoryYieldTests: XCTestCase {
    static let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-yield-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - the parser

    func testIsPullRequestReadsASquashSuffixOrAMergeSubject() {
        XCTAssertTrue(RepositoryYield.isPullRequest("Say every agent's model on its line (#129)"))
        XCTAssertTrue(RepositoryYield.isPullRequest("Merge pull request #12 from tienan92it/fix"))
        XCTAssertFalse(RepositoryYield.isPullRequest("Back-fill the Cost line on rounds 1 to 4"))
        XCTAssertFalse(RepositoryYield.isPullRequest("Note (see #12)"), "a reference is not a merge")
        XCTAssertFalse(RepositoryYield.isPullRequest("Fix (#)"))
        XCTAssertFalse(RepositoryYield.isPullRequest("Fix (#12a)"))
    }

    func testParseLogReadsEachRecordAndItsInsertions() {
        let rs = "\u{1E}", us = "\u{1F}"
        let output = """
        \(rs)aaa\(us)First (#1)

         3 files changed, 120 insertions(+), 4 deletions(-)
        \(rs)bbb\(us)Docs only (#2)

         1 file changed, 1 insertion(+)
        \(rs)ccc\(us)Empty merge
        \(rs)ddd\(us)Removal (#3)

         2 files changed, 9 deletions(-)

        """
        XCTAssertEqual(RepositoryYield.parseLog(output), [
            .init(sha: "aaa", subject: "First (#1)", insertions: 120),
            .init(sha: "bbb", subject: "Docs only (#2)", insertions: 1),
            .init(sha: "ccc", subject: "Empty merge", insertions: 0),
            .init(sha: "ddd", subject: "Removal (#3)", insertions: 0),
        ])
        XCTAssertEqual(RepositoryYield.parseLog(""), [])
    }

    // MARK: - real checkouts

    /// A checkout with a remote: two squash merges and a merge commit in
    /// the range, one plain commit, one merge before the range, and two
    /// tags, one in the range.
    func testCountsMergedPullRequestsLinesAndReleasesInTheRange() throws {
        let root = try repo("withremote")
        try git(root, ["remote", "add", "origin", "https://example.invalid/repo.git"])
        try commit(root, "Before the range (#1)", lines: 50, at: "2026-08-01T10:00:00+07:00")
        try git(root, ["tag", "v0.1.0"], at: "2026-08-01T11:00:00+07:00")
        try commit(root, "Plain work", lines: 7, at: "2026-09-02T10:00:00+07:00")
        try commit(root, "First merged (#2)", lines: 100, at: "2026-09-03T10:00:00+07:00")
        try commit(root, "Merge pull request #3 from x/y", lines: 20, at: "2026-09-04T23:30:00+07:00")
        try git(root, ["tag", "v0.2.0"], at: "2026-09-04T23:40:00+07:00")
        try commit(root, "Second merged (#4)", lines: 3, at: "2026-09-05T00:10:00+07:00")
        // The remote's main is what "merged" means; point it at HEAD.
        try git(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])

        let yield = RepositoryYield.read(root: root, from: DayKey("2026-09-01")!, to: DayKey("2026-09-04")!, zone: Self.saigon)
        XCTAssertTrue(yield.checkout)
        XCTAssertTrue(yield.remote)
        XCTAssertEqual(yield.branch, "origin/main")
        XCTAssertEqual(yield.mergedPullRequests, 2, "the squash merge and the merge commit; the plain commit is not one")
        XCTAssertEqual(yield.mergedLines, 120)
        XCTAssertEqual(yield.releases, 1)

        let wider = RepositoryYield.read(root: root, from: DayKey("2026-08-01")!, to: DayKey("2026-09-30")!, zone: Self.saigon)
        XCTAssertEqual(wider.mergedPullRequests, 4)
        XCTAssertEqual(wider.mergedLines, 173)
        XCTAssertEqual(wider.releases, 2)

        let empty = RepositoryYield.read(root: root, from: DayKey("2026-07-01")!, to: DayKey("2026-07-31")!, zone: Self.saigon)
        XCTAssertEqual(empty.mergedPullRequests, 0, "a range with nothing merged is a measured zero")
        XCTAssertEqual(empty.mergedLines, 0)
        XCTAssertEqual(empty.releases, 0)
    }

    /// The day bounds follow `zone`, not the machine's zone: a merge at
    /// `00:10+07` on the 5th is outside a range that ends on the 4th in
    /// Saigon and inside it in UTC, whatever `TZ` the test runs under. Both
    /// reads share one fixture, so one of them fails on any machine when
    /// `git` is handed a bound with no zone.
    func testTheRangeBoundsFollowTheZoneNotTheMachine() throws {
        let root = try repo("zoned")
        try git(root, ["remote", "add", "origin", "https://example.invalid/z.git"])
        try commit(root, "Early in Saigon (#1)", lines: 100, at: "2026-09-01T00:10:00+07:00")
        try commit(root, "Inside both (#2)", lines: 10, at: "2026-09-04T23:30:00+07:00")
        try commit(root, "Late in Saigon (#3)", lines: 3, at: "2026-09-05T00:10:00+07:00")
        try git(root, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        let from = DayKey("2026-09-01")!, to = DayKey("2026-09-04")!

        let saigon = RepositoryYield.read(root: root, from: from, to: to, zone: Self.saigon)
        XCTAssertEqual(saigon.mergedPullRequests, 2, "the early and the inside commits")
        XCTAssertEqual(saigon.mergedLines, 110)

        let utc = RepositoryYield.read(root: root, from: from, to: to, zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(utc.mergedPullRequests, 2, "the inside and the late commits: 16:30Z and 17:10Z on the 4th")
        XCTAssertEqual(utc.mergedLines, 13, "the early commit is 17:10Z on August 31st, before the range")
    }

    func testACheckoutWithNoRemoteCountsReleasesAndNoPullRequests() throws {
        let root = try repo("noremote")
        try commit(root, "Local merge (#9)", lines: 10, at: "2026-09-03T10:00:00+07:00")
        try git(root, ["tag", "v1.0.0"], at: "2026-09-03T11:00:00+07:00")
        let yield = RepositoryYield.read(root: root, from: DayKey("2026-09-01")!, to: DayKey("2026-09-30")!, zone: Self.saigon)
        XCTAssertTrue(yield.checkout)
        XCTAssertFalse(yield.remote)
        XCTAssertEqual(yield.branch, "HEAD")
        XCTAssertNil(yield.mergedPullRequests, "a pull request is the remote's concept")
        XCTAssertNil(yield.mergedLines)
        XCTAssertEqual(yield.releases, 1)
    }

    func testADirectoryThatIsNotACheckoutHasNoCounts() throws {
        let root = scratch.appendingPathComponent("plain", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let yield = RepositoryYield.read(root: root, from: DayKey("2026-09-01")!, to: DayKey("2026-09-30")!, zone: Self.saigon)
        XCTAssertEqual(yield, .none)
        XCTAssertNil(yield.mergedPullRequests)
        XCTAssertNil(yield.releases)
        let missing = RepositoryYield.read(root: root + "/nowhere", from: DayKey("2026-09-01")!, to: DayKey("2026-09-30")!, zone: Self.saigon)
        XCTAssertEqual(missing, .none)
    }

    // MARK: - the report and its cache

    func testTheReportSumsTheProjectsThatHaveCountsAndKeepsAnAnswerFiveMinutes() throws {
        let counted = try repo("counted")
        try git(counted, ["remote", "add", "origin", "https://example.invalid/a.git"])
        try commit(counted, "One (#1)", lines: 40, at: "2026-09-03T10:00:00+07:00")
        try git(counted, ["update-ref", "refs/remotes/origin/main", "HEAD"])
        let plain = scratch.appendingPathComponent("plain2", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)

        var calls = 0
        let yields = RepositoryYields(zone: Self.saigon) { args in
            calls += 1
            return RepositoryYield.run(args: args)
        }
        let projects = [
            RepositoryYields.ProjectRef(id: "counted", name: "counted", root: counted, registered: true),
            RepositoryYields.ProjectRef(id: "plain", name: "plain", root: plain, registered: false),
        ]
        let from = DayKey("2026-09-01")!, to = DayKey("2026-09-30")!
        let start = Date()
        let report = yields.report(projects: projects, from: from, to: to, now: start)
        XCTAssertEqual(report.from, "2026-09-01")
        XCTAssertEqual(report.projects.map(\.id), ["counted", "plain"])
        XCTAssertEqual(report.projects[0].yield.mergedPullRequests, 1)
        XCTAssertEqual(report.projects[1].yield, .none)
        XCTAssertEqual(report.totals, .init(checkouts: 1, counted: 1, mergedPullRequests: 1, mergedLines: 40, releases: 0))

        let first = calls
        XCTAssertGreaterThan(first, 0)
        _ = yields.report(projects: projects, from: from, to: to, now: start.addingTimeInterval(60))
        XCTAssertEqual(calls, first, "inside the ttl nothing runs")
        _ = yields.report(projects: projects, from: from, to: to.advanced(by: 1), now: start.addingTimeInterval(60))
        XCTAssertGreaterThan(calls, first, "another range is another read")
        let again = calls
        _ = yields.report(projects: projects, from: from, to: to, now: start.addingTimeInterval(RepositoryYields.ttlSeconds + 1))
        XCTAssertGreaterThan(calls, again, "past the ttl the root is read again")
    }

    // MARK: - the route

    func testTheRouteAnswersEveryProjectAndRefusesAWatchToken() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let root = try repo("served")
        try git(root, ["remote", "add", "origin", "https://example.invalid/s.git"])
        try commit(root, "Served (#5)", lines: 12, at: "2026-09-03T10:00:00+07:00")
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
        let (status, json) = try await get(port, "/api/yield?from=2026-09-01&to=2026-09-30")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        let projects = try XCTUnwrap(json["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.map { $0["id"] as? String }, ["plain", "served"])
        let plainYield = try XCTUnwrap(projects[0]["yield"] as? [String: Any])
        XCTAssertEqual(plainYield["checkout"] as? Bool, false)
        XCTAssertNil(plainYield["mergedPullRequests"], "absent, never zero, for a root with no history")
        let servedYield = try XCTUnwrap(projects[1]["yield"] as? [String: Any])
        XCTAssertEqual(servedYield["mergedPullRequests"] as? Int, 1)
        XCTAssertEqual(servedYield["mergedLines"] as? Int, 12)
        XCTAssertEqual((json["totals"] as? [String: Any])?["mergedPullRequests"] as? Int, 1)
        let (bad, reason) = try await get(port, "/api/yield?from=2026-09-12&to=2026-09-10")
        XCTAssertEqual(bad, 400)
        XCTAssertEqual(reason["error"] as? String, "from must not be after to")
        try channel.close().wait()

        let none = try server(policy: .loopbackOnly, yields: nil)
        let (unavailable, why) = try await get(none.localAddress!.port!, "/api/yield")
        XCTAssertEqual(unavailable, 503)
        XCTAssertEqual(why["error"] as? String, "repository yield unavailable")
        try none.close().wait()

        let watch = "ktw_" + String(repeating: "e", count: 32)
        let full = String(repeating: "f", count: 32)
        let guarded = try server(policy: .proxied(token: full, watchToken: watch, trustedHosts: ["box.example.test"]), yields: yields)
        let guardedPort = guarded.localAddress!.port!
        XCTAssertEqual(try raw(guardedPort, "/api/yield?token=\(watch)").status, 403)
        XCTAssertEqual(try raw(guardedPort, "/api/yield?token=\(full)").status, 200)
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
        let collector = RawCollector()
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

    private final class RawCollector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private(set) var text = ""
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            text += buffer.readString(length: buffer.readableBytes) ?? ""
        }
    }
}
