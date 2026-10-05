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

/// The two knowledge routes over `KnowledgeBase`: the `source` and the
/// `sourceReason` of the summary, the file from the same source, the
/// `ETag`, and that no request waits for a fetch and no `git` runs on the
/// event loop. The remote is a scratch bare repository.
final class KnowledgeBaseRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var fixture: GitFixture!
    private var runs: Runs!
    private var clock: TestClock!
    private var bare: String!

    /// Where each `git` of the routes ran, and how long a fetch is held.
    private final class Runs: @unchecked Sendable {
        private let lock = NIOLock()
        private var onLoop = 0
        private var fetchesOnQueue = 0
        private var fetches = 0
        private var delay: TimeInterval = 0
        func record(args: [String], onLoop: Bool, onQueue: Bool) {
            lock.withLock {
                if onLoop { self.onLoop += 1 }
                if args.contains("fetch") {
                    fetches += 1
                    if onQueue { fetchesOnQueue += 1 }
                }
            }
        }
        var counts: (onLoop: Int, fetches: Int, fetchesOnQueue: Int) { lock.withLock { (onLoop, fetches, fetchesOnQueue) } }
        var fetchDelay: TimeInterval {
            get { lock.withLock { delay } }
            set { lock.withLock { delay = newValue } }
        }
    }

    override func setUpWithError() throws {
        fixture = try GitFixture()
        setenv("KITTERM_STATE_DIR", fixture.directory.path, 1)
        // hub: a clone of the bare repository. bare: a checkout with no remote.
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha"))
        try fixture.write("docs/goals/alpha/rounds/001.md", GitFixture.record(1))
        try fixture.push("alpha")
        try fixture.makeClone()
        bare = fixture.directory.appendingPathComponent("bare").path
        try fixture.git(["init", "-q", "-b", "main", bare])
        try fixture.write("docs/goals/local/STATE.md", GitFixture.state("local"), in: bare)
        try ProjectStore.save([
            Project(id: "hub", name: "hub", root: fixture.clone), Project(id: "bare", name: "bare", root: bare),
        ])
        _ = ProjectStore.shared.registered()

        runs = Runs()
        clock = TestClock()
        try serve(base: makeBase())
    }

    private func makeBase() -> KnowledgeBase {
        let runs = self.runs!
        let clock = self.clock!
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let loop = group.next()
        return KnowledgeBase(git: { executable, args, input, maxOutput in
            runs.record(args: args, onLoop: loop.inEventLoop, onQueue: KnowledgeBase.isOnQueue)
            if args.contains("fetch"), runs.fetchDelay > 0 { Thread.sleep(forTimeInterval: runs.fetchDelay) }
            return KnowledgeBase.run(
                executable: executable, args: args, input: input, maxOutput: maxOutput,
                searchPath: PullRequestStatus.defaultSearchPath
            )
        }, clock: { clock.now })
    }

    private func serve(base: KnowledgeBase?) throws {
        if group == nil { group = MultiThreadedEventLoopGroup(numberOfThreads: 1) }
        let registry = SessionRegistry()
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(registry: registry, agentControl: false, staticRoot: nil, knowledgeBase: base)
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        KnowledgeBase.queue.sync {}
        KnowledgeFile.queue.sync {}
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        group = nil
        unsetenv("KITTERM_STATE_DIR")
        fixture.remove()
    }

    // MARK: - helpers

    private struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var goals: [[String: Any]] { json["goals"] as? [[String: Any]] ?? [] }
        var slugs: [String] { goals.compactMap { $0["slug"] as? String } }
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

    /// The first request starts the read; this waits for it to end.
    private func primed(_ target: String = "/api/projects/hub/knowledge") throws -> Answer {
        _ = try get(target)
        KnowledgeBase.queue.sync {}
        return try get(target)
    }

    /// The merge on the remote: alpha is done, beta is new.
    private func merge() throws {
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", status: "done", round: 2))
        try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta"))
        try fixture.push("the merge")
    }

    // MARK: - the summary

    func testTheFirstAnswerIsTheWorkingTreeAndTheNextOneTheMergedBase() throws {
        try merge()
        let first = try get("/api/projects/hub/knowledge")
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.json["source"] as? String, "working tree")
        XCTAssertEqual(first.json["sourceReason"] as? String, "not read yet")
        XCTAssertEqual(first.slugs, ["alpha"])
        XCTAssertEqual(first.goals.first?["status"] as? String, "active")

        KnowledgeBase.queue.sync {}
        let second = try get("/api/projects/hub/knowledge")
        XCTAssertEqual(second.status, 200)
        XCTAssertEqual(second.json["ok"] as? Bool, true)
        XCTAssertEqual(second.json["project"] as? String, "hub")
        XCTAssertEqual(second.json["source"] as? String, "origin/main")
        XCTAssertNil(second.json["sourceReason"])
        XCTAssertEqual(second.slugs, ["beta", "alpha"])
        XCTAssertEqual(second.goals.last?["status"] as? String, "done")
        XCTAssertEqual(second.goals.last?["lastRecord"] as? String, "alpha/rounds/001.md")
        // Nobody pulled.
        let onDisk = try String(contentsOfFile: fixture.clone + "/docs/goals/alpha/STATE.md", encoding: .utf8)
        XCTAssertTrue(onDisk.contains("- Status: active"))
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "status", "--porcelain"]), "")
    }

    func testAMergeShowsAfterTheNextMinute() throws {
        XCTAssertEqual(try primed().slugs, ["alpha"])
        try merge()
        XCTAssertEqual(try primed().slugs, ["alpha"], "inside the minute no fetch runs")
        XCTAssertEqual(runs.counts.fetches, 1)
        clock.advance(60)
        let after = try primed()
        XCTAssertEqual(after.slugs, ["beta", "alpha"])
        XCTAssertEqual(runs.counts.fetches, 2)
    }

    func testTheETagCoversTheSourceAndAnswers304() throws {
        try merge()
        let first = try get("/api/projects/hub/knowledge")
        let workingTag = try XCTUnwrap(first.headers["etag"])
        KnowledgeBase.queue.sync {}
        let second = try get("/api/projects/hub/knowledge", extra: ["If-None-Match: \(workingTag)"])
        XCTAssertEqual(second.status, 200, "the source changed, so the body and its tag did")
        let tag = try XCTUnwrap(second.headers["etag"])
        XCTAssertNotEqual(tag, workingTag)
        let third = try get("/api/projects/hub/knowledge", extra: ["If-None-Match: \(tag)"])
        XCTAssertEqual(third.status, 304)
        XCTAssertEqual(third.body.count, 0)
        XCTAssertEqual(third.headers["etag"], tag)
    }

    func testAProjectWithNoRemoteReadsTheWorkingTreeAndSaysWhy() throws {
        let answer = try primed("/api/projects/bare/knowledge")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.json["source"] as? String, "working tree")
        XCTAssertEqual(answer.json["sourceReason"] as? String, "no origin remote")
        XCTAssertEqual(answer.slugs, ["local"])
        XCTAssertEqual(runs.counts.fetches, 0)
    }

    func testAFailedFetchKeepsTheLocalBaseAndSaysWhy() throws {
        XCTAssertNil(try primed().json["sourceReason"])
        let fetchedAt = clock.now
        try fixture.git(["-C", fixture.clone, "remote", "set-url", "origin", fixture.directory.path + "/gone.git"])
        try fixture.write("docs/goals/gamma/STATE.md", GitFixture.state("gamma"), in: fixture.clone)
        clock.advance(60)
        let answer = try primed()
        XCTAssertEqual(answer.json["source"] as? String, "origin/main")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(
            answer.json["sourceReason"] as? String, "git fetch exited 128; last good fetch " + formatter.string(from: fetchedAt))
        XCTAssertEqual(answer.slugs, ["alpha"], "the base, not the working tree")
        // The reason holds no clock reading that moves, so the tag holds.
        let tag = try XCTUnwrap(answer.headers["etag"])
        clock.advance(60)
        _ = try primed()
        XCTAssertEqual(try get("/api/projects/hub/knowledge", extra: ["If-None-Match: \(tag)"]).status, 304)
    }

    func testAFailedFetchWithNoLocalBaseReadsTheWorkingTreeAndSaysWhy() throws {
        try fixture.git(["-C", fixture.clone, "remote", "set-url", "origin", fixture.directory.path + "/gone.git"])
        try fixture.git(["-C", fixture.clone, "remote", "set-head", "origin", "-d"])
        try fixture.git(["-C", fixture.clone, "update-ref", "-d", "refs/remotes/origin/main"])
        let answer = try primed()
        XCTAssertEqual(answer.json["source"] as? String, "working tree")
        XCTAssertEqual(answer.json["sourceReason"] as? String, "git fetch exited 128; no local origin/main")
        XCTAssertEqual(answer.slugs, ["alpha"])
    }

    func testAHandlerWithNoBaseReaderReadsTheWorkingTree() throws {
        try? channel.close().wait()
        try serve(base: nil)
        let answer = try get("/api/projects/hub/knowledge")
        XCTAssertEqual(answer.json["source"] as? String, "working tree")
        XCTAssertEqual(answer.json["sourceReason"] as? String, "no base branch reader")
        XCTAssertEqual(answer.slugs, ["alpha"])
        XCTAssertEqual(try get("/api/projects/hub/knowledge/alpha/STATE.md").status, 200)
    }

    // MARK: - the file

    func testTheFileRouteReadsTheSameSource() throws {
        try merge()
        try fixture.write("docs/goals/draft.md", "a local draft\n", in: fixture.clone)
        let before = try get("/api/projects/hub/knowledge/alpha/STATE.md")
        XCTAssertEqual(before.status, 200)
        XCTAssertTrue(before.text.contains("- Status: active"), "the working tree before the first read")
        XCTAssertEqual(try get("/api/projects/hub/knowledge/draft.md").text, "a local draft\n")

        KnowledgeBase.queue.sync {}
        let after = try get("/api/projects/hub/knowledge/alpha/STATE.md")
        XCTAssertEqual(after.status, 200)
        XCTAssertTrue(after.text.contains("- Status: done"), after.text)
        XCTAssertEqual(after.headers["content-type"], "text/plain; charset=utf-8")
        XCTAssertEqual(after.headers["x-content-type-options"], "nosniff")
        XCTAssertEqual(after.headers["content-security-policy"], "default-src 'none'; sandbox")
        XCTAssertEqual(try get("/api/projects/hub/knowledge/beta/STATE.md").status, 200, "a file the clone never had")
        XCTAssertEqual(try get("/api/projects/hub/knowledge/draft.md").status, 404, "the base has no such file")
        XCTAssertEqual(try get("/api/projects/hub/knowledge/alpha").status, 404)
        XCTAssertEqual(try get("/api/projects/hub/knowledge/alpha/../../secret").status, 400)
    }

    func testTheFileRouteKeepsTheJailOnTheBase() throws {
        try fixture.write("secret.md", "outside\n")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.seed + "/docs/goals/alpha/link.md", withDestinationPath: "../../../secret.md")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.seed + "/docs/goals/linked", withDestinationPath: "alpha")
        try fixture.write("docs/goals/alpha/big.md", String(repeating: "x", count: KnowledgeFile.maxBytes + 1))
        try fixture.push("links")
        XCTAssertEqual(try primed().json["source"] as? String, "origin/main")
        let link = try get("/api/projects/hub/knowledge/alpha/link.md")
        XCTAssertEqual(link.status, 404)
        XCTAssertFalse(link.text.contains("outside"))
        XCTAssertEqual(try get("/api/projects/hub/knowledge/linked/STATE.md").status, 404)
        XCTAssertEqual(try get("/api/projects/hub/knowledge/alpha/big.md").status, 413)
        XCTAssertEqual(try get("/api/projects/hub/knowledge/alpha/STATE.md").status, 200)
    }

    // MARK: - off the loop

    func testNoRequestWaitsForASlowFetchAndNoGitRunsOnTheLoop() throws {
        try merge()
        runs.fetchDelay = 4
        let started = Date()
        let summary = try get("/api/projects/hub/knowledge")
        let file = try get("/api/projects/hub/knowledge/alpha/STATE.md")
        let again = try get("/api/projects/hub/knowledge")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0, "three answers while the 4 s fetch still runs")
        XCTAssertEqual(summary.json["source"] as? String, "working tree")
        XCTAssertEqual(again.json["sourceReason"] as? String, "not read yet")
        XCTAssertEqual(file.status, 200)

        KnowledgeBase.queue.sync {}
        XCTAssertEqual(try get("/api/projects/hub/knowledge").json["source"] as? String, "origin/main")
        XCTAssertEqual(try get("/api/projects/hub/knowledge/alpha/STATE.md").status, 200)
        KnowledgeFile.queue.sync {}
        let counts = runs.counts
        XCTAssertEqual(counts.fetches, 1)
        XCTAssertEqual(counts.fetchesOnQueue, 1, "the fetch ran on the base queue")
        XCTAssertEqual(counts.onLoop, 0, "no git ran on the event loop")
    }
}
