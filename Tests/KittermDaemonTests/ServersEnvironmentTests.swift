import Foundation
import XCTest

@testable import KittermDaemon

/// The first join rule of `GET /api/servers` (`running-servers` round 3):
/// the `KITTERM_SESSION_ID` a server carries in its environment. The pane's
/// shell exported it, and a server keeps it after it leaves the terminal
/// (setsid) and after its starter exits (reparented to launchd), where the
/// tty and the parent chain say nothing. An id that names a live session
/// links that session; one that names none is `endedSession`. No kernel
/// read: the table is a fake with an environment.
final class ServersEnvironmentTests: XCTestCase {
    private let paneA = ListeningServers.ShellLink(id: UUID(), name: "db", pid: 100)
    private let paneB = ListeningServers.ShellLink(id: UUID(), name: "foreman", pid: 110)
    private let gone = UUID()

    /// launchd (1); the daemon (50) with panes A (100, tty 5) and B (110,
    /// tty 6). Under launchd, with no tty: `kubectl` (310) under Claude
    /// Code's detached `claude bg-pty-host` (300), both carrying B's id;
    /// `postgres` (200) carrying A's id; `python` (210) carrying an id no
    /// live session has; `node` (320) with no id under `claude` (330) under
    /// B's shell, the chain rule; `next-server` (440) under Terminal (400)
    /// with no id, outside kitterm.
    private func table() -> ProcessTable {
        let processes: [ProcessTable.Process] = [
            .init(pid: 1, ppid: 0, uid: 0, tty: nil),
            .init(pid: 50, ppid: 1, uid: 501, tty: nil),
            .init(pid: 100, ppid: 50, uid: 501, tty: 5),
            .init(pid: 110, ppid: 50, uid: 501, tty: 6),
            .init(pid: 200, ppid: 1, uid: 501, tty: nil),
            .init(pid: 210, ppid: 1, uid: 501, tty: nil),
            .init(pid: 300, ppid: 1, uid: 501, tty: nil),
            .init(pid: 310, ppid: 300, uid: 501, tty: nil),
            .init(pid: 330, ppid: 110, uid: 501, tty: 6),
            .init(pid: 320, ppid: 330, uid: 501, tty: nil),
            .init(pid: 400, ppid: 1, uid: 501, tty: nil),
            .init(pid: 440, ppid: 400, uid: 501, tty: 7),
        ]
        let names: [pid_t: String] = [
            50: "kitterm", 100: "zsh", 110: "zsh", 200: "postgres", 210: "python", 300: "claude bg-pty-host",
            310: "kubectl", 320: "node", 330: "claude", 400: "Terminal", 440: "next-server",
        ]
        let ids: [pid_t: String] = [
            200: paneA.id.uuidString, 210: gone.uuidString, 300: paneB.id.uuidString, 310: paneB.id.uuidString,
            100: paneA.id.uuidString, 110: paneB.id.uuidString,
        ]
        return ProcessTable(
            processes: Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) }),
            listeners: [
                .init(pid: 200, port: 5432, address: "127.0.0.1"),
                .init(pid: 210, port: 8010, address: "0.0.0.0"),
                .init(pid: 310, port: 3003, address: "127.0.0.1"),
                .init(pid: 320, port: 4000, address: "127.0.0.1"),
                .init(pid: 440, port: 3000, address: "::"),
            ],
            name: { names[$0] }, cwd: { _ in "/Users/me" }, sessionID: { ids[$0] }
        )
    }

    private func rows() -> [ListeningServers.Server] {
        ListeningServers.servers(table: table(), links: [paneA, paneB], excludedPids: [50], resolveProject: { _ in nil })
    }

    private func row(_ port: Int) -> ListeningServers.Server {
        rows().first { $0.port == port }!
    }

    func testAServerWithNoTtyAndNoChainIsThePanesByTheIdItCarries() {
        let postgres = row(5432)
        XCTAssertEqual(postgres.session, .init(id: paneA.id, name: "db", through: nil), "under launchd itself: no program between")
        XCTAssertNil(postgres.endedSession)
        XCTAssertNil(postgres.launcher)
        XCTAssertNil(postgres.parent)
    }

    func testAServerUnderADetachedHostNamesTheHostsFirstWordAsThrough() {
        let kubectl = row(3003)
        XCTAssertEqual(kubectl.session, .init(id: paneB.id, name: "foreman", through: "claude"),
                       "the top program below launchd that is not the server, by its first word: `claude in foreman`")
    }

    func testAnIdThatNamesNoLiveSessionIsAnEndedSession() {
        let python = row(8010)
        XCTAssertNil(python.session)
        XCTAssertEqual(python.endedSession, gone)
        XCTAssertNil(python.launcher, "an ended pane's server is not outside kitterm")
        XCTAssertNil(python.parent)
        XCTAssertEqual(python.json["endedSession"] as? String, gone.uuidString)
        XCTAssertNil(python.json["session"])
    }

    func testTheEnvironmentWinsOverTheTtyAndTheChain() {
        var mutable = table()
        // postgres also holds pane B's tty; the id it carries is pane A's.
        mutable.processes[200]?.tty = 6
        let rows = ListeningServers.servers(table: mutable, links: [paneA, paneB], excludedPids: [50], resolveProject: { _ in nil })
        XCTAssertEqual(rows.first { $0.port == 5432 }?.session?.id, paneA.id)
    }

    func testTheOtherRulesStillApplyWithNoId() {
        XCTAssertEqual(row(4000).session, .init(id: paneB.id, name: "foreman", through: "claude"), "the chain, as in round 1")
        let next = row(3000)
        XCTAssertNil(next.session)
        XCTAssertNil(next.endedSession)
        XCTAssertEqual(next.launcher, "Terminal")
    }

    func testAMalformedIdIsNoId() {
        var mutable = table()
        mutable.sessionID = { $0 == 200 ? "not-a-uuid" : nil }
        let rows = ListeningServers.servers(table: mutable, links: [paneA, paneB], excludedPids: [50], resolveProject: { _ in nil })
        let postgres = rows.first { $0.port == 5432 }!
        XCTAssertNil(postgres.session)
        XCTAssertNil(postgres.endedSession)
    }

    func testTheFirstWord() {
        XCTAssertEqual(ListeningServers.firstWord("claude bg-pty-host"), "claude")
        XCTAssertEqual(ListeningServers.firstWord("perl"), "perl")
        XCTAssertNil(ListeningServers.firstWord(""))
    }

    func testTheEnvironmentOfThisProcessIsRead() {
        // The reader against the real kernel, on the test's own pid.
        setenv("KITTERM_ENV_PROBE", "it-reads", 1)
        defer { unsetenv("KITTERM_ENV_PROBE") }
        XCTAssertEqual(PtySession.environmentValue(ofPID: getpid(), name: "KITTERM_ENV_PROBE"), nil,
                       "the kernel holds the environment the process was started with, not a later setenv")
        XCTAssertNotNil(PtySession.environmentValue(ofPID: getpid(), name: "PATH"))
        XCTAssertNil(PtySession.environmentValue(ofPID: getpid(), name: "KITTERM_NO_SUCH_VARIABLE_X"))
        XCTAssertNil(PtySession.environmentValue(ofPID: 1, name: "PATH"), "another user's process")
    }
}
