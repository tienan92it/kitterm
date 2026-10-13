#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers

/// The listening servers of the user's processes, who started each and the
/// project its cwd resolves to, behind `GET /api/servers` (`running-servers`
/// round 1). The kernel is read by `ProcessTable`, the HTTP verdict by
/// `HTTPProbe`, both on `queue`, never on the event loop.
///
/// A request reads `snapshot` under the lock and calls `refreshIfDue`, which
/// starts one read when none runs and the last one ended `refreshSeconds`
/// ago or more; no request waits for the kernel or a probe. A listener is
/// joined to a session first by the `KITTERM_SESSION_ID` in its environment
/// (round 3: the pane's shell exported it and a server keeps it after it
/// leaves the terminal and its starter exits; an id that names no live
/// session is `endedSession`), else by its controlling tty against the
/// session's shell, else by its parent chain to a session's shell pid, else
/// it is outside kitterm with the top launcher below launchd. The kernel
/// withholds the environment of an Apple platform binary (`/usr/bin/nc`,
/// `/bin/sleep`, `postgres` from the system) from every other process and
/// shows that of a binary built or installed by the user (measured
/// 2026-10-13 with `ps -wwE` on macOS 26.6.2), so the tty and the chain
/// rules are the fallback for a platform binary. The probe's verdict
/// is cached per pid and port: a server that answers HTTP keeps the verdict
/// while it is listed; a server that does not is asked again after
/// `reprobeSeconds` only while its process is younger than
/// `youngProcessSeconds`, because a server still starting accepts before it
/// answers, and after that the verdict is final while the pid and port are
/// listed, because a postgres or a redis asked every minute writes a
/// protocol error to its own log for each request. A verdict the probe
/// could not reach (`nil`: a timeout, a connect that never completed;
/// round 3) leaves `http` absent and is asked again after `reprobeSeconds`
/// whatever the process's age: a server that was slow once is not text for
/// the life of its process.
public final class ListeningServers: @unchecked Sendable {
    public static let refreshSeconds: TimeInterval = 3
    public static let reprobeSeconds: TimeInterval = 60
    /// How long after its start a process that did not answer HTTP is
    /// asked again; a process with no start time is never asked again.
    public static let youngProcessSeconds: TimeInterval = 300
    /// The most parents walked from a server to a session's shell or to
    /// launchd.
    public static let maxChain = 32
    public static let notReadReason = "not read yet"
    static let queue = DispatchQueue(label: "kitterm.servers", qos: .utility)

    /// A live session's shell, as the registry hands it to the route.
    public struct ShellLink: Equatable, Sendable {
        public var id: UUID
        public var name: String?
        public var pid: pid_t

        public init(id: UUID, name: String?, pid: pid_t) {
            self.id = id
            self.name = name
            self.pid = pid
        }
    }

    /// The session a server was started from, and the program between the
    /// shell and the server when there is one (`claude`).
    public struct SessionLink: Equatable, Sendable {
        public var id: UUID
        public var name: String?
        public var through: String?
    }

    /// One row of the route.
    public struct Server: Equatable, Sendable {
        public var port: Int
        /// The addresses bound on `port`, sorted; a server bound on IPv4
        /// and IPv6 is one row.
        public var addresses: [String]
        public var pid: pid_t
        public var program: String?
        /// When the process started, from the table; nil when the table
        /// has no time for it.
        public var startedAt: Date?
        public var cwd: String?
        public var project: ResolvedProject?
        /// Set when a session started the server; `launcher` and `parent`
        /// are then nil.
        public var session: SessionLink?
        /// The `KITTERM_SESSION_ID` the server carries when it names no live
        /// session: a pane that ended started it. `session`, `launcher` and
        /// `parent` are then nil.
        public var endedSession: UUID?
        /// The top ancestor below launchd, for a server outside kitterm;
        /// nil when the server is that ancestor itself.
        public var launcher: String?
        /// The parent's name, for a server outside kitterm; nil when the
        /// parent is launchd.
        public var parent: String?
        /// Whether the loopback address answers HTTP; nil for a server
        /// bound to another interface alone, which the probe never asks.
        public var http: Bool?

        var json: [String: Any] {
            var item: [String: Any] = ["port": port, "addresses": addresses, "pid": Int(pid)]
            if let program { item["program"] = program }
            if let startedAt { item["startedAt"] = Int64(startedAt.timeIntervalSince1970 * 1000) }
            if let cwd { item["cwd"] = cwd }
            if let project { item["project"] = project.rowJSON }
            if let session {
                var link: [String: Any] = ["id": session.id.uuidString]
                if let name = session.name { link["name"] = name }
                if let through = session.through { link["through"] = through }
                item["session"] = link
            }
            if let endedSession { item["endedSession"] = endedSession.uuidString }
            if let launcher { item["launcher"] = launcher }
            if let parent { item["parent"] = parent }
            if let http { item["http"] = http }
            return item
        }
    }

    public struct Snapshot: Equatable, Sendable {
        /// True where a reader exists (Darwin); false on Linux, where
        /// `reason` says so and `servers` is empty.
        public var supported = true
        public var servers: [Server] = []
        /// When the table was read; nil before the first read and on a
        /// platform with no reader.
        public var readAt: Date?
        public var reason: String?
    }

    private struct ProbeKey: Hashable {
        var pid: pid_t
        var port: Int
    }

    private struct Probe {
        /// Nil when the probe reached no verdict (a timeout).
        var answers: Bool?
        var at: Date
    }

    private let excludedPids: Set<pid_t>
    private let readTable: @Sendable () -> (table: ProcessTable?, reason: String?)
    private let probe: @Sendable (String, Int) -> Bool?
    private let resolveProject: @Sendable (String) -> ResolvedProject?
    private let refreshSeconds: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NIOLock()
    private var snapshotStorage = Snapshot(reason: ListeningServers.notReadReason)
    private var reading = false
    private var endedAt: Date?
    private var probes: [ProbeKey: Probe] = [:]

    /// `excludedPids` is the daemon's own process by default: its listeners
    /// are not the user's servers. A test hands in a fake table, a fake
    /// probe and a zero refresh.
    public init(
        excludedPids: Set<pid_t> = [getpid()],
        readTable: @escaping @Sendable () -> (table: ProcessTable?, reason: String?) = { ProcessTable.read() },
        probe: @escaping @Sendable (String, Int) -> Bool? = { HTTPProbe.answersHTTP(host: $0, port: $1) },
        resolveProject: @escaping @Sendable (String) -> ResolvedProject? = { ProjectStore.shared.resolve(cwd: $0) },
        refreshSeconds: TimeInterval = ListeningServers.refreshSeconds,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.excludedPids = excludedPids
        self.readTable = readTable
        self.probe = probe
        self.resolveProject = resolveProject
        self.refreshSeconds = refreshSeconds
        self.clock = clock
    }

    /// What the cache holds, under the lock; no read.
    public func snapshot() -> Snapshot {
        lock.withLock { snapshotStorage }
    }

    /// Start a read on `queue` when none runs and the last one ended
    /// `refreshSeconds` ago or more. True when a read started. `links` are
    /// the live sessions' shells the read joins against.
    @discardableResult
    public func refreshIfDue(links: [ShellLink]) -> Bool {
        let now = clock()
        let due: Bool = lock.withLock {
            if reading { return false }
            if let endedAt, now.timeIntervalSince(endedAt) < refreshSeconds { return false }
            reading = true
            return true
        }
        guard due else { return false }
        Self.queue.async { [self] in
            let snapshot = read(links: links)
            let ended = clock()
            lock.withLock {
                snapshotStorage = snapshot
                reading = false
                endedAt = ended
            }
        }
        return true
    }

    private func read(links: [ShellLink]) -> Snapshot {
        let (table, reason) = readTable()
        guard let table else { return Snapshot(supported: false, servers: [], readAt: nil, reason: reason) }
        var servers = Self.servers(
            table: table, links: links, excludedPids: excludedPids, resolveProject: resolveProject
        )
        fillProbes(&servers)
        return Snapshot(servers: servers, readAt: clock(), reason: nil)
    }

    /// The verdicts from the cache, and one concurrent round of probes for
    /// the servers that need one. The cache keeps the listed servers only.
    private func fillProbes(_ servers: inout [Server]) {
        let now = clock()
        struct Pending {
            var index: Int
            var key: ProbeKey
            var host: String
        }
        var pending: [Pending] = []
        var kept: [ProbeKey: Probe] = [:]
        let known = lock.withLock { probes }
        for (index, server) in servers.enumerated() {
            guard let host = server.addresses.lazy.compactMap(HTTPProbe.loopbackTarget(for:)).first else { continue }
            let key = ProbeKey(pid: server.pid, port: server.port)
            if let probe = known[key] {
                let young = server.startedAt.map { now.timeIntervalSince($0) < Self.youngProcessSeconds } ?? false
                let fresh = now.timeIntervalSince(probe.at) < Self.reprobeSeconds
                // A yes is final; a no is final once the process is old; an
                // unknown is kept only inside the minute.
                let final: Bool
                switch probe.answers {
                case .some(true): final = true
                case .some(false): final = !young || fresh
                case .none: final = fresh
                }
                if final {
                    servers[index].http = probe.answers
                    kept[key] = probe
                    continue
                }
            }
            pending.append(Pending(index: index, key: key, host: host))
        }
        // The probes of one read run together, so a read with several new
        // listeners ends within one timeout. The jobs are a constant and the
        // answers land in a locked box: the closure is `@Sendable`.
        let jobs: [(host: String, port: Int)] = pending.map { ($0.host, servers[$0.index].port) }
        let answers = NIOLockedValueBox([Bool?](repeating: nil, count: jobs.count))
        if !jobs.isEmpty {
            let probe = self.probe
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let answer = probe(jobs[i].host, jobs[i].port)
                answers.withLockedValue { $0[i] = answer }
            }
        }
        let verdicts = answers.withLockedValue { $0 }
        for (i, item) in pending.enumerated() {
            servers[item.index].http = verdicts[i]
            kept[item.key] = Probe(answers: verdicts[i], at: now)
        }
        lock.withLock { probes = kept }
    }

    /// The rows of a table, with no probe: one per pid and port, the
    /// addresses merged, ordered by port then pid. Pure, so a test hands in
    /// a table it made.
    public static func servers(
        table: ProcessTable, links: [ShellLink], excludedPids: Set<pid_t>,
        resolveProject: (String) -> ResolvedProject?
    ) -> [Server] {
        struct Key: Hashable {
            var pid: pid_t
            var port: Int
        }
        var addresses: [Key: Set<String>] = [:]
        for listener in table.listeners where !excludedPids.contains(listener.pid) {
            addresses[Key(pid: listener.pid, port: listener.port), default: []].insert(listener.address)
        }
        let shells = Dictionary(links.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(links.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ttys: [UInt32: ShellLink] = [:]
        for link in links {
            if let tty = table.processes[link.pid]?.tty, ttys[tty] == nil { ttys[tty] = link }
        }
        var names: [pid_t: String?] = [:]
        func name(_ pid: pid_t) -> String? {
            if let known = names[pid] { return known }
            let found = table.name(pid)
            names[pid] = found
            return found
        }
        return addresses.keys.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }.map { key in
            let pid = key.pid
            let chain = ancestry(of: pid, in: table)
            var server = Server(
                port: key.port, addresses: addresses[key]!.sorted(), pid: pid,
                program: name(pid), startedAt: table.processes[pid]?.startedAt, cwd: table.cwd(pid)
            )
            server.project = server.cwd.flatMap(resolveProject)
            let shellIndex = chain.firstIndex { shells[$0] != nil }
            // The environment first: the pane's shell exported its id, and
            // the server keeps it after setsid and after its starter exited
            // (kubectl under Claude Code's detached bg-pty-host). A platform
            // binary's environment is not readable, so the rules below are
            // its fallback.
            let exported = table.sessionID(pid).flatMap(UUID.init(uuidString:))
            var link = exported.flatMap { byID[$0] }
            // Then the tty: a server whose starter has exited keeps the
            // pane's terminal (postgres from a pane, reparented to launchd).
            if link == nil { link = table.processes[pid]?.tty.flatMap { ttys[$0] } }
            if link == nil, let shellIndex { link = shells[chain[shellIndex]] }
            if let link {
                // The program under the shell on the chain, when the server
                // is not the shell's own child; with the shell off the chain,
                // the top program below launchd that is not the server.
                var through: String?
                if let shellIndex, shells[chain[shellIndex]]?.id == link.id {
                    if shellIndex > 1 { through = name(chain[shellIndex - 1]) }
                } else if chain.count > 1 {
                    through = name(chain[chain.count - 1])
                }
                server.session = SessionLink(id: link.id, name: link.name, through: through.flatMap(Self.firstWord))
            } else if let exported {
                server.endedSession = exported
            } else {
                if chain.count > 1 {
                    let top = chain[chain.count - 1]
                    server.launcher = name(top)
                    server.parent = name(chain[1])
                }
            }
            return server
        }
    }

    /// The first word of a program's name: `claude` from the title
    /// `claude bg-pty-host` Claude Code gives its detached host.
    static func firstWord(_ name: String) -> String? {
        let word = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
        return word?.isEmpty == false ? word : nil
    }

    /// `pid`, its parent, and so on, up to the process whose parent is
    /// launchd or that the table does not hold, at most `maxChain` deep.
    static func ancestry(of pid: pid_t, in table: ProcessTable) -> [pid_t] {
        var chain = [pid]
        var current = pid
        while chain.count < maxChain, let process = table.processes[current], process.ppid > 1,
              table.processes[process.ppid] != nil, !chain.contains(process.ppid)
        {
            chain.append(process.ppid)
            current = process.ppid
        }
        return chain
    }
}
