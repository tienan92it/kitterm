#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers

/// The pull requests of each GitHub repository a project's `origin` names,
/// read with `gh pr list` (`sessions-workflow` round 2) and served by
/// `GET /api/projects/<id>/pulls`. `gh` and the human's own `gh` login are
/// the only source: no token file, no REST client.
///
/// Every `gh` runs on `queue`, never on the event loop, with a timeout. A
/// request reads `snapshot` under the lock and calls `refreshIfDue`, which
/// starts a read of a repository when none runs and the last one ended
/// `refreshSeconds` ago or more; no request waits for `gh`. The minute
/// counts from the end of a read, not from its start, so a repository whose
/// `gh` takes its whole timeout to fail is not due again when it ends. A
/// read that fails keeps the last good list with its `readAt` and adds the
/// reason.
public final class PullRequestStatus: @unchecked Sendable {
    public static let refreshSeconds: TimeInterval = 60
    public static let timeoutSeconds: TimeInterval = 20
    /// How long a `gh` that got `SIGTERM` at the timeout has before `SIGKILL`.
    public static let killGraceSeconds: TimeInterval = 1
    /// How long the pipes are read after `gh` ended, for a child of `gh`
    /// that keeps one open.
    public static let pipeGraceSeconds: TimeInterval = 0.5
    static let maxOutputBytes = 8 << 20
    static let maxErrorBytes = 64 << 10
    public static let limit = 50
    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "kitterm.pulls", qos: .utility)
        queue.setSpecific(key: queueMark.key, value: true)
        return queue
    }()
    /// The key `queue` alone carries. It is an identity that nothing
    /// mutates; the box is there because corelibs Dispatch does not mark
    /// the key `Sendable`.
    private final class QueueMark: @unchecked Sendable {
        let key = DispatchSpecificKey<Bool>()
    }
    private static let queueMark = QueueMark()
    /// True on `queue`, so a test can tell where a `gh` ran.
    static var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueMark.key) == true }

    public static let noRemoteReason = "no GitHub remote"
    public static let notReadReason = "not read yet"
    public static let absentReason = "gh is not on PATH"
    public static let loggedOutReason = "gh is not logged in"

    /// One pull request, as the route prints it.
    public struct Pull: Equatable, Sendable {
        public var number: Int
        public var title: String
        /// `open`, `closed` or `merged`.
        public var state: String
        public var draft: Bool
        public var headRefName: String
        public var mergedAt: String?
        public var url: String
        /// `passing`, `failing` or `pending`; nil with no checks.
        public var ci: String?
        public var additions: Int
        public var deletions: Int

        var json: [String: Any] {
            var item: [String: Any] = [
                "number": number, "title": title, "state": state, "draft": draft,
                "headRefName": headRefName, "url": url, "additions": additions, "deletions": deletions,
            ]
            if let mergedAt { item["mergedAt"] = mergedAt }
            if let ci { item["ci"] = ci }
            return item
        }
    }

    /// What the cache holds for one repository: the last good list, when
    /// `gh` printed it, and why the latest read gave none.
    public struct Snapshot: Equatable, Sendable {
        public var pulls: [Pull] = []
        public var readAt: Date?
        public var reason: String?
    }

    /// The end of one `gh` process.
    public struct RunResult: Sendable {
        public var status: Int32
        public var output: Data
        public var error: String
        public var timedOut: Bool

        public init(status: Int32, output: Data = Data(), error: String = "", timedOut: Bool = false) {
            self.status = status
            self.output = output
            self.error = error
            self.timedOut = timedOut
        }
    }

    /// Runs the executable at a path with arguments; nil when it cannot
    /// start. `keepOutput` false sends its stdout to `/dev/null`.
    public typealias Runner = @Sendable (_ executable: String, _ args: [String], _ keepOutput: Bool) -> RunResult?

    private struct Entry {
        var snapshot = Snapshot(reason: PullRequestStatus.notReadReason)
        var endedAt: Date?
        var reading = false
    }

    private let searchPath: String
    private let run: Runner
    private let clock: @Sendable () -> Date
    private let lock = NIOLock()
    private var cache: [String: Entry] = [:]

    /// `searchPath` is where `gh` is looked for, in `PATH` form. The default
    /// is the daemon's `PATH`, then the directories a `gh` is installed in:
    /// launchd starts the service with `/usr/bin:/bin:/usr/sbin:/sbin`.
    public init(
        searchPath: String = PullRequestStatus.defaultSearchPath, run: Runner? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.searchPath = searchPath
        self.clock = clock
        self.run = run ?? { executable, args, keepOutput in
            PullRequestStatus.run(
                executable: executable, args: args, searchPath: searchPath,
                timeout: PullRequestStatus.timeoutSeconds, keepOutput: keepOutput
            )
        }
    }

    public static var defaultSearchPath: String {
        let own = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return own + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
    }

    /// What the cache holds for `repository` (`owner/repo`), under the lock
    /// alone. A repository never read answers no pull and `notReadReason`.
    public func snapshot(repository: String) -> Snapshot {
        lock.withLock { cache[repository]?.snapshot ?? Snapshot(reason: Self.notReadReason) }
    }

    /// Start one read of `repository` on `queue` when none runs and the last
    /// one ended `refreshSeconds` ago or more. True when a read started.
    @discardableResult
    public func refreshIfDue(repository: String) -> Bool {
        let now = clock()
        let due: Bool = lock.withLock {
            var entry = cache[repository] ?? Entry()
            if entry.reading { return false }
            if let last = entry.endedAt, now.timeIntervalSince(last) < Self.refreshSeconds { return false }
            entry.reading = true
            cache[repository] = entry
            return true
        }
        guard due else { return false }
        Self.queue.async { self.refresh(repository: repository) }
        return true
    }

    /// One read, on `queue`: `gh pr list`, and `gh auth token` only after
    /// a list that failed, to say which failure it was.
    private func refresh(repository: String) {
        let outcome = Self.fetch(repository: repository, searchPath: searchPath, run: run)
        let ended = clock()
        lock.withLock {
            var entry = cache[repository] ?? Entry()
            entry.reading = false
            entry.endedAt = ended
            switch outcome {
            case .success(let pulls):
                entry.snapshot = Snapshot(pulls: pulls, readAt: ended, reason: nil)
            case .failure(let failure):
                entry.snapshot.reason = failure.reason
            }
            cache[repository] = entry
        }
    }

    struct Failure: Error, Equatable {
        var reason: String
    }

    static func listArguments(repository: String) -> [String] {
        [
            "pr", "list", "--repo", repository, "--state", "all", "--limit", String(limit),
            "--json", "number,title,state,isDraft,headRefName,mergedAt,url,statusCheckRollup,additions,deletions",
        ]
    }

    /// The pulls of `repository`, or why there are none. Synchronous.
    static func fetch(repository: String, searchPath: String, run: Runner) -> Result<[Pull], Failure> {
        guard let gh = locate("gh", in: searchPath) else { return .failure(Failure(reason: absentReason)) }
        guard let list = run(gh, listArguments(repository: repository), true) else {
            return .failure(Failure(reason: "gh did not start"))
        }
        if list.timedOut {
            return .failure(Failure(reason: "gh pr list timed out after \(Int(timeoutSeconds)) s"))
        }
        guard list.status == 0 else {
            // `gh auth token` reads the local login and asks no server, so
            // an offline machine is not logged out. Its exit status is the
            // answer; the token it prints goes to `/dev/null`.
            if let auth = run(gh, ["auth", "token"], false), !auth.timedOut, auth.status != 0 {
                return .failure(Failure(reason: loggedOutReason))
            }
            let line = list.error.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let exit = "gh pr list exited \(list.status)"
            return .failure(Failure(reason: line.isEmpty ? exit : exit + ": " + String(line.prefix(200))))
        }
        guard let pulls = parse(list.output) else {
            return .failure(Failure(reason: "gh pr list printed no JSON list"))
        }
        return .success(pulls)
    }

    /// The pulls of a `gh pr list --json …` output, in its order; nil when
    /// the output is not a JSON list. An item with no number is skipped.
    public static func parse(_ output: Data) -> [Pull]? {
        guard let items = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let number = item["number"] as? Int else { return nil }
            return Pull(
                number: number,
                title: item["title"] as? String ?? "",
                state: (item["state"] as? String ?? "").lowercased(),
                draft: item["isDraft"] as? Bool ?? false,
                headRefName: item["headRefName"] as? String ?? "",
                mergedAt: item["mergedAt"] as? String,
                url: item["url"] as? String ?? "",
                ci: ciWord(rollup: item["statusCheckRollup"] as? [[String: Any]] ?? []),
                additions: item["additions"] as? Int ?? 0,
                deletions: item["deletions"] as? Int ?? 0
            )
        }
    }

    /// One word for a `statusCheckRollup`: `failing` when any check failed,
    /// else `pending` when any check has not ended, else `passing`; nil with
    /// no checks. A `CheckRun` carries `status` and `conclusion`, a
    /// `StatusContext` carries `state`.
    public static func ciWord(rollup: [[String: Any]]) -> String? {
        guard !rollup.isEmpty else { return nil }
        var pending = false
        for check in rollup {
            if let state = check["state"] as? String {
                if state == "FAILURE" || state == "ERROR" { return "failing" }
                if state == "PENDING" || state == "EXPECTED" { pending = true }
                continue
            }
            let conclusion = check["conclusion"] as? String ?? ""
            if failedConclusions.contains(conclusion) { return "failing" }
            if (check["status"] as? String ?? "") != "COMPLETED" { pending = true }
        }
        return pending ? "pending" : "passing"
    }

    private static let failedConclusions: Set<String> = [
        "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE",
    ]

    /// `owner/repo` of a `pullRequestBase`, `https://github.com/owner/repo/pull/`.
    public static func repository(pullRequestBase base: String) -> String? {
        let prefix = "https://github.com/", suffix = "/pull/"
        guard base.hasPrefix(prefix), base.hasSuffix(suffix) else { return nil }
        let repository = base.dropFirst(prefix.count).dropLast(suffix.count)
        return repository.isEmpty ? nil : String(repository)
    }

    /// The first executable file named `name` in the absolute directories
    /// of `searchPath`; a relative entry is skipped, because the daemon's
    /// cwd is not a place to find a program in.
    static func locate(_ name: String, in searchPath: String) -> String? {
        for directory in searchPath.split(separator: ":") where directory.hasPrefix("/") {
            let path = directory + "/" + name
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Run `executable` with `searchPath` as its `PATH` and no prompt; nil
    /// when it cannot start. The process leads its own process group. At
    /// `timeout` the group gets `SIGTERM`, and `SIGKILL` after `killGrace`,
    /// so a `gh` that ignores the first signal still ends. One thread reads
    /// both pipes and reaps the process; once the process has ended, the
    /// pipes are read for `pipeGrace` at most and then closed, so a child
    /// that keeps one open holds nothing and what was read is judged.
    public static func run(
        executable: String, args: [String], searchPath: String, timeout: TimeInterval,
        killGrace: TimeInterval = PullRequestStatus.killGraceSeconds,
        pipeGrace: TimeInterval = PullRequestStatus.pipeGraceSeconds,
        keepOutput: Bool = true
    ) -> RunResult? {
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&errPipe) == 0 else { return nil }
        guard !keepOutput || pipe(&outPipe) == 0 else {
            _ = close(errPipe[0]); _ = close(errPipe[1])
            return nil
        }
        // The parent's ends must not reach another child of the daemon.
        for fd in outPipe + errPipe where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        // Darwin hands these back as pointers, glibc as structs.
        #if canImport(Darwin)
        var attrs: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        #else
        var attrs = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawnattr_init(&attrs)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attrs)
            posix_spawn_file_actions_destroy(&actions)
        }
        #if canImport(Darwin)
        // Close everything undeclared: swift-nio sets no close-on-exec on
        // Darwin sockets. Linux has no such flag; the daemon's descriptors
        // are close-on-exec at creation there (`PtySession`).
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        #else
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        #endif
        posix_spawnattr_setpgroup(&attrs, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        if keepOutput {
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0.key + "=" + $0.value) }
        envp.append(nil)
        defer { for pointer in argv + envp where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let spawned = executable.withCString { posix_spawn(&pid, $0, &actions, &attrs, &argv, &envp) }
        if outPipe[1] >= 0 { _ = close(outPipe[1]) }
        _ = close(errPipe[1])
        var readers: [(fd: Int32, isOutput: Bool)] = [(errPipe[0], false)]
        if outPipe[0] >= 0 { readers.append((outPipe[0], true)) }
        guard spawned == 0, pid > 0 else {
            for reader in readers { _ = close(reader.fd) }
            return nil
        }

        func seconds(since start: DispatchTime) -> TimeInterval {
            TimeInterval(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        }
        let started = DispatchTime.now()
        var output = Data(), error = Data()
        var status: Int32?
        var endedAt = started
        var timedOut = false, killed = false
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if status == nil {
                var raw: Int32 = 0
                let reaped = waitpid(pid, &raw, WNOHANG)
                if reaped == pid {
                    // An exit code, or 128 plus the signal that ended it.
                    status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
                    endedAt = DispatchTime.now()
                } else if reaped < 0, errno != EINTR {
                    status = -1
                    endedAt = DispatchTime.now()
                } else if !timedOut, seconds(since: started) >= timeout {
                    timedOut = true
                    _ = kill(-pid, SIGTERM)
                } else if timedOut, !killed, seconds(since: started) >= timeout + killGrace {
                    killed = true
                    _ = kill(-pid, SIGKILL)
                }
            }
            if status != nil, readers.isEmpty || seconds(since: endedAt) >= pipeGrace { break }
            guard !readers.isEmpty else {
                usleep(20_000)
                continue
            }
            var polled = readers.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            guard poll(&polled, nfds_t(polled.count), 20) > 0 else { continue }
            for entry in polled where entry.revents != 0 {
                let count = read(entry.fd, &buffer, buffer.count)
                if count > 0 {
                    let isOutput = readers.first { $0.fd == entry.fd }?.isOutput ?? false
                    if isOutput {
                        output.append(contentsOf: buffer[0..<min(count, max(0, maxOutputBytes - output.count))])
                    } else {
                        error.append(contentsOf: buffer[0..<min(count, max(0, maxErrorBytes - error.count))])
                    }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    _ = close(entry.fd)
                    readers.removeAll { $0.fd == entry.fd }
                }
            }
        }
        for reader in readers { _ = close(reader.fd) }
        return RunResult(
            status: status ?? -1, output: output,
            error: String(decoding: error, as: UTF8.self), timedOut: timedOut
        )
    }
}
