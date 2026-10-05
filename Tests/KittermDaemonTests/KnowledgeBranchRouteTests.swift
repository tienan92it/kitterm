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

/// `SOCK_STREAM` is an `Int32` on Darwin and a `__socket_type` enum on Glibc.
#if canImport(Darwin)
private let socketType = SOCK_STREAM
#else
private let socketType = Int32(SOCK_STREAM.rawValue)
#endif

/// The two knowledge routes with the open goal branches (`sessions-workflow`
/// round 4): a goal from `origin/goal/<slug>` with its `source` and
/// `pullRequest`, the working-tree-only goal, the drop at a merge, the file
/// from the branch, and that no request waits for `git` or `gh` and neither
/// runs on the event loop. The remote is a scratch bare repository and the
/// pull request list comes from a fake `gh`.
final class KnowledgeBranchRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var fixture: GitFixture!
    private var gh: FakeGH!
    private var runs: Runs!
    private var clock: TestClock!
    private var status: PullRequestStatus!

    /// Where each `git` and `gh` of the routes ran, and how long a fetch is held.
    private final class Runs: @unchecked Sendable {
        private let lock = NIOLock()
        private var onLoop = 0
        private var offQueue = 0
        private var fetches = 0
        private var lists = 0
        private var delay: TimeInterval = 0
        func record(fetch: Bool, list: Bool, onLoop: Bool, onQueue: Bool) {
            lock.withLock {
                if onLoop { self.onLoop += 1 }
                if !onQueue { offQueue += 1 }
                if fetch { fetches += 1 }
                if list { lists += 1 }
            }
        }
        var counts: (onLoop: Int, offQueue: Int, fetches: Int, lists: Int) {
            lock.withLock { (onLoop, offQueue, fetches, lists) }
        }
        var fetchDelay: TimeInterval {
            get { lock.withLock { delay } }
            set { lock.withLock { delay = newValue } }
        }
    }

    override func setUpWithError() throws {
        fixture = try GitFixture()
        setenv("KITTERM_STATE_DIR", fixture.directory.path, 1)
        // The base holds alpha. The branch goal/beta holds beta, a changed
        // alpha, and files outside both. The clone also holds a local goal.
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha"))
        try fixture.push("alpha")
        try fixture.makeClone()
        try fixture.git(["-C", fixture.seed, "checkout", "-q", "-b", "goal/beta"])
        try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta", round: 2))
        try fixture.write("docs/goals/beta/rounds/002.md", GitFixture.record(2))
        try fixture.write("docs/goals/other/STATE.md", GitFixture.state("other"))
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", status: "done", round: 9))
        try fixture.write("secret.md", "outside\n")
        try fixture.push("beta")
        try fixture.git(["-C", fixture.seed, "checkout", "-q", "main"])
        try fixture.write("docs/goals/local/STATE.md", GitFixture.state("local"), in: fixture.clone)
        try ProjectStore.save([Project(id: "hub", name: "hub", root: fixture.clone)])
        _ = ProjectStore.shared.registered()

        gh = try FakeGH()
        try setPulls([(12, "goal/beta", "OPEN"), (11, "chore/tidy", "OPEN"), (10, "goal/alpha", "MERGED")])
        runs = Runs()
        clock = TestClock()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let runs = self.runs!
        let clock = self.clock!
        let path = gh.searchPath
        let status = PullRequestStatus(searchPath: path, run: { executable, args, keepOutput in
            runs.record(
                fetch: false, list: args.contains("list"), onLoop: loop.inEventLoop,
                onQueue: PullRequestStatus.isOnQueue)
            return PullRequestStatus.run(
                executable: executable, args: args, searchPath: path, timeout: 10, keepOutput: keepOutput)
        }, clock: { clock.now })
        self.status = status
        let base = KnowledgeBase(git: { executable, args, input, maxOutput in
            runs.record(
                fetch: args.contains("fetch"), list: false, onLoop: loop.inEventLoop,
                // The one blob of the file route runs on the knowledge file queue.
                onQueue: KnowledgeBase.isOnQueue || args.contains("blob"))
            if args.contains("fetch"), runs.fetchDelay > 0 { Thread.sleep(forTimeInterval: runs.fetchDelay) }
            return KnowledgeBase.run(
                executable: executable, args: args, input: input, maxOutput: maxOutput,
                searchPath: PullRequestStatus.defaultSearchPath
            )
        }, clock: { clock.now })
        let clone = fixture.clone
        let origins = RemoteOrigins(git: { args in
            args.count > 1 && args[1] == clone ? (0, "git@github.com:o/r.git\n") : (2, "")
        })
        let registry = SessionRegistry()
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry, agentControl: false, staticRoot: nil,
                            remoteOrigins: origins, pullRequestStatus: status, knowledgeBase: base
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        settle()
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        unsetenv("KITTERM_STATE_DIR")
        gh.remove()
        fixture.remove()
    }

    // MARK: - helpers

    /// What the fake `gh` prints for `pr list`.
    private func setPulls(_ pulls: [(number: Int, head: String, state: String)]) throws {
        let items = pulls.map { pull -> [String: Any] in
            [
                "number": pull.number, "title": pull.head, "state": pull.state, "isDraft": false,
                "headRefName": pull.head, "url": "https://github.com/o/r/pull/\(pull.number)",
                "statusCheckRollup": [[String: Any]](), "additions": 1, "deletions": 0,
            ]
        }
        try JSONSerialization.data(withJSONObject: items)
            .write(to: gh.directory.appendingPathComponent("pulls.json"))
    }

    /// Wait for every read the last request started.
    private func settle() {
        PullRequestStatus.queue.sync {}
        KnowledgeBase.queue.sync {}
        KnowledgeFile.queue.sync {}
    }

    private struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var goals: [[String: Any]] { json["goals"] as? [[String: Any]] ?? [] }
        var slugs: [String] { goals.compactMap { $0["slug"] as? String } }
        func goal(_ slug: String) -> [String: Any]? { goals.first { $0["slug"] as? String == slug } }
    }

    /// One HTTP/1.1 request over a raw socket.
    private func get(_ target: String, extra: [String] = []) throws -> Answer {
        let fd = socket(AF_INET, socketType, 0)
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
        let lines = ["GET \(target) HTTP/1.1", "Host: 127.0.0.1:\(port!)", "Connection: close"] + extra
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

    private let summary = "/api/projects/hub/knowledge"

    /// The answer once the pulls cache and the knowledge cache both hold a
    /// read: the pulls first, then the knowledge read that takes its list.
    private func primed() throws -> Answer {
        status.refreshIfDue(repository: "o/r")
        PullRequestStatus.queue.sync {}
        _ = try get(summary)
        settle()
        return try get(summary)
    }

    // MARK: - the summary

    func testAnOpenGoalBranchShowsWithItsSourceAndItsPullRequest() throws {
        let answer = try primed()
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.json["source"] as? String, "origin/main")
        XCTAssertEqual(answer.slugs, ["alpha", "beta", "local"])
        let beta = try XCTUnwrap(answer.goal("beta"))
        XCTAssertEqual(beta["source"] as? String, "origin/goal/beta")
        XCTAssertEqual(beta["pullRequest"] as? Int, 12)
        XCTAssertEqual(beta["round"] as? Int, 2)
        XCTAssertEqual(beta["lastRecord"] as? String, "beta/rounds/002.md")
        XCTAssertNil(beta["sourceReason"])
        let alpha = try XCTUnwrap(answer.goal("alpha"))
        XCTAssertEqual(alpha["source"] as? String, "origin/main")
        XCTAssertEqual(alpha["status"] as? String, "active", "the branch's alpha is not read")
        XCTAssertNil(alpha["pullRequest"])
        let local = try XCTUnwrap(answer.goal("local"))
        XCTAssertEqual(local["source"] as? String, "working tree")
        XCTAssertNil(answer.goal("other"), "a folder of the branch outside its own goal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.clone + "/docs/goals/beta"))
    }

    func testFromAColdStartTheBranchShowsAfterThePullsReadAndTheNextMinute() throws {
        let first = try get(summary)
        XCTAssertEqual(first.json["source"] as? String, "working tree")
        XCTAssertEqual(first.slugs, ["alpha", "local"])
        settle()
        XCTAssertEqual(runs.counts.lists, 1, "the knowledge route feeds the pulls cache")
        let second = try get(summary)
        XCTAssertEqual(second.json["source"] as? String, "origin/main")
        XCTAssertEqual(second.slugs, ["alpha", "local"], "the first read had no pull request list yet")
        clock.advance(KnowledgeBase.refreshSeconds + 1)
        _ = try get(summary)
        settle()
        XCTAssertEqual(try get(summary).slugs, ["alpha", "beta", "local"])
    }

    func testAMergedPullRequestsBranchIsDroppedAndTheBaseAnswers() throws {
        XCTAssertEqual(try primed().goal("beta")?["source"] as? String, "origin/goal/beta")
        let tag = try XCTUnwrap(try get(summary).headers["etag"])
        XCTAssertEqual(try get(summary, extra: ["If-None-Match: \(tag)"]).status, 304)

        // The merge: the base gets beta at round 3, `gh` says merged.
        try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta", status: "done", round: 3))
        try fixture.push("the merge")
        try setPulls([(12, "goal/beta", "MERGED")])
        clock.advance(KnowledgeBase.refreshSeconds + 1)
        _ = try get(summary)
        settle()
        clock.advance(KnowledgeBase.refreshSeconds + 1)
        _ = try get(summary)
        settle()
        let after = try get(summary, extra: ["If-None-Match: \(tag)"])
        XCTAssertEqual(after.status, 200, "the source is in the tag")
        let beta = try XCTUnwrap(after.goal("beta"))
        XCTAssertEqual(beta["source"] as? String, "origin/main")
        XCTAssertNil(beta["pullRequest"])
        XCTAssertEqual(beta["round"] as? Int, 3)
        XCTAssertEqual(beta["status"] as? String, "done")
    }

    // MARK: - the file

    func testTheFileRouteServesABranchGoalFromItsBranchAndNothingElseOfIt() throws {
        _ = try primed()
        let state = try get(summary + "/beta/STATE.md")
        XCTAssertEqual(state.status, 200)
        XCTAssertTrue(state.text.contains("- Round: 2 of 3"), state.text)
        XCTAssertEqual(state.headers["content-type"], "text/plain; charset=utf-8")
        XCTAssertEqual(state.headers["x-content-type-options"], "nosniff")
        XCTAssertEqual(state.headers["content-security-policy"], "default-src 'none'; sandbox")
        XCTAssertEqual(try get(summary + "/beta/rounds/002.md").text, GitFixture.record(2))
        XCTAssertEqual(try get(summary + "/beta/none.md").status, 404)
        XCTAssertEqual(try get(summary + "/beta").status, 404)
        XCTAssertEqual(try get(summary + "/beta/../../secret.md").status, 400)
        // What the branch holds outside its goal folder is never served.
        XCTAssertEqual(try get(summary + "/other/STATE.md").status, 404)
        XCTAssertEqual(try get(summary + "/secret.md").status, 404)
        let alpha = try get(summary + "/alpha/STATE.md")
        XCTAssertTrue(alpha.text.contains("- Status: active"), "the base's alpha")
        // A working-tree folder the summary does not list is not served.
        try fixture.write("docs/goals/notes/draft.md", "a draft\n", in: fixture.clone)
        XCTAssertEqual(try get(summary + "/notes/draft.md").status, 404)
        // A goal only the working tree holds comes from the working tree.
        let local = try get(summary + "/local/STATE.md")
        XCTAssertEqual(local.status, 200)
        XCTAssertTrue(local.text.contains("# STATE: local"))
    }

    // MARK: - off the loop

    func testNoRequestWaitsForASlowFetchAndNothingRunsOnTheLoop() throws {
        status.refreshIfDue(repository: "o/r")
        PullRequestStatus.queue.sync {}
        runs.fetchDelay = 1.5
        let started = Date()
        let first = try get(summary)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(try get(summary + "/alpha/STATE.md").status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the answers came before the fetch ended")
        XCTAssertEqual(first.json["sourceReason"] as? String, "not read yet")
        settle()
        XCTAssertEqual(try get(summary).slugs, ["alpha", "beta", "local"])
        _ = try get(summary + "/beta/STATE.md")
        let counts = runs.counts
        XCTAssertEqual(counts.fetches, 1, "one fetch for the base and the branch")
        XCTAssertEqual(counts.onLoop, 0, "no git and no gh on the event loop")
        XCTAssertEqual(counts.offQueue, 0, "every git and gh on its own queue")
    }
}
