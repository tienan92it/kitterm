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

/// `GET /api/servers` against the real kernel, loop and registry, for the
/// environment rule (`running-servers` round 3): a listener a pane started
/// whose starter exited and that left the terminal with `setsid`, so the
/// tty is gone and the parent chain ends at launchd, is still the pane's,
/// by the `KITTERM_SESSION_ID` the pane's shell exported; once the pane is
/// gone the row carries `endedSession`. The listener is a two-dozen-line C
/// program built with `cc` in `setUp`, because the kernel withholds the
/// environment of an Apple platform binary (`/usr/bin/nc`, `/bin/sleep`)
/// from every other process, and shows a binary built here (measured
/// 2026-10-13 on macOS 26.6.2 with `ps -wwE`). It forks, the parent exits,
/// the child calls `setsid`, binds `127.0.0.1:0`, writes its port to the
/// file named in `argv[1]` and pauses; `SIGKILL` ends it in `tearDown`
/// (`facts.md`, Crew pane). The tests skip when `cc` is absent.
final class ServersEnvironmentRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var cache: ListeningServers!
    private var sessions: [PtySession] = []
    private var port: Int!
    private var listeners: [pid_t] = []

    private static let full = String(repeating: "f", count: 32)
    /// The built listener, or the reason it could not be built.
    nonisolated(unsafe) private static var listener: Result<String, Error> = .failure(NotBuilt(reason: "setUp did not run"))
    private struct NotBuilt: Error { var reason: String }

    private static let source = """
    #include <arpa/inet.h>
    #include <netinet/in.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <sys/socket.h>
    #include <unistd.h>
    int main(int argc, char **argv) {
        if (argc < 2) return 2;
        if (fork() > 0) return 0;
        setsid();
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a;
        memset(&a, 0, sizeof a);
        a.sin_family = AF_INET;
        a.sin_port = 0;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) return 3;
        if (listen(fd, 1) != 0) return 4;
        socklen_t len = sizeof a;
        getsockname(fd, (struct sockaddr *)&a, &len);
        FILE *out = fopen(argv[1], "w");
        if (!out) return 5;
        fprintf(out, "%d\\n", ntohs(a.sin_port));
        fclose(out);
        for (;;) pause();
    }
    """

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: ServersEnvironmentRouteTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
        listener = Result { try build() }
    }

    /// `cc` the listener into a scratch directory; throws with the reason
    /// when `cc` is absent or fails.
    private static func build() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kt-listener-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sourcePath = dir.appendingPathComponent("kt-listener.c").path
        let binary = dir.appendingPathComponent("kt-listener").path
        try ("#include <string.h>\n" + source).write(toFile: sourcePath, atomically: true, encoding: .utf8)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/cc") else { throw NotBuilt(reason: "no /usr/bin/cc") }
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-o", binary, sourcePath]
        let errors = Pipe()
        cc.standardError = errors
        cc.standardOutput = FileHandle.nullDevice
        try cc.run()
        cc.waitUntilExit()
        guard cc.terminationStatus == 0 else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NotBuilt(reason: "cc exited \(cc.terminationStatus): \(text.split(separator: "\n").first ?? "")")
        }
        return binary
    }

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        registry = SessionRegistry()
        let registry = self.registry!
        cache = ListeningServers(excludedPids: [], refreshSeconds: 0)
        let cache = self.cache!
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
                            policy: .proxied(token: Self.full, watchToken: nil, trustedHosts: []),
                            agentControl: false,
                            staticRoot: nil,
                            listeningServers: cache
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
        sessions = []
        for pid in listeners { kill(pid, SIGKILL) }
        listeners = []
        ListeningServers.queue.sync {}
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    /// `GET /api/servers` over a raw socket, parsed.
    private func get() throws -> [String: Any] {
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
        let request = Data("GET /api/servers HTTP/1.1\r\nHost: 127.0.0.1:\(port!)\r\nConnection: close\r\n\r\n".utf8)
        request.withUnsafeBytes { XCTAssertEqual(send(fd, $0.baseAddress, $0.count, 0), request.count) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        guard let split = received.range(of: Data("\r\n\r\n".utf8)) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: received[split.upperBound...]) as? [String: Any]) ?? [:]
    }

    /// A read, then the answer it produced; until a row on `port` is in it.
    private func row(onPort port: Int, seconds: Double = 20) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = try get()
            ListeningServers.queue.sync {}
            let servers = try get()["servers"] as? [[String: Any]] ?? []
            if let row = servers.first(where: { $0["port"] as? Int == port }) { return row }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("no row on port \(port) within \(seconds) s")
        return [:]
    }

    /// A pane, named, with the reader that flushes its input.
    private func makeSession(named name: String) async throws -> (UUID, PtySession) {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse(nil))
        sessions.append(session)
        try await session.makeReader(group: group, eventLoop: group.next()).get()
        let registered = await registry.register(session)
        let id = try XCTUnwrap(registered, "registry refused the session")
        session.setName(name)
        return (id, session)
    }

    /// Start the listener from the pane; its port, from the file it writes.
    private func startListener(in session: PtySession) throws -> Int {
        let binary = try Self.listener.get()
        let portFile = NSTemporaryDirectory() + "kt-listener-port-\(getpid())-\(UUID().uuidString)"
        try session.write(Data("'\(binary)' '\(portFile)' </dev/null\n".utf8))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: portFile, encoding: .utf8), let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                try? FileManager.default.removeItem(atPath: portFile)
                return port
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NotBuilt(reason: "the listener wrote no port within 20 s")
    }

    private func skipUnlessBuilt() throws {
        if case .failure(let error) = Self.listener {
            throw XCTSkip("the environment rule needs a listener that is no platform binary, and cc did not build one: \((error as? NotBuilt)?.reason ?? "\(error)")")
        }
    }

    #if canImport(Darwin)
    func testAListenerWhoseStarterExitedAndThatLeftTheTerminalIsThePanesByItsEnvironment() async throws {
        try skipUnlessBuilt()
        let (id, session) = try await makeSession(named: "api")
        let port = try startListener(in: session)
        let row = try self.row(onPort: port)
        XCTAssertEqual(row["program"] as? String, "kt-listener")
        let pid = try XCTUnwrap(row["pid"] as? Int)
        listeners.append(pid_t(pid))
        let process = ProcessTable.read().table?.processes[pid_t(pid)]
        XCTAssertNil(process?.tty, "setsid took its terminal away")
        XCTAssertEqual(process?.ppid, 1, "its starter exited, so launchd holds it")
        XCTAssertEqual(PtySession.environmentValue(ofPID: pid_t(pid), name: ProcessTable.sessionVariable), id.uuidString,
                       "the pane's id survives in its environment")
        let link = try XCTUnwrap(row["session"] as? [String: Any], "joined by the environment")
        XCTAssertEqual(link["id"] as? String, id.uuidString)
        XCTAssertEqual(link["name"] as? String, "api")
        XCTAssertNil(link["through"], "under launchd itself: no program between")
        XCTAssertNil(row["endedSession"])
        XCTAssertNil(row["launcher"])
        XCTAssertNil(row["parent"])
    }

    /// The same listener once its pane is gone: the id names no live
    /// session, so the row carries `endedSession` and no `session`.
    func testAListenerWhosePaneEndedCarriesEndedSession() async throws {
        try skipUnlessBuilt()
        let (id, session) = try await makeSession(named: "api")
        let port = try startListener(in: session)
        let first = try self.row(onPort: port)
        listeners.append(pid_t(try XCTUnwrap(first["pid"] as? Int)))
        XCTAssertEqual((first["session"] as? [String: Any])?["id"] as? String, id.uuidString)
        // End the pane; the listener outlives it.
        await registry.remove(id)
        session.terminate()
        sessions = []
        let deadline = Date().addingTimeInterval(20)
        var row = first
        while Date() < deadline, row["session"] != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            row = try self.row(onPort: port)
        }
        XCTAssertNil(row["session"])
        XCTAssertEqual(row["endedSession"] as? String, id.uuidString)
        XCTAssertNil(row["launcher"])
        XCTAssertNil(row["parent"])
    }
    #endif
}
