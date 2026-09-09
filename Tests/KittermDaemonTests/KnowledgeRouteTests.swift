#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/projects/<id>/knowledge` and `/knowledge/<path>`: the jail,
/// the cap, the content types, the 404s, the summary, and the grade.
final class KnowledgeRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var sessions: [PtySession] = []
    private var port: Int!
    private var stateDir: URL!
    private var alpha: String!
    private var outside: String!

    private static let watch = "ktw_" + String(repeating: "e", count: 32)
    private static let full = String(repeating: "f", count: 32)
    private static let trustedHost = "box.example.test"

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: KnowledgeRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-knowledge-routes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.path), isDirectory: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)

        // alpha: a registered project with a package; outside: what the
        // symlinks point at; beta: its knowledge directory is a symlink;
        // gamma: registered, no knowledge directory; repo: a git checkout
        // with a package, discovered by a session's cwd and not served.
        alpha = try dir("alpha")
        outside = try dir("outside")
        try write("outside/secret.md", "# secret\n")
        try write("alpha/docs/goals/STATE.md", Self.stateText)
        try write("alpha/docs/goals/goal.md", "# Goal: alpha ships\n")
        try write("alpha/docs/goals/notes.txt", "plain notes\n")
        try write("alpha/docs/goals/rounds/001.md", "# Round 001: a\n\n## Decision\n\ndone.\n")
        try write("alpha/docs/goals/rounds/002.md", "# Round 002: b\n\n## Decision\n\npropose (`plan.md`: x)\n")
        try write("alpha/docs/goals/big.txt", String(repeating: "x", count: KnowledgeFile.maxBytes + 1))
        try write("alpha/docs/goals/exact.txt", String(repeating: "y", count: KnowledgeFile.maxBytes))
        try write("alpha/Package.swift", "// not knowledge\n")
        try link("alpha/docs/goals/escape.md", to: outside + "/secret.md")
        try link("alpha/docs/goals/linkdir", to: outside)
        let beta = try dir("beta/docs")
        try link("beta/docs/goals", to: outside)
        let gamma = try dir("gamma")
        let repo = try dir("repo")
        _ = try dir("repo/.git")
        try write("repo/docs/goals/STATE.md", "# STATE: repo-goal\n\n- Status: active\n")
        // pipe.md: a FIFO where a record could be; delta: `rounds/` is a
        // symlink to a directory with a record; epsilon: the root does not
        // exist when the store loads and becomes a symlink afterwards.
        XCTAssertEqual(mkfifo(alpha + "/docs/goals/pipe.md", 0o600), 0, "mkfifo: errno \(errno)")
        try write("outside/rounds/009.md", "# Round 009: elsewhere\n\n## Decision\n\npropose (x)\n")
        try write("outside/docs/goals/STATE.md", "# STATE: outside-goal\n")
        // zeta: the latest record is `7.md`, not `007.md`.
        let zeta = try dir("zeta")
        try write("zeta/docs/goals/STATE.md", "# STATE: zeta-goal\n\n- Round: 3 of 3, budget spent\n")
        try write("zeta/docs/goals/rounds/006.md", "# Round 006\n\n## Decision\n\ndone.\n")
        try write("zeta/docs/goals/rounds/7.md", "# Round 7\n\n## Decision\n\npropose (seven)\n")
        let delta = try dir("delta/docs/goals")
        try write("delta/docs/goals/STATE.md", "# STATE: delta-goal\n")
        try link("delta/docs/goals/rounds", to: outside + "/rounds")
        try ProjectStore.save([
            Project(id: "alpha", name: "Alpha", root: alpha),
            Project(id: "beta", name: "Beta", root: URL(fileURLWithPath: beta).deletingLastPathComponent().path),
            Project(id: "gamma", name: "Gamma", root: gamma),
            Project(id: "zeta", name: "Zeta", root: zeta),
            Project(id: "delta", name: "Delta", root: URL(fileURLWithPath: delta).deletingLastPathComponent().deletingLastPathComponent().path),
            Project(id: "epsilon", name: "Epsilon", root: stateDir.appendingPathComponent("epsilon").path),
        ])
        _ = ProjectStore.shared.registered()
        try link("epsilon", to: outside)
        _ = repo

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        registry = SessionRegistry()
        let registry = self.registry!
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
                            // Loopback is full grade; a request naming the
                            // trusted host must present a token, which is
                            // how the watch grade reaches the route.
                            policy: .proxied(
                                token: Self.full, watchToken: Self.watch, trustedHosts: [Self.trustedHost]
                            ),
                            agentControl: false,
                            staticRoot: nil
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        for session in sessions { session.terminate() }
        try? channel.close().wait()
        try? await group.shutdownGracefully()
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
    }

    private static let stateText = """
        # STATE: alpha-goal

        - Status: active
        - Round: 2 of 3 in this budget
        - Last floor: green

        ## Proposals waiting on the human

        - one
        - two

        ## Next action

        Round 3: dashboard.
        Then the rest.
        """

    // MARK: - helpers

    private func dir(_ path: String) throws -> String {
        let url = stateDir.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func write(_ path: String, _ text: String) throws {
        let url = stateDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func link(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: stateDir.appendingPathComponent(path).path, withDestinationPath: target)
    }

    private struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// One HTTP/1.1 request over a raw socket, so the path reaches the daemon
    /// byte for byte (a URL client folds `..` away) and the `Host` header is
    /// ours to set (URLSession will not).
    private func raw(_ target: String, host: String? = nil, extra: [String] = []) throws -> Answer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
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

    private func get(_ path: String) async throws -> Answer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return Answer(status: http?.statusCode ?? 0, headers: headers, body: data)
    }

    private func status(_ path: String) async throws -> Int {
        try await get(path).status
    }

    private func json(_ answer: Answer) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: answer.body) as? [String: Any], answer.text)
    }

    // MARK: - the jail

    func testDotDotSegmentIs400() throws {
        let answer = try raw("/api/projects/alpha/knowledge/../../Package.swift")
        XCTAssertEqual(answer.status, 400, answer.text)
        XCTAssertEqual(try raw("/api/projects/alpha/knowledge/rounds/../STATE.md").status, 400)
        XCTAssertEqual(try raw("/api/projects/alpha/knowledge/%2e%2e/%2e%2e/Package.swift").status, 400, "percent-encoded")
        XCTAssertEqual(try raw("/api/projects/alpha/knowledge/./STATE.md").status, 400, "a `.` segment")
        XCTAssertEqual(try raw("/api/projects/alpha/knowledge/rounds//001.md").status, 400, "an empty segment")
    }

    func testAbsolutePathIs400() throws {
        XCTAssertEqual(try raw("/api/projects/alpha/knowledge//etc/passwd").status, 400)
        XCTAssertEqual(try raw("/api/projects/alpha/knowledge/%2Fetc%2Fpasswd").status, 400)
        XCTAssertEqual(try raw("/api/projects/alpha/knowledge/").status, 400, "an empty path")
    }

    func testSymlinkInsideTheDirectoryPointingOutsideIs404() async throws {
        let file = try await get("/api/projects/alpha/knowledge/escape.md")
        XCTAssertEqual(file.status, 404, file.text)
        XCTAssertTrue(file.text.contains("symlink"), file.text)
        let under = try await get("/api/projects/alpha/knowledge/linkdir/secret.md")
        XCTAssertEqual(under.status, 404, "a file under a symlinked directory")
    }

    func testSymlinkedKnowledgeDirectoryIs404() async throws {
        let file = try await get("/api/projects/beta/knowledge/secret.md")
        XCTAssertEqual(file.status, 404, file.text)
        let summary = try await get("/api/projects/beta/knowledge")
        XCTAssertEqual(summary.status, 404, "the summary refuses it too")
    }

    /// The open is `O_NONBLOCK` and the type comes from `fstat`, so a FIFO
    /// is refused at once instead of holding the knowledge queue until a
    /// writer opens it.
    func testFIFOAtThePathIs404AtOnce() async throws {
        let started = Date()
        let answer = try await get("/api/projects/alpha/knowledge/pipe.md")
        XCTAssertEqual(answer.status, 404, answer.text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the open blocked on the FIFO")
        // The queue is free: the next read answers.
        let next = try await status("/api/projects/alpha/knowledge/STATE.md")
        XCTAssertEqual(next, 200)
    }

    func testSymlinkedRoundsDirectoryListsNothing() async throws {
        let summary = try await get("/api/projects/delta/knowledge")
        XCTAssertEqual(summary.status, 200, summary.text)
        let body = try json(summary)
        XCTAssertEqual(body["slug"] as? String, "delta-goal")
        XCTAssertNil(body["lastRound"], "a symlinked rounds/ must not leak its target's names")
        XCTAssertNil(body["lastDecision"])
        let record = try await status("/api/projects/delta/knowledge/rounds/009.md")
        XCTAssertEqual(record, 404)
    }

    func testRootThatBecameASymlinkIs404() async throws {
        let summary = try await status("/api/projects/epsilon/knowledge")
        XCTAssertEqual(summary, 404, "the listing must not follow the root")
        let file = try await status("/api/projects/epsilon/knowledge/STATE.md")
        XCTAssertEqual(file, 404)
    }

    func testPathThatResolvesUnderTheDirectoryIsServed() async throws {
        let nested = try await get("/api/projects/alpha/knowledge/rounds/001.md")
        XCTAssertEqual(nested.status, 200, nested.text)
        XCTAssertTrue(nested.text.hasPrefix("# Round 001"))
        XCTAssertEqual(try KnowledgeFile.read(root: alpha, knowledge: "docs/goals", path: "rounds/002.md").contentType,
                       "text/markdown; charset=utf-8")
    }

    // MARK: - the cap and the types

    func testFileOverTheCapIs413AndAtTheCapIsServed() async throws {
        let big = try await get("/api/projects/alpha/knowledge/big.txt")
        XCTAssertEqual(big.status, 413, big.text)
        let exact = try await get("/api/projects/alpha/knowledge/exact.txt")
        XCTAssertEqual(exact.status, 200)
        XCTAssertEqual(exact.body.count, KnowledgeFile.maxBytes)
    }

    func testContentTypes() async throws {
        let markdown = try await get("/api/projects/alpha/knowledge/STATE.md")
        XCTAssertEqual(markdown.status, 200)
        XCTAssertEqual(markdown.header("content-type"), "text/markdown; charset=utf-8")
        XCTAssertEqual(markdown.header("x-content-type-options"), "nosniff")
        XCTAssertEqual(markdown.text, Self.stateText)
        let plain = try await get("/api/projects/alpha/knowledge/notes.txt")
        XCTAssertEqual(plain.status, 200)
        XCTAssertEqual(plain.header("content-type"), "text/plain; charset=utf-8")
    }

    // MARK: - 404s

    func testMissingFileDirectoryUnknownProjectAndNoKnowledgeDirectoryAre404() async throws {
        let missing = try await status("/api/projects/alpha/knowledge/missing.md")
        XCTAssertEqual(missing, 404)
        let directory = try await status("/api/projects/alpha/knowledge/rounds")
        XCTAssertEqual(directory, 404, "a directory is not a file")
        let unknownFile = try await status("/api/projects/nobody/knowledge/STATE.md")
        XCTAssertEqual(unknownFile, 404)
        let unknownSummary = try await status("/api/projects/nobody/knowledge")
        XCTAssertEqual(unknownSummary, 404)
        let invalid = try await status("/api/projects/Bad_ID/knowledge")
        XCTAssertEqual(invalid, 404, "an invalid id")
        let other = try await status("/api/projects/alpha/other")
        XCTAssertEqual(other, 404, "not the knowledge route")
        let noDirectory = try await status("/api/projects/gamma/knowledge")
        XCTAssertEqual(noDirectory, 404, "no knowledge directory")
        let noDirectoryFile = try await status("/api/projects/gamma/knowledge/STATE.md")
        XCTAssertEqual(noDirectoryFile, 404)
    }

    // MARK: - the summary

    func testSummaryFieldsAndETag() async throws {
        let answer = try await get("/api/projects/alpha/knowledge")
        XCTAssertEqual(answer.status, 200, answer.text)
        let body = try json(answer)
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertEqual(body["slug"] as? String, "alpha-goal")
        XCTAssertEqual(body["goal"] as? String, "alpha ships")
        XCTAssertEqual(body["status"] as? String, "active")
        XCTAssertEqual(body["round"] as? Int, 2)
        XCTAssertEqual(body["budget"] as? Int, 3)
        XCTAssertEqual(body["lastFloor"] as? String, "green")
        XCTAssertEqual(body["nextAction"] as? String, "Round 3: dashboard. Then the rest.")
        XCTAssertEqual(body["proposals"] as? Int, 2)
        XCTAssertEqual(body["lastRound"] as? Int, 2)
        XCTAssertEqual(body["lastDecision"] as? String, "propose (`plan.md`: x)")

        let etag = try XCTUnwrap(answer.header("etag"))
        XCTAssertTrue(etag.hasPrefix("\""))
        let again = try raw("/api/projects/alpha/knowledge", extra: ["If-None-Match: \(etag)"])
        XCTAssertEqual(again.status, 304, again.text)
        XCTAssertTrue(again.body.isEmpty)
        XCTAssertEqual(again.header("etag"), etag)

        try write("alpha/docs/goals/STATE.md", Self.stateText.replacingOccurrences(of: "2 of 3", with: "3 of 3"))
        let changed = try raw("/api/projects/alpha/knowledge", extra: ["If-None-Match: \(etag)"])
        XCTAssertEqual(changed.status, 200, "a changed file has a new tag")
        XCTAssertNotEqual(changed.header("etag"), etag)
    }

    func testLatestRecordIsReadByItsRealName() async throws {
        let answer = try await get("/api/projects/zeta/knowledge")
        XCTAssertEqual(answer.status, 200, answer.text)
        let body = try json(answer)
        XCTAssertEqual(body["lastRound"] as? Int, 7)
        XCTAssertEqual(body["lastRecord"] as? String, "rounds/7.md")
        XCTAssertEqual(body["lastDecision"] as? String, "propose (seven)")
        XCTAssertEqual(body["budget"] as? Int, 3, "the comma after the budget")
        let record = try await status("/api/projects/zeta/knowledge/rounds/7.md")
        XCTAssertEqual(record, 200)
    }

    /// A discovered project is not served: the fleet view asks only for
    /// registered ids, and a watch token must not read the package of every
    /// repository a pane visits.
    func testDiscoveredProjectIs404OnBothRoutes() async throws {
        let repo = stateDir.appendingPathComponent("repo").path
        let session = try PtySession.spawn(cwd: repo, labels: SessionLabels([:]))
        sessions.append(session)
        _ = await registry.register(session)
        for _ in 0..<200 {
            if let leader = session.foregroundLeader, leader.group == session.pid,
               leader.name != SpawnHelperPath.name, session.liveCwd == repo { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let listed = try await get("/api/projects")
        let ids = ((try json(listed))["projects"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        XCTAssertTrue(ids.contains("repo"), "the session discovered the project: \(ids)")
        let summary = try await get("/api/projects/repo/knowledge")
        XCTAssertEqual(summary.status, 404, summary.text)
        let file = try await status("/api/projects/repo/knowledge/STATE.md")
        XCTAssertEqual(file, 404)
    }

    // MARK: - grade and the loop

    func testWatchTokenReadsTheFileAndTheSummary() throws {
        let file = try raw("/api/projects/alpha/knowledge/STATE.md?token=\(Self.watch)", host: Self.trustedHost)
        XCTAssertEqual(file.status, 200, file.text)
        XCTAssertEqual(file.text, Self.stateText)
        let summary = try raw("/api/projects/alpha/knowledge?token=\(Self.watch)", host: Self.trustedHost)
        XCTAssertEqual(summary.status, 200, summary.text)
        let none = try raw("/api/projects/alpha/knowledge/STATE.md", host: Self.trustedHost)
        XCTAssertEqual(none.status, 403, "no token through the trusted host")
        let jailed = try raw("/api/projects/alpha/knowledge/../../Package.swift?token=\(Self.watch)", host: Self.trustedHost)
        XCTAssertEqual(jailed.status, 400)
    }

    func testTheEventLoopNeverTakesTheStoreLock() async throws {
        let before = ProjectStore.shared.eventLoopCalls
        _ = try await get("/api/projects/alpha/knowledge")
        _ = try await get("/api/projects/alpha/knowledge/STATE.md")
        _ = try await get("/api/projects/nobody/knowledge")
        XCTAssertEqual(ProjectStore.shared.eventLoopCalls, before, "a ProjectStore lock take ran on an event loop")
    }
}
