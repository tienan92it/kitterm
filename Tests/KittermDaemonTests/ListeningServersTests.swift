#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers
import XCTest

@testable import KittermDaemon

/// `ListeningServers` on a table a test made: the join by tty, the join by
/// parent chain with the program between, the launcher outside kitterm,
/// the daemon's own pid left out, one row per pid and port, the probe
/// cache, and the Linux answer. No kernel read and no socket.
final class ListeningServersTests: XCTestCase {
    private let paneA = ListeningServers.ShellLink(id: UUID(), name: "db", pid: 100)
    private let paneB = ListeningServers.ShellLink(id: UUID(), name: nil, pid: 110)
    private let started = Date(timeIntervalSince1970: 1_760_000_000.25)

    /// launchd (1); the daemon (50) with two panes, A (100, tty 5) and B
    /// (110, tty 6); under A nothing, but `postgres` (200) keeps tty 5 after
    /// `pg_ctl` exited and launchd adopted it; under B `claude` (300) runs
    /// `kubectl` (310, no tty, it called setsid) and `node` (320, tty 6);
    /// outside, Terminal (400) → login (410) → zsh (420) → node (430) →
    /// next-server (440); redis (500) under launchd; the daemon itself
    /// listens on 3418 (50) and is excluded.
    private func table() -> ProcessTable {
        let processes: [ProcessTable.Process] = [
            .init(pid: 1, ppid: 0, uid: 0, tty: nil),
            .init(pid: 50, ppid: 1, uid: 501, tty: nil),
            .init(pid: 100, ppid: 50, uid: 501, tty: 5),
            .init(pid: 110, ppid: 50, uid: 501, tty: 6),
            .init(pid: 200, ppid: 1, uid: 501, tty: 5, startedAt: started),
            .init(pid: 300, ppid: 110, uid: 501, tty: 6),
            .init(pid: 310, ppid: 300, uid: 501, tty: nil),
            .init(pid: 320, ppid: 300, uid: 501, tty: 6),
            .init(pid: 400, ppid: 1, uid: 501, tty: nil),
            .init(pid: 410, ppid: 400, uid: 501, tty: 7),
            .init(pid: 420, ppid: 410, uid: 501, tty: 7),
            .init(pid: 430, ppid: 420, uid: 501, tty: 7),
            .init(pid: 440, ppid: 430, uid: 501, tty: 7),
            .init(pid: 500, ppid: 1, uid: 501, tty: nil),
        ]
        let names: [pid_t: String] = [
            50: "kitterm", 100: "zsh", 110: "zsh", 200: "postgres", 300: "claude", 310: "kubectl",
            320: "node", 400: "Terminal", 410: "login", 420: "zsh", 430: "node", 440: "next-server",
            500: "redis-server",
        ]
        let cwds: [pid_t: String] = [
            200: "/Users/me/.pgdata", 310: "/Users/me/Workspace/pipeline", 320: "/Users/me/Workspace/pipeline",
            440: "/Users/me/Workspace/apps/memo", 500: "/",
        ]
        return ProcessTable(
            processes: Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) }),
            listeners: [
                .init(pid: 50, port: 3418, address: "127.0.0.1"),
                .init(pid: 200, port: 5432, address: "127.0.0.1"),
                .init(pid: 310, port: 3003, address: "127.0.0.1"),
                .init(pid: 320, port: 4000, address: "192.168.1.5"),
                .init(pid: 440, port: 3000, address: "::"),
                .init(pid: 440, port: 3000, address: "0.0.0.0"),
                .init(pid: 500, port: 6379, address: "127.0.0.1"),
                .init(pid: 500, port: 6379, address: "::1"),
            ],
            name: { names[$0] }, cwd: { cwds[$0] }
        )
    }

    private func resolve(_ cwd: String) -> ResolvedProject? {
        guard cwd.hasPrefix("/Users/me/Workspace/") else { return nil }
        let name = cwd.split(separator: "/")[3]
        return ResolvedProject(
            id: String(name), name: String(name), root: "/Users/me/Workspace/\(name)", registered: false,
            knowledge: "docs/goals")
    }

    private func rows() -> [ListeningServers.Server] {
        ListeningServers.servers(table: table(), links: [paneA, paneB], excludedPids: [50], resolveProject: resolve)
    }

    func testOneRowPerPidAndPortByPortWithTheAddressesMergedAndTheDaemonLeftOut() {
        let rows = rows()
        XCTAssertEqual(rows.map(\.port), [3000, 3003, 4000, 5432, 6379])
        XCTAssertEqual(rows[0].addresses, ["0.0.0.0", "::"])
        XCTAssertEqual(rows[4].addresses, ["127.0.0.1", "::1"])
        XCTAssertEqual(rows.map(\.program), ["next-server", "kubectl", "node", "postgres", "redis-server"])
        XCTAssertEqual(rows[3].startedAt, started)
        XCTAssertNil(rows[0].http, "no probe ran")
    }

    func testAServerThatKeepsThePanesTtyIsThePanesEvenAfterLaunchdAdoptedIt() {
        let postgres = rows()[3]
        XCTAssertEqual(postgres.session, .init(id: paneA.id, name: "db", through: nil))
        XCTAssertNil(postgres.launcher)
        XCTAssertNil(postgres.parent)
        XCTAssertNil(postgres.project)
        XCTAssertEqual(postgres.cwd, "/Users/me/.pgdata")
    }

    func testAServerWithNoTtyIsJoinedByItsParentChainThroughTheProgramUnderTheShell() {
        let kubectl = rows()[1]
        XCTAssertEqual(kubectl.session, .init(id: paneB.id, name: nil, through: "claude"))
        XCTAssertEqual(kubectl.project?.id, "pipeline")
    }

    func testAServerWithThePanesTtyUnderAProgramNamesThatProgramToo() {
        let node = rows()[2]
        XCTAssertEqual(node.session, .init(id: paneB.id, name: nil, through: "claude"))
    }

    func testAServerOutsideKittermNamesTheTopLauncherBelowLaunchdAndItsParent() {
        let next = rows()[0]
        XCTAssertNil(next.session)
        XCTAssertEqual(next.launcher, "Terminal")
        XCTAssertEqual(next.parent, "node")
        XCTAssertEqual(next.project?.id, "apps")
        let redis = rows()[4]
        XCTAssertNil(redis.session)
        XCTAssertNil(redis.launcher, "launchd started it")
        XCTAssertNil(redis.parent)
    }

    func testTheAncestryIsBounded() {
        var processes: [pid_t: ProcessTable.Process] = [:]
        for pid in pid_t(2)...pid_t(80) { processes[pid] = .init(pid: pid, ppid: pid - 1, uid: 501, tty: nil) }
        let table = ProcessTable(processes: processes, listeners: [], name: { _ in nil }, cwd: { _ in nil })
        XCTAssertEqual(ListeningServers.ancestry(of: 80, in: table).count, ListeningServers.maxChain)
        processes[3]?.ppid = 5
        let loop = ProcessTable(processes: processes, listeners: [], name: { _ in nil }, cwd: { _ in nil })
        XCTAssertEqual(ListeningServers.ancestry(of: 5, in: loop), [5, 4, 3], "a cycle ends the walk")

    }

    func testTheJSONRow() throws {
        let next = rows()[0]
        let json = next.json
        XCTAssertEqual(json["port"] as? Int, 3000)
        XCTAssertEqual(json["addresses"] as? [String], ["0.0.0.0", "::"])
        XCTAssertEqual(json["pid"] as? Int, 440)
        XCTAssertEqual(json["program"] as? String, "next-server")
        XCTAssertEqual(json["launcher"] as? String, "Terminal")
        XCTAssertEqual(json["parent"] as? String, "node")
        XCTAssertEqual((json["project"] as? [String: Any])?["id"] as? String, "apps")
        XCTAssertNil(json["session"])
        XCTAssertNil(json["http"])
        XCTAssertNil(json["startedAt"])
        let postgres = rows()[3].json
        XCTAssertEqual(postgres["startedAt"] as? Int64, 1_760_000_000_250)
        let session = try XCTUnwrap(postgres["session"] as? [String: Any])
        XCTAssertEqual(session["id"] as? String, paneA.id.uuidString)
        XCTAssertEqual(session["name"] as? String, "db")
        XCTAssertNil(session["through"])
    }

    // MARK: - the cache

    private final class Probes: @unchecked Sendable {
        private let lock = NIOLock()
        private var calls: [String] = []
        func record(_ host: String, _ port: Int) -> Bool {
            lock.withLock { calls.append("\(host):\(port)") }
            return port == 3000 || port == 3003
        }
        var all: [String] { lock.withLock { calls.sorted() } }
    }

    func testTheProbeAsksLoopbackOncePerPidAndPortAndAsksANegativeAgainAfterAMinute() {
        let probes = Probes()
        let clock = TestClock()
        let table = table()
        let cache = ListeningServers(
            excludedPids: [50], readTable: { (table, nil) }, probe: { probes.record($0, $1) },
            resolveProject: { _ in nil }, refreshSeconds: 0, clock: { clock.now })
        XCTAssertEqual(cache.snapshot().reason, "not read yet")
        XCTAssertTrue(cache.refreshIfDue(links: [paneA, paneB]))
        XCTAssertFalse(cache.refreshIfDue(links: []), "one read at a time")
        ListeningServers.queue.sync {}
        let first = cache.snapshot()
        XCTAssertTrue(first.supported)
        XCTAssertNil(first.reason)
        XCTAssertEqual(first.readAt, clock.now)
        XCTAssertEqual(first.servers.map(\.http), [true, true, nil, false, false])
        XCTAssertEqual(probes.all, ["127.0.0.1:3000", "127.0.0.1:3003", "127.0.0.1:5432", "127.0.0.1:6379"],
                       "the v4 loopback is asked where it is bound; 192.168.1.5 is never asked")

        clock.advance(10)
        XCTAssertTrue(cache.refreshIfDue(links: [paneA, paneB]))
        ListeningServers.queue.sync {}
        XCTAssertEqual(probes.all.count, 4, "every verdict is cached inside the minute")
        XCTAssertEqual(cache.snapshot().servers.map(\.http), [true, true, nil, false, false])

        clock.advance(ListeningServers.reprobeSeconds)
        XCTAssertTrue(cache.refreshIfDue(links: [paneA, paneB]))
        ListeningServers.queue.sync {}
        XCTAssertEqual(probes.all.count, 6, "the two negatives are asked again, the positives are kept")
    }

    func testTheRefreshBoundHolds() {
        let clock = TestClock()
        let table = table()
        let cache = ListeningServers(
            excludedPids: [50], readTable: { (table, nil) }, probe: { _, _ in false },
            resolveProject: { _ in nil }, refreshSeconds: 3, clock: { clock.now })
        XCTAssertTrue(cache.refreshIfDue(links: []))
        ListeningServers.queue.sync {}
        clock.advance(2)
        XCTAssertFalse(cache.refreshIfDue(links: []))
        clock.advance(1)
        XCTAssertTrue(cache.refreshIfDue(links: []))
        ListeningServers.queue.sync {}
    }

    func testAPlatformWithNoReaderAnswersUnsupportedWithTheReason() {
        let cache = ListeningServers(
            readTable: { (nil, ProcessTable.linuxReason) }, probe: { _, _ in false },
            resolveProject: { _ in nil }, refreshSeconds: 0)
        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        let snapshot = cache.snapshot()
        XCTAssertFalse(snapshot.supported)
        XCTAssertEqual(snapshot.reason, "reading /proc is not implemented on Linux")
        XCTAssertEqual(snapshot.servers, [])
        XCTAssertNil(snapshot.readAt)
    }

    func testTheLoopbackTarget() {
        XCTAssertEqual(HTTPProbe.loopbackTarget(for: "0.0.0.0"), "127.0.0.1")
        XCTAssertEqual(HTTPProbe.loopbackTarget(for: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(HTTPProbe.loopbackTarget(for: "127.0.0.2"), "127.0.0.2")
        XCTAssertEqual(HTTPProbe.loopbackTarget(for: "::"), "::1")
        XCTAssertEqual(HTTPProbe.loopbackTarget(for: "::1"), "::1")
        XCTAssertNil(HTTPProbe.loopbackTarget(for: "192.168.1.5"))
        XCTAssertNil(HTTPProbe.loopbackTarget(for: "fe80::1"))
    }
}
