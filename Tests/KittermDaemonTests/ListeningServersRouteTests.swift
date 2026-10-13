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

/// `GET /api/servers` against the real kernel, loop and registry: a
/// listener in a pane (joined by its tty), one a pane started and detached
/// from the terminal (joined by the parent chain), one outside kitterm (the
/// test's own HTTP server, which answers the probe), the grade, the 503,
/// the 304 and the Linux body. The pane listeners are `nc -k -l` on a free
/// loopback port, which accepts the probe and answers nothing; its stdin
/// is `/dev/null`, else the background job reads the terminal, gets
/// `SIGTTIN` and stops.
final class ListeningServersRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var sessions: [PtySession] = []
    private var port: Int!
    private var extraChannels: [Channel] = []
    /// The `nc` processes the pane tests started: a background job outlives
    /// its shell, so each is ended here, with `SIGKILL` because a background
    /// job that touched the terminal may be stopped and a stopped process
    /// acts on no `SIGTERM`.
    private var listeners: [pid_t] = []

    private static let watch = "ktw_" + String(repeating: "e", count: 32)
    private static let full = String(repeating: "f", count: 32)
    private static let trustedHost = "box.example.test"

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: ListeningServersRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        registry = SessionRegistry()
        // The test process is the "daemon" here and also the outside HTTP
        // server, so no pid is excluded.
        channel = try makeServer(cache: ListeningServers(excludedPids: [], refreshSeconds: 0))
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        for session in sessions { session.terminate() }
        sessions = []
        for pid in listeners { kill(pid, SIGKILL) }
        listeners = []
        ListeningServers.queue.sync {}
        for extra in extraChannels { try? await extra.close().get() }
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    private func makeServer(cache: ListeningServers?) throws -> Channel {
        let registry = self.registry!
        return try ServerBootstrap(group: group)
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
                            listeningServers: cache
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    // MARK: - helpers

    private struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var servers: [[String: Any]] { json["servers"] as? [[String: Any]] ?? [] }
    }

    /// One HTTP/1.1 request over a raw socket, so the `Host` header is ours.
    private func get(
        _ target: String, port overridePort: Int? = nil, host: String? = nil, extra: [String] = []
    ) throws -> Answer {
        let port = overridePort ?? self.port!
        let fd = socket(AF_INET, streamSocketType, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connect failed: errno \(errno)")
        let lines = ["GET \(target) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")", "Connection: close"] + extra
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

    /// A read, then the answer it produced.
    private func read() throws -> Answer {
        _ = try get("/api/servers")
        ListeningServers.queue.sync {}
        return try get("/api/servers")
    }

    /// Until a row on `port` is in the answer; the kernel sees a listener
    /// a moment after the shell starts it.
    private func row(onPort port: Int, seconds: Double = 20, file: StaticString = #filePath, line: UInt = #line)
        throws -> [String: Any]
    {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let row = try read().servers.first(where: { $0["port"] as? Int == port }) { return row }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("no row on port \(port) within \(seconds) s", file: file, line: line)
        return [:]
    }

    private func makeSession() async throws -> (UUID, PtySession) {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse(nil))
        sessions.append(session)
        // The reader is what flushes input to the shell; the daemon makes it
        // before any client, the test makes it here.
        try await session.makeReader(group: group, eventLoop: group.next()).get()
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered, "registry refused the session")
        return (id, session)
    }

    /// A loopback port nothing listens on right now.
    private func freePort() throws -> Int {
        let fd = socket(AF_INET, streamSocketType, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    // MARK: - the rows

    #if canImport(Darwin)
    func testAListenerInAPaneIsThePanesByItsTtyAndIsNotHTTP() async throws {
        let (id, session) = try await makeSession()
        session.setName("db")
        let port = try freePort()
        try session.write(Data("nc -k -l 127.0.0.1 \(port) </dev/null &\n".utf8))
        let row = try self.row(onPort: port)
        XCTAssertEqual(row["program"] as? String, "nc")
        XCTAssertEqual(row["addresses"] as? [String], ["127.0.0.1"])
        XCTAssertEqual(row["http"] as? Bool, false, "nc accepts and answers nothing")
        let link = try XCTUnwrap(row["session"] as? [String: Any])
        XCTAssertEqual(link["id"] as? String, id.uuidString)
        XCTAssertEqual(link["name"] as? String, "db")
        XCTAssertNil(link["through"], "the shell's own child")
        XCTAssertNil(row["launcher"])
        XCTAssertEqual(row["cwd"] as? String, PtySession.currentDirectory(ofPID: session.pid))
        let pid = try XCTUnwrap(row["pid"] as? Int)
        listeners.append(pid_t(pid))
        XCTAssertNotNil(ProcessTable.read().table?.processes[pid_t(pid)]?.tty, "it holds the pane's terminal")
        let startedAt = try XCTUnwrap(row["startedAt"] as? Double)
        XCTAssertEqual(startedAt / 1000, Date().timeIntervalSince1970, accuracy: 60)
    }

    /// `perl` forks, the child leaves the terminal with `setsid` and execs
    /// `nc`; the parent waits, so the chain is nc → perl → the shell.
    func testAListenerThatLeftTheTerminalIsThePanesByItsParentChain() async throws {
        let (id, session) = try await makeSession()
        let port = try freePort()
        let script = "use POSIX; my $p = fork; if ($p) { waitpid $p, 0; exit } POSIX::setsid(); exec @ARGV"
        try session.write(Data("perl -e '\(script)' nc -k -l 127.0.0.1 \(port) </dev/null &\n".utf8))
        let row = try self.row(onPort: port)
        XCTAssertEqual(row["program"] as? String, "nc")
        let link = try XCTUnwrap(row["session"] as? [String: Any])
        XCTAssertEqual(link["id"] as? String, id.uuidString)
        XCTAssertEqual(link["through"] as? String, "perl")
        let pid = try XCTUnwrap(row["pid"] as? Int)
        listeners.append(pid_t(pid))
        XCTAssertNil(ProcessTable.read().table?.processes[pid_t(pid)]?.tty, "setsid took its terminal away")
    }

    func testAListenerOutsideKittermNamesItsParentAndAnswersHTTP() throws {
        let row = try self.row(onPort: port)
        XCTAssertEqual(row["pid"] as? Int, Int(getpid()))
        XCTAssertNil(row["session"])
        XCTAssertEqual(row["http"] as? Bool, true, "the test's own HTTP server answers the probe")
        XCTAssertEqual(row["addresses"] as? [String], ["127.0.0.1"])
        XCTAssertNotNil(row["program"])
        // Chartered in round 3 of `running-servers` (the human's correction:
        // the environment is the first join rule): a test process started
        // from a kitterm pane carries that pane's `KITTERM_SESSION_ID`, which
        // this test's own registry does not hold, so its row is a pane that
        // ended, not a server outside kitterm. It read the two assertions
        // of the `else` branch unconditionally before.
        if let exported = ProcessInfo.processInfo.environment[ProcessTable.sessionVariable] {
            XCTAssertEqual(row["endedSession"] as? String, exported)
            XCTAssertNil(row["launcher"])
        } else if getppid() > 1 {
            XCTAssertEqual(row["parent"] as? String, PtySession.invocationName(ofPID: getppid()))
            XCTAssertNotNil(row["launcher"])
        }
        let answer = try read()
        XCTAssertEqual(answer.json["supported"] as? Bool, true)
        XCTAssertNil(answer.json["reason"])
        XCTAssertNotNil(answer.json["readAt"])
        XCTAssertNotNil(answer.json["ageSeconds"])
    }
    #endif

    // MARK: - the body

    private func fakeTable() -> ProcessTable {
        ProcessTable(
            processes: [
                1: .init(pid: 1, ppid: 0, uid: 0, tty: nil),
                70: .init(pid: 70, ppid: 1, uid: 501, tty: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ],
            listeners: [.init(pid: 70, port: 6379, address: "127.0.0.1")],
            name: { $0 == 70 ? "redis-server" : nil }, cwd: { _ in "/" })
    }

    func testTheFirstAnswerIsTheEmptyCacheAndAnUnchangedBodyAnswers304() throws {
        let table = fakeTable()
        let fake = try makeServer(
            cache: ListeningServers(
                excludedPids: [], readTable: { (table, nil) }, probe: { _, _ in false },
                resolveProject: { _ in nil }, refreshSeconds: 0))
        extraChannels.append(fake)
        let port = fake.localAddress!.port!
        let first = try get("/api/servers", port: port)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.json["ok"] as? Bool, true)
        XCTAssertEqual(first.json["supported"] as? Bool, true)
        XCTAssertEqual(first.json["reason"] as? String, "not read yet")
        XCTAssertEqual(first.servers.count, 0)
        XCTAssertNil(first.json["readAt"])
        ListeningServers.queue.sync {}
        let second = try get("/api/servers", port: port)
        XCTAssertEqual(second.headers["content-type"], "application/json")
        XCTAssertNil(second.json["reason"])
        XCTAssertEqual(second.servers.count, 1)
        XCTAssertEqual(second.servers[0]["startedAt"] as? Int64, 1_700_000_000_000)
        XCTAssertEqual(second.servers[0]["http"] as? Bool, false)
        XCTAssertNil(second.servers[0]["launcher"])
        let etag = try XCTUnwrap(second.headers["etag"])
        ListeningServers.queue.sync {}
        let third = try get("/api/servers", port: port, extra: ["If-None-Match: \(etag)"])
        XCTAssertEqual(third.status, 304, "readAt and ageSeconds moved; the rows did not")
        XCTAssertEqual(third.body.count, 0)
    }

    func testAPlatformWithNoReaderSaysSo() throws {
        let fake = try makeServer(
            cache: ListeningServers(
                readTable: { (nil, ProcessTable.linuxReason) }, probe: { _, _ in false },
                resolveProject: { _ in nil }, refreshSeconds: 0))
        extraChannels.append(fake)
        let port = fake.localAddress!.port!
        _ = try get("/api/servers", port: port)
        ListeningServers.queue.sync {}
        let answer = try get("/api/servers", port: port)
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.json["supported"] as? Bool, false)
        XCTAssertEqual(answer.json["reason"] as? String, "reading /proc is not implemented on Linux")
        XCTAssertEqual(answer.servers.count, 0)
    }

    // MARK: - the grade

    func testWatchGradeIs403AndAHandlerWithNoCacheIs503() throws {
        let watch = try get("/api/servers?token=\(Self.watch)", host: Self.trustedHost)
        XCTAssertEqual(watch.status, 403)
        XCTAssertEqual(watch.json["error"] as? String, "watch-only token")
        let none = try get("/api/servers", host: Self.trustedHost)
        XCTAssertEqual(none.status, 403)
        let full = try get("/api/servers?token=\(Self.full)", host: Self.trustedHost)
        XCTAssertEqual(full.status, 200)

        let bare = try makeServer(cache: nil)
        extraChannels.append(bare)
        let answer = try get("/api/servers", port: bare.localAddress!.port!)
        XCTAssertEqual(answer.status, 503)
        XCTAssertEqual(answer.json["error"] as? String, "servers unavailable")
    }
}
