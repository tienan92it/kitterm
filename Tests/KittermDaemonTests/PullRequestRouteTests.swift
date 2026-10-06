#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/projects/<id>/pulls`: the body, the reasons, the `ETag`, the
/// grade, the 404, and that no `gh` runs on the event loop or holds the
/// answer. The `gh` is `FakeGH`; the `git` behind `RemoteOrigins` is a
/// closure, so no real `gh` and no real `git` runs.
final class PullRequestRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var stateDir: URL!
    private var gh: FakeGH!
    private var runs: Runs!
    private var clock: TestClock!

    private static let watch = "ktw_" + String(repeating: "e", count: 32)
    private static let full = String(repeating: "f", count: 32)
    private static let trustedHost = "box.example.test"

    /// Where each `gh` of the route ran.
    private final class Runs: @unchecked Sendable {
        private let lock = NIOLock()
        private var onLoop = 0
        private var onQueue = 0
        func record(onLoop: Bool, onQueue: Bool) {
            lock.withLock {
                if onLoop { self.onLoop += 1 }
                if onQueue { self.onQueue += 1 }
            }
        }
        var counts: (onLoop: Int, onQueue: Int) { lock.withLock { (onLoop, onQueue) } }
    }

    override func setUpWithError() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-pull-routes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.path), isDirectory: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        // hub: origin on GitHub; lab: origin on another host; bare: no remote.
        // found: a checkout no file registers, origin on GitHub.
        let found = stateDir.appendingPathComponent("found/.git", isDirectory: true)
        try FileManager.default.createDirectory(at: found, withIntermediateDirectories: true)
        let foundRoot = found.deletingLastPathComponent().path
        var roots: [String: String] = [:]
        for name in ["hub", "lab", "bare"] {
            let url = stateDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            roots[name] = url.path
        }
        try ProjectStore.save(roots.map { Project(id: $0.key, name: $0.key, root: $0.value) })
        _ = ProjectStore.shared.registered()
        let remotes = [
            roots["hub"]!: "git@github.com:o/r.git\n", roots["lab"]!: "git@gitlab.com:o/r.git\n",
            foundRoot: "https://github.com/o/found\n",
        ]
        let origins = RemoteOrigins(git: { args in
            guard args.count > 1, let remote = remotes[args[1]] else { return (2, "") }
            return (0, remote)
        })

        gh = try FakeGH()
        runs = Runs()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let runs = self.runs!
        let path = gh.searchPath
        clock = TestClock()
        let clock = self.clock!
        let status = PullRequestStatus(searchPath: path, run: { executable, args, keepOutput in
            runs.record(
                onLoop: loop.inEventLoop,
                onQueue: PullRequestStatus.isOnQueue
            )
            return PullRequestStatus.run(
                executable: executable, args: args, searchPath: path, timeout: 10, keepOutput: keepOutput)
        }, clock: { clock.now })
        let registry = SessionRegistry()
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
                            policy: .proxied(
                                token: Self.full, watchToken: Self.watch, trustedHosts: [Self.trustedHost]
                            ),
                            agentControl: false,
                            staticRoot: nil,
                            remoteOrigins: origins,
                            pullRequestStatus: status
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        PullRequestStatus.queue.sync {}
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
        gh.remove()
    }

    // MARK: - helpers

    private struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var pulls: [[String: Any]] { json["pulls"] as? [[String: Any]] ?? [] }
    }

    /// One HTTP/1.1 request over a raw socket, so the `Host` header is ours.
    private func get(_ target: String, host: String? = nil, extra: [String] = []) throws -> Answer {
        let fd = socket(AF_INET, streamSocketType, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0, "connect failed: errno \(errno)")
        let lines = ["GET \(target) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port!)")", "Connection: close"] + extra
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        request.withUnsafeBytes { XCTAssertEqual(send(fd, $0.baseAddress, $0.count, 0), request.count) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        guard let split = received.range(of: Data("\r\n\r\n".utf8)) else {
            XCTFail("no header block in \(String(decoding: received, as: UTF8.self))")
            return Answer(status: 0, headers: [:], body: Data())
        }
        let head = String(decoding: received[..<split.lowerBound], as: UTF8.self).split(separator: "\r\n")
        let status = Int(head.first?.split(separator: " ").dropFirst().first ?? "0") ?? 0
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Answer(status: status, headers: headers, body: received[split.upperBound...])
    }

    /// The first request starts the read; this waits for it to end.
    private func primed(_ target: String = "/api/projects/hub/pulls") throws -> Answer {
        _ = try get(target)
        PullRequestStatus.queue.sync {}
        return try get(target)
    }

    // MARK: - the body

    func testTheFirstAnswerIsTheEmptyCacheAndTheNextOneTheList() throws {
        let first = try get("/api/projects/hub/pulls")
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.json["ok"] as? Bool, true)
        XCTAssertEqual(first.json["project"] as? String, "hub")
        XCTAssertEqual(first.json["reason"] as? String, "not read yet")
        XCTAssertEqual(first.pulls.count, 0)
        XCTAssertNil(first.json["readAt"])
        XCTAssertNil(first.json["ageSeconds"])

        PullRequestStatus.queue.sync {}
        let second = try get("/api/projects/hub/pulls")
        XCTAssertEqual(second.status, 200)
        XCTAssertEqual(second.headers["content-type"], "application/json")
        XCTAssertNil(second.json["reason"])
        XCTAssertEqual(second.json["readAt"] as? Int64, Int64(clock.now.timeIntervalSince1970 * 1000))
        XCTAssertNotNil(second.json["ageSeconds"] as? Int)
        XCTAssertEqual(second.pulls.map { $0["number"] as? Int }, [185, 184, 7])
        let open = second.pulls[0]
        XCTAssertEqual(Set(open.keys), ["number", "title", "state", "draft", "headRefName", "url", "ci", "additions", "deletions", "createdAt", "updatedAt"])
        XCTAssertEqual(open["createdAt"] as? String, "2026-10-03T10:00:00Z")
        XCTAssertEqual(open["updatedAt"] as? String, "2026-10-05T18:34:00Z", "the wait of a ready pull request counts from it")
        XCTAssertEqual(open["state"] as? String, "open")
        XCTAssertEqual(open["draft"] as? Bool, true)
        XCTAssertEqual(open["ci"] as? String, "pending")
        XCTAssertEqual(open["headRefName"] as? String, "goal/sessions-workflow")
        XCTAssertEqual(open["url"] as? String, "https://github.com/o/r/pull/185")
        XCTAssertEqual(open["additions"] as? Int, 16844)
        XCTAssertEqual(open["deletions"] as? Int, 52)
        XCTAssertEqual(second.pulls[1]["state"] as? String, "merged")
        XCTAssertEqual(second.pulls[1]["mergedAt"] as? String, "2026-10-02T01:42:11Z")
        XCTAssertEqual(second.pulls[1]["ci"] as? String, "passing")
        XCTAssertEqual(second.pulls[2]["state"] as? String, "closed")
        XCTAssertNil(second.pulls[2]["ci"])
        XCTAssertNil(second.pulls[2]["updatedAt"], "absent when gh printed none")
        XCTAssertEqual(gh.calls.first?.hasPrefix("pr list --repo o/r --state all --limit 50 --json "), true)
    }

    func testRequestsInsideAMinuteRunOneGh() throws {
        _ = try primed()
        for _ in 0..<5 { _ = try get("/api/projects/hub/pulls") }
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.listCalls, 1)
    }

    // MARK: - the reasons

    func testAProjectWithNoGitHubRemoteAnswersAnEmptyListAndTheReason() throws {
        for id in ["lab", "bare"] {
            let answer = try primed("/api/projects/\(id)/pulls")
            XCTAssertEqual(answer.status, 200, id)
            XCTAssertEqual(answer.json["reason"] as? String, "no GitHub remote", id)
            XCTAssertEqual(answer.pulls.count, 0, id)
            XCTAssertNil(answer.json["readAt"], id)
        }
        XCTAssertEqual(gh.calls, [], "no gh for a project with no GitHub remote")
    }

    func testAFailingGhAnswersTheReason() throws {
        try gh.set(mode: "logged-out")
        let answer = try primed()
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.json["reason"] as? String, "gh is not logged in")
        XCTAssertEqual(answer.pulls.count, 0)
    }

    // MARK: - the ETag

    func testETagAnd304() throws {
        let answer = try primed()
        let etag = try XCTUnwrap(answer.headers["etag"])
        XCTAssertTrue(etag.hasPrefix("\"") && etag.hasSuffix("\""))
        let again = try get("/api/projects/hub/pulls", extra: ["If-None-Match: \(etag)"])
        XCTAssertEqual(again.status, 304)
        XCTAssertEqual(again.body.count, 0)
        XCTAssertEqual(again.headers["etag"], etag)
        let other = try get("/api/projects/hub/pulls", extra: ["If-None-Match: \"0\""])
        XCTAssertEqual(other.status, 200)
        XCTAssertEqual(other.headers["etag"], etag)
        XCTAssertNotEqual(try get("/api/projects/lab/pulls").headers["etag"], etag, "another body, another tag")
    }

    /// A failed read changes the body, so the old tag gets the new body
    /// once; the new tag then answers 304 while the failure stands.
    func testA304AfterAFailedRead() throws {
        let good = try primed()
        let goodTag = try XCTUnwrap(good.headers["etag"])
        try gh.set(mode: "fail")
        clock.advance(60)
        let failed = try primed()
        XCTAssertEqual(failed.status, 200)
        XCTAssertEqual(failed.json["reason"] as? String, "gh pr list exited 1: GraphQL: Could not resolve to a Repository")
        XCTAssertEqual(failed.pulls.count, 3, "the last good list stays")
        XCTAssertEqual(failed.json["readAt"] as? Int64, good.json["readAt"] as? Int64)
        let failedTag = try XCTUnwrap(failed.headers["etag"])
        XCTAssertNotEqual(failedTag, goodTag)
        XCTAssertEqual(try get("/api/projects/hub/pulls", extra: ["If-None-Match: \(goodTag)"]).status, 200)
        let again = try get("/api/projects/hub/pulls", extra: ["If-None-Match: \(failedTag)"])
        XCTAssertEqual(again.status, 304)
        XCTAssertEqual(again.body.count, 0)
        XCTAssertEqual(gh.listCalls, 2)
    }

    func testTheETagDoesNotChangeWithTheAge() {
        let pulls = PullRequestStatus.parse(Data(FakeGH.pulls.utf8)) ?? []
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = PullRequestStatus.Snapshot(pulls: pulls, readAt: readAt, reason: nil)
        let (early, earlyTag) = HTTPAPIHandler.pullsBody(project: "hub", snapshot: snapshot, now: readAt.addingTimeInterval(1))
        let (late, lateTag) = HTTPAPIHandler.pullsBody(project: "hub", snapshot: snapshot, now: readAt.addingTimeInterval(45))
        XCTAssertNotEqual(early, late, "ageSeconds moved")
        XCTAssertEqual(earlyTag, lateTag)
        let age = (try? JSONSerialization.jsonObject(with: late) as? [String: Any])?["ageSeconds"] as? Int
        XCTAssertEqual(age, 45)
        var changed = snapshot
        changed.pulls[0].draft = false
        XCTAssertNotEqual(HTTPAPIHandler.pullsBody(project: "hub", snapshot: changed, now: readAt).1, earlyTag)
        var failed = snapshot
        failed.reason = "gh is not logged in"
        XCTAssertNotEqual(HTTPAPIHandler.pullsBody(project: "hub", snapshot: failed, now: readAt).1, earlyTag)
    }

    // MARK: - the grade and the 404

    func testFullGradeOnly() throws {
        let watch = try get("/api/projects/hub/pulls?token=\(Self.watch)", host: Self.trustedHost)
        XCTAssertEqual(watch.status, 403)
        let none = try get("/api/projects/hub/pulls", host: Self.trustedHost)
        XCTAssertNotEqual(none.status, 200)
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.calls, [], "a refused request starts no gh")
        let full = try get("/api/projects/hub/pulls?token=\(Self.full)", host: Self.trustedHost)
        XCTAssertEqual(full.status, 200)
    }

    /// A project a session's cwd discovered is served from the id the store
    /// gave its root, with no session listing; before the store saw the
    /// root, the id is unknown.
    func testADiscoveredProjectIsServedFromTheStore() throws {
        XCTAssertEqual(try get("/api/projects/found/pulls").status, 404)
        let root = stateDir.appendingPathComponent("found").path
        XCTAssertEqual(ProjectStore.shared.resolve(cwd: root)?.id, "found")
        let answer = try primed("/api/projects/found/pulls")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.pulls.count, 3)
        XCTAssertEqual(gh.calls.first?.hasPrefix("pr list --repo o/found "), true)
    }

    func testAnUnknownProjectIs404() throws {
        let answer = try get("/api/projects/nowhere/pulls")
        XCTAssertEqual(answer.status, 404)
        XCTAssertEqual(answer.json["ok"] as? Bool, false)
        PullRequestStatus.queue.sync {}
        XCTAssertEqual(gh.calls, [])
    }

    // MARK: - never on the loop, never in the request

    func testGhRunsOnItsQueueAndNeverOnTheEventLoop() throws {
        try gh.set(mode: "logged-out")
        _ = try primed()
        let counts = runs.counts
        XCTAssertEqual(counts.onQueue, 2, "gh pr list and gh auth token, both on kitterm.pulls")
        XCTAssertEqual(counts.onLoop, 0)
    }

    func testARequestDoesNotWaitForGh() throws {
        try gh.set(mode: "slow")
        let started = Date()
        let first = try get("/api/projects/hub/pulls")
        let second = try get("/api/projects/hub/pulls")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "two answers while the 2 s gh still runs")
        XCTAssertEqual(first.json["reason"] as? String, "not read yet")
        XCTAssertEqual(second.json["reason"] as? String, "not read yet")
        // The loop stays free for another route too.
        XCTAssertEqual(try get("/api/health").status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }
}
