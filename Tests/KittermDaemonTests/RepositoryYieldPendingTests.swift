import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// The yield routes never wait for `git` (`fleet-first-paint`, capability
/// 2, completion condition 3). Every case runs against a `git` stub that
/// blocks until the test lets it go: an answer that arrives while the
/// stub blocks did not wait for it.
final class RepositoryYieldPendingTests: XCTestCase {
    static let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-yield-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A `git` that answers one checkout with a remote, the branch
    /// `origin/main` and one merged pull request of `lines` lines on
    /// 2026-09-02. While `blocked`, each read stops at its first command.
    private final class StubGit: @unchecked Sendable {
        private let condition = NSCondition()
        private var blocked: Bool
        private var readCount = 0
        private var lineCount = 40
        private let entered = DispatchSemaphore(value: 0)

        init(blocked: Bool) { self.blocked = blocked }

        /// The reads that started.
        var reads: Int { condition.withLock { readCount } }

        func setLines(_ lines: Int) { condition.withLock { lineCount = lines } }

        func block() { condition.withLock { blocked = true } }

        func release() {
            condition.withLock {
                blocked = false
                condition.broadcast()
            }
        }

        /// Wait until one more read reached the stub.
        func waitForRead(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(entered.wait(timeout: .now() + 10), .success, "no read reached git", file: file, line: line)
        }

        func run(_ args: [String]) -> (status: Int32, output: String)? {
            let command = Array(args.dropFirst(2))
            switch command.first {
            case "rev-parse" where command.contains("--is-inside-work-tree"):
                condition.lock()
                readCount += 1
                entered.signal()
                while blocked { condition.wait() }
                condition.unlock()
                return (0, "true\n")
            case "rev-parse":
                return (command.last == "refs/remotes/origin/main" ? 0 : 1, "")
            case "remote":
                return (0, "origin\n")
            case "log":
                let lines = condition.withLock { lineCount }
                let head = command.contains { $0.contains("%cI") } ? "2026-09-02T10:00:00+07:00" : "abc123"
                return (0, "\u{1E}\(head)\u{1F}One (#1)\n\n 1 file changed, \(lines) insertions(+)\n")
            default:
                return (0, "")
            }
        }
    }

    private let projects = [RepositoryYields.ProjectRef(id: "p", name: "p", root: "/work/p", registered: true)]
    private let from = DayKey("2026-09-01")!
    private let to = DayKey("2026-09-03")!

    private func yields(_ stub: StubGit, queue: DispatchQueue, file: URL? = nil, zone: TimeZone = RepositoryYieldPendingTests.saigon) -> RepositoryYields {
        RepositoryYields(zone: zone, file: file, queue: queue) { stub.run($0) }
    }

    // MARK: - nothing kept

    func testWithNothingKeptTheReportAnswersAtOnceSaysPendingAndStartsOneRead() {
        let stub = StubGit(blocked: true)
        let queue = DispatchQueue(label: "test.yield.nothing")
        let yields = yields(stub, queue: queue)
        let start = Date()

        let first = yields.report(projects: projects, from: from, to: to, now: start)
        XCTAssertTrue(first.pending)
        XCTAssertEqual(first.unread, 1)
        XCTAssertNil(first.readAt)
        XCTAssertNil(first.ageSeconds)
        XCTAssertEqual(first.projects[0].pending, true)
        XCTAssertNil(first.projects[0].yield.mergedPullRequests, "no figure before the read")
        XCTAssertEqual(first.totals, .init())

        stub.waitForRead()
        let second = yields.report(projects: projects, from: from, to: to, now: start.addingTimeInterval(2))
        XCTAssertTrue(second.pending)
        XCTAssertEqual(second.unread, 1)

        stub.release()
        queue.sync {}
        XCTAssertEqual(stub.reads, 1, "the second request started no read of the same root and range")
        let third = yields.report(projects: projects, from: from, to: to, now: start.addingTimeInterval(10))
        XCTAssertFalse(third.pending)
        XCTAssertEqual(third.unread, 0)
        XCTAssertNil(third.projects[0].pending)
        XCTAssertEqual(third.projects[0].yield.mergedPullRequests, 1)
        XCTAssertEqual(third.totals.mergedLines, 40)
        XCTAssertEqual(third.ageSeconds, 10)
        XCTAssertNotNil(third.readAt)
        XCTAssertEqual(stub.reads, 1)
    }

    func testWithNothingKeptTheDailyReportAnswersAtOnceSaysPendingAndStartsOneRead() {
        let stub = StubGit(blocked: true)
        let queue = DispatchQueue(label: "test.yield.nothing-daily")
        let yields = yields(stub, queue: queue)
        let start = Date()

        let first = yields.dailyReport(projects: projects, from: from, to: to, now: start)
        XCTAssertTrue(first.pending)
        XCTAssertEqual(first.unread, 1)
        XCTAssertNil(first.ageSeconds)
        XCTAssertEqual(first.days.count, 3)
        XCTAssertNil(first.days[1].projects[0].mergedPullRequests, "no figure before the read")

        stub.waitForRead()
        XCTAssertTrue(yields.dailyReport(projects: projects, from: from, to: to, now: start).pending)
        stub.release()
        queue.sync {}
        XCTAssertEqual(stub.reads, 1, "the second request started no read of the same root and range")
        let third = yields.dailyReport(projects: projects, from: from, to: to, now: start.addingTimeInterval(10))
        XCTAssertFalse(third.pending)
        XCTAssertEqual(third.unread, 0)
        XCTAssertEqual(third.days[1].mergedPullRequests, 1)
        XCTAssertEqual(third.days[1].mergedLines, 40)
        XCTAssertEqual(third.ageSeconds, 10)
    }

    // MARK: - an old answer

    func testAnAnswerOlderThanTheIntervalIsServedWhileOneRefreshRuns() {
        let stub = StubGit(blocked: false)
        let queue = DispatchQueue(label: "test.yield.old")
        let yields = yields(stub, queue: queue)
        let start = Date()
        _ = yields.report(projects: projects, from: from, to: to, now: start)
        _ = yields.dailyReport(projects: projects, from: from, to: to, now: start)
        queue.sync {}
        XCTAssertEqual(stub.reads, 2)

        stub.block()
        stub.setLines(99)
        let late = start.addingTimeInterval(RepositoryYields.ttlSeconds)
        let old = yields.report(projects: projects, from: from, to: to, now: late)
        XCTAssertTrue(old.pending, "one refresh runs")
        XCTAssertEqual(old.unread, 0)
        XCTAssertEqual(old.totals.mergedLines, 40, "the kept figures, not the refresh's")
        XCTAssertEqual(old.ageSeconds, Int(RepositoryYields.ttlSeconds))
        stub.waitForRead()
        let oldDaily = yields.dailyReport(projects: projects, from: from, to: to, now: late)
        XCTAssertTrue(oldDaily.pending)
        XCTAssertEqual(oldDaily.days[1].mergedLines, 40)

        _ = yields.report(projects: projects, from: from, to: to, now: late.addingTimeInterval(2))
        _ = yields.dailyReport(projects: projects, from: from, to: to, now: late.addingTimeInterval(2))
        stub.release()
        queue.sync {}
        XCTAssertEqual(stub.reads, 4, "one refresh per route, no second read while one runs")
        let fresh = yields.report(projects: projects, from: from, to: to, now: late.addingTimeInterval(4))
        XCTAssertFalse(fresh.pending)
        XCTAssertEqual(fresh.totals.mergedLines, 99)
        XCTAssertEqual(fresh.ageSeconds, 4)
        XCTAssertEqual(yields.dailyReport(projects: projects, from: from, to: to, now: late.addingTimeInterval(4)).days[1].mergedLines, 99)
    }

    // MARK: - the file

    func testTheFirstRequestAfterARestartIsServedFromTheFile() throws {
        let file = scratch.appendingPathComponent("state/yield-cache.json")
        let start = Date()
        let before = StubGit(blocked: false)
        let firstQueue = DispatchQueue(label: "test.yield.restart-1")
        let first = yields(before, queue: firstQueue, file: file)
        _ = first.report(projects: projects, from: from, to: to, now: start)
        _ = first.dailyReport(projects: projects, from: from, to: to, now: start)
        firstQueue.sync {}
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)

        // The restart: a new instance on the same file, and a git that blocks.
        let after = StubGit(blocked: true)
        let secondQueue = DispatchQueue(label: "test.yield.restart-2")
        let second = yields(after, queue: secondQueue, file: file)
        let soon = second.report(projects: projects, from: from, to: to, now: start.addingTimeInterval(60))
        XCTAssertFalse(soon.pending, "inside the interval the file's answer needs no read")
        XCTAssertEqual(soon.unread, 0)
        XCTAssertEqual(soon.totals.mergedLines, 40)
        XCTAssertEqual(soon.ageSeconds, 60)
        let soonDaily = second.dailyReport(projects: projects, from: from, to: to, now: start.addingTimeInterval(60))
        XCTAssertEqual(soonDaily.unread, 0)
        XCTAssertEqual(soonDaily.days[1].mergedPullRequests, 1)
        XCTAssertEqual(after.reads, 0)

        let late = second.report(projects: projects, from: from, to: to, now: start.addingTimeInterval(900))
        XCTAssertTrue(late.pending, "an old answer of the file is served while one refresh runs")
        XCTAssertEqual(late.totals.mergedLines, 40)
        XCTAssertEqual(late.ageSeconds, 900)
        after.release()
        secondQueue.sync {}
    }

    func testAFileThatIsCorruptOrOfAnotherVersionOrZoneKeepsNoAnswer() throws {
        let file = scratch.appendingPathComponent("yield-cache.json")
        let start = Date()
        func write() throws -> [String: Any] {
            let stub = StubGit(blocked: false)
            let queue = DispatchQueue(label: "test.yield.file-write")
            _ = yields(stub, queue: queue, file: file).report(projects: projects, from: from, to: to, now: start)
            queue.sync {}
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        }
        func unreadAfterLoad(zone: TimeZone = Self.saigon) -> Int {
            let stub = StubGit(blocked: true)
            let queue = DispatchQueue(label: "test.yield.file-load")
            let unread = yields(stub, queue: queue, file: file, zone: zone)
                .report(projects: projects, from: from, to: to, now: start).unread
            stub.release()
            queue.sync {}
            return unread
        }

        let good = try write()
        XCTAssertEqual(good["version"] as? Int, RepositoryYields.formatVersion)
        XCTAssertEqual(good["zone"] as? String, "Asia/Ho_Chi_Minh")
        XCTAssertEqual(unreadAfterLoad(), 0, "the file as written is served")

        _ = try write()
        XCTAssertEqual(unreadAfterLoad(zone: TimeZone(identifier: "UTC")!), 1, "another zone has other day bounds")

        var old = try write()
        old["version"] = 0
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        XCTAssertEqual(unreadAfterLoad(), 1, "another format version is not read")

        try Data("{ not json".utf8).write(to: file)
        XCTAssertEqual(unreadAfterLoad(), 1, "a corrupt file keeps no answer")
        let replaced = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((replaced["totals"] as? [Any])?.count, 1, "the next write replaced the corrupt file")
    }

    func testTheFileKeepsWhatWasAskedLatelyAndNoMoreThanTheBound() throws {
        let file = scratch.appendingPathComponent("yield-cache.json")
        let stub = StubGit(blocked: false)
        let queue = DispatchQueue(label: "test.yield.bounds")
        let yields = yields(stub, queue: queue, file: file)
        let start = Date()
        func kept() throws -> [[String: Any]] {
            queue.sync {}
            let shape = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            return try XCTUnwrap(shape["totals"] as? [[String: Any]])
        }

        for step in 0..<(RepositoryYields.maxEntries + 6) {
            _ = yields.report(projects: projects, from: from, to: to.advanced(by: step), now: start.addingTimeInterval(Double(step)))
            queue.sync {}
        }
        let bounded = try kept()
        XCTAssertEqual(bounded.count, RepositoryYields.maxEntries)
        XCTAssertFalse(bounded.contains { $0["to"] as? Int == to.number }, "the least recently asked went first")
        XCTAssertTrue(bounded.contains { $0["to"] as? Int == to.advanced(by: RepositoryYields.maxEntries + 5).number })

        let later = start.addingTimeInterval(RepositoryYields.keepSeconds + 3600)
        _ = yields.report(projects: projects, from: from.advanced(by: 1), to: to, now: later)
        let aged = try kept()
        XCTAssertEqual(aged.count, 1, "an answer nobody asked for 48 hours is dropped")
        XCTAssertEqual(aged[0]["from"] as? Int, from.advanced(by: 1).number)
    }

    // MARK: - the midnight roll

    func testTheFirstAskOfADayIsServedFromTheAnswerOfTheDayBefore() {
        let stub = StubGit(blocked: false)
        let queue = DispatchQueue(label: "test.yield.roll")
        let yields = yields(stub, queue: queue)
        let start = Date()
        _ = yields.report(projects: projects, from: from, to: to, now: start)
        _ = yields.dailyReport(projects: projects, from: from, to: to, now: start)
        queue.sync {}

        stub.block()
        let next = start.addingTimeInterval(60)
        let rolled = yields.report(projects: projects, from: from, to: to.advanced(by: 1), now: next)
        XCTAssertTrue(rolled.pending, "the read of the new range runs")
        XCTAssertEqual(rolled.unread, 0, "yesterday's answer stands in")
        XCTAssertEqual(rolled.to, "2026-09-04")
        XCTAssertEqual(rolled.totals.mergedLines, 40)
        XCTAssertEqual(rolled.ageSeconds, 60)
        XCTAssertNil(rolled.projects[0].pending)

        let moved = yields.report(projects: projects, from: from.advanced(by: 1), to: to.advanced(by: 1), now: next)
        XCTAssertEqual(moved.unread, 1, "a total of another first day is another sum")

        // The day-by-day series is cut to the range: the lifetime range
        // moves both its bounds each day.
        let daily = yields.dailyReport(projects: projects, from: from.advanced(by: 1), to: to.advanced(by: 1), now: next)
        XCTAssertTrue(daily.pending)
        XCTAssertEqual(daily.unread, 0)
        XCTAssertEqual(daily.days.map(\.day), ["2026-09-02", "2026-09-03", "2026-09-04"])
        XCTAssertEqual(daily.days[0].mergedPullRequests, 1, "2026-09-02 keeps its count at its own day")
        XCTAssertEqual(daily.days[1].projects[0].mergedPullRequests, 0)
        XCTAssertNil(daily.days[2].projects[0].mergedPullRequests, "the new day has no figure before its read")
        XCTAssertEqual(daily.ageSeconds, 60)

        stub.release()
        queue.sync {}
        let read = yields.report(projects: projects, from: from, to: to.advanced(by: 1), now: next)
        XCTAssertFalse(read.pending)
        XCTAssertEqual(read.ageSeconds, 0, "the range's own answer replaced the stand-in")
    }

    // MARK: - the routes

    func testBothRoutesAnswerWhileGitBlocks() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let root = scratch.appendingPathComponent("served", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("projects.json")
        try ProjectStore.save([Project(id: "served", name: "served", root: ProjectStore.canonicalRoot(root))], to: file)
        let store = ProjectStore(url: file)
        let stub = StubGit(blocked: true)
        let queue = DispatchQueue(label: "test.yield.routes")
        let yields = yields(stub, queue: queue)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPAPIHandler(
                        registry: SessionRegistry(), policy: .loopbackOnly, agentControl: false, staticRoot: nil,
                        projects: store, repositoryYields: yields
                    ))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = channel.localAddress!.port!
        func get(_ path: String) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
        }

        let (status, body) = try await get("/api/yield?from=2026-09-01&to=2026-09-03")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(body["pending"] as? Bool, true)
        XCTAssertEqual(body["unread"] as? Int, 1)
        XCTAssertNil(body["readAt"])
        XCTAssertNil(body["ageSeconds"])
        let project = try XCTUnwrap((body["projects"] as? [[String: Any]])?.first)
        XCTAssertEqual(project["pending"] as? Bool, true)

        let (dailyStatus, daily) = try await get("/api/yield/daily?from=2026-09-01&to=2026-09-03")
        XCTAssertEqual(dailyStatus, 200)
        XCTAssertEqual(daily["pending"] as? Bool, true)
        XCTAssertEqual(daily["unread"] as? Int, 1)
        XCTAssertEqual((daily["days"] as? [Any])?.count, 3)
        XCTAssertEqual(stub.reads, 1, "git still blocks in the first read; both answers arrived")

        stub.release()
        queue.sync {}
        let (_, read) = try await get("/api/yield?from=2026-09-01&to=2026-09-03")
        XCTAssertEqual(read["pending"] as? Bool, false)
        XCTAssertEqual(read["unread"] as? Int, 0)
        XCTAssertEqual(read["ageSeconds"] as? Int, 0)
        XCTAssertNotNil(read["readAt"] as? String)
        XCTAssertEqual((read["totals"] as? [String: Any])?["mergedLines"] as? Int, 40)

        try await channel.close()
        try await group.shutdownGracefully()
    }
}
