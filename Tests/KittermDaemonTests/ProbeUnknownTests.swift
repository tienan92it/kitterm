import Foundation
import NIOConcurrencyHelpers
import XCTest

@testable import KittermDaemon

/// The probe's third value (`running-servers` round 3, the gap of round
/// 1): a timeout is unknown, not a no. `ListeningServers` then leaves
/// `http` absent and asks again after `reprobeSeconds` whatever the
/// process's age, and keeps the yes or the no the next probe gives. No
/// kernel read and no socket: the probe is a fake the test scripts.
final class ProbeUnknownTests: XCTestCase {
    /// The verdicts a fake probe gives per port, in order; the last one
    /// repeats. Every call is recorded.
    private final class ScriptedProbe: @unchecked Sendable {
        private let lock = NIOLock()
        private var script: [Int: [Bool?]]
        private(set) var calls: [String] = []
        init(_ script: [Int: [Bool?]]) { self.script = script }
        func answer(_ host: String, _ port: Int) -> Bool? {
            lock.withLock {
                calls.append("\(host):\(port)")
                guard var answers = script[port], let first = answers.first else { return false }
                if answers.count > 1 { answers.removeFirst() }
                script[port] = answers
                return first
            }
        }
        func count(of port: Int) -> Int { lock.withLock { calls.filter { $0.hasSuffix(":\(port)") }.count } }
    }

    /// Two servers outside kitterm, both started an hour ago: `kubectl`
    /// on 3003 (a port-forward whose first answer is slow) and `redis` on
    /// 6379.
    private func table(startedAt: Date) -> ProcessTable {
        let processes: [ProcessTable.Process] = [
            .init(pid: 1, ppid: 0, uid: 0, tty: nil),
            .init(pid: 310, ppid: 1, uid: 501, tty: nil, startedAt: startedAt),
            .init(pid: 500, ppid: 1, uid: 501, tty: nil, startedAt: startedAt),
        ]
        let names: [pid_t: String] = [310: "kubectl", 500: "redis-server"]
        return ProcessTable(
            processes: Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) }),
            listeners: [
                .init(pid: 310, port: 3003, address: "127.0.0.1"),
                .init(pid: 500, port: 6379, address: "127.0.0.1"),
            ],
            name: { names[$0] }, cwd: { _ in "/" }
        )
    }

    private func cache(_ probe: ScriptedProbe, clock: TestClock, table: ProcessTable) -> ListeningServers {
        ListeningServers(
            excludedPids: [], readTable: { (table, nil) }, probe: { probe.answer($0, $1) },
            resolveProject: { _ in nil }, refreshSeconds: 0, clock: { clock.now })
    }

    private func http(_ cache: ListeningServers) -> [Int: Bool?] {
        Dictionary(uniqueKeysWithValues: cache.snapshot().servers.map { ($0.port, $0.http) })
    }

    func testATimeoutIsUnknownAndAskedAgainAfterAMinuteWhateverTheAge() {
        let clock = TestClock()
        let table = table(startedAt: clock.now.addingTimeInterval(-3600))
        // kubectl: a timeout, then a timeout, then HTTP. redis: a no at once.
        let probe = ScriptedProbe([3003: [nil, nil, true], 6379: [false]])
        let cache = cache(probe, clock: clock, table: table)

        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        XCTAssertEqual(http(cache)[3003], .some(nil), "a timeout leaves http absent, not false")
        XCTAssertEqual(http(cache)[6379], .some(false))
        XCTAssertEqual(probe.calls, ["127.0.0.1:3003", "127.0.0.1:6379"])

        clock.advance(10)
        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        XCTAssertEqual(probe.count(of: 3003), 1, "an unknown is kept inside the minute")

        clock.advance(ListeningServers.reprobeSeconds)
        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        XCTAssertEqual(probe.count(of: 3003), 2, "an unknown is asked again after a minute, though the process is an hour old")
        XCTAssertEqual(probe.count(of: 6379), 1, "an old no is final")
        XCTAssertEqual(http(cache)[3003], .some(nil))

        clock.advance(ListeningServers.reprobeSeconds)
        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        XCTAssertEqual(probe.count(of: 3003), 3)
        XCTAssertEqual(http(cache)[3003], .some(true), "the yes lands once the server answers")

        clock.advance(ListeningServers.reprobeSeconds)
        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        XCTAssertEqual(probe.count(of: 3003), 3, "a yes is final")
        XCTAssertEqual(http(cache)[3003], .some(true))
    }

    func testAnUnknownThatBecomesANoFollowsTheNoRule() {
        let clock = TestClock()
        let table = table(startedAt: clock.now.addingTimeInterval(-3600))
        let probe = ScriptedProbe([3003: [nil, false], 6379: [false]])
        let cache = cache(probe, clock: clock, table: table)
        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        clock.advance(ListeningServers.reprobeSeconds)
        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        XCTAssertEqual(http(cache)[3003], .some(false))
        clock.advance(ListeningServers.reprobeSeconds)
        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        XCTAssertEqual(probe.count(of: 3003), 2, "the no of an old process is final, as in round 1")
    }

    func testTheRouteOmitsHTTPForAnUnknownVerdict() {
        let clock = TestClock()
        let table = table(startedAt: clock.now)
        let cache = cache(ScriptedProbe([3003: [nil], 6379: [false]]), clock: clock, table: table)
        cache.refreshIfDue(links: [])
        ListeningServers.queue.sync {}
        let rows = cache.snapshot().servers.map(\.json)
        XCTAssertNil(rows[0]["http"], "kubectl: no verdict, no key")
        XCTAssertEqual(rows[1]["http"] as? Bool, false)
    }
}
