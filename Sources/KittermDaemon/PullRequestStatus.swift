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
/// starts a read of a repository when none runs and the last one ended its
/// interval ago or more; no request waits for `gh`. The interval counts
/// from the end of a read, not from its start, so a repository whose `gh`
/// takes its whole timeout to fail is not due again when it ends. A read
/// that fails keeps the last good list with its `readAt` and adds the
/// reason.
///
/// **The schedule is adaptive** (`sessions-workflow` round 8,
/// `corpus/03-faster-pull-sync.md`). `interval` is pure: a repository with
/// open work reads every `activeSeconds` (15), else every `idleSeconds`
/// (180). Open work is an open pull request whose `ci` is `pending`, a pull
/// request whose `updatedAt` is under `recentSeconds` (5 min) old, or a live
/// session labelled `pr:<N>` for one of its open pull requests (the
/// registry hands the labels to the route, which hands them here). A
/// `nudge` reads at once, `nudgeGapSeconds` (5) after the last read's
/// start at the earliest, one read at a time; a nudge while a read runs
/// queues exactly one more. **The ceiling**: `readsPerMinute` (24) list
/// reads a minute daemon-wide, nudges included; past it a read waits for
/// the next slot. The rate budget: 7 repositories all active at 15 s is
/// 1,680 GraphQL calls an hour against the account's 5,000-point budget,
/// which every crew's `gh` shares; the ceiling caps the daemon at 1,440 an
/// hour, so the crews keep most of the budget whatever the fleet does. A
/// read whose pulls or reason differ from the last appends `pulls.changed`
/// with each project that asked for the repository to the event feed,
/// never on an unchanged read, so the page asks at once.
///
/// **The change probe** (`sessions-workflow` round 9,
/// `corpus/04-change-probe.md`) answers the two gaps the schedule above
/// still leaves: a change made on github.com, and a crew's `gh pr create`
/// or `git push`, whose Bash tool runs outside the pane's shell, so
/// `PullNudge` never fires. While a full-grade page has asked the pulls
/// route for a repository in the last `watchSeconds` (`watch(repository:)`),
/// the daemon sends a conditional `gh api` request every
/// `probeIntervalSeconds`, on `probeQueue`, apart from `queue` and the
/// event loop; `probeQueue` is concurrent, so several repositories' probes
/// run at once and one slow `gh` never delays another repository's tick,
/// while `probeArmed` keeps at most one tick per repository, never two. A
/// `304` costs nothing; a `200` with a changed `ETag` stores
/// it and nudges through the same `nudge(repository:)` as a local push, so
/// the ceiling and the one-read-at-a-time rule above still bound it; the
/// first `200` only stores the tag. A failure backs the repository off to
/// `probeBackoffSeconds`, and a later success resets it to
/// `probeIntervalSeconds`. The probe never runs while a list read of the
/// same repository is in flight.
public final class PullRequestStatus: @unchecked Sendable {
    /// The interval of a repository with open work.
    public static let activeSeconds: TimeInterval = 15
    /// The interval of a repository with none.
    public static let idleSeconds: TimeInterval = 180
    /// How recent a pull request's `updatedAt` counts as open work.
    public static let recentSeconds: TimeInterval = 300
    /// The least time between two reads' starts of one repository.
    public static let nudgeGapSeconds: TimeInterval = 5
    /// The most list reads a minute, over every repository.
    public static let readsPerMinute = 24
    public static let timeoutSeconds: TimeInterval = 20
    /// The change probe (`sessions-workflow` round 9,
    /// `corpus/04-change-probe.md`): while a full-grade page has asked the
    /// pulls route for a repository in the last `watchSeconds`, the daemon
    /// sends a conditional `gh api` request every `probeIntervalSeconds`,
    /// through `probeQueue`, never `queue` and never the event loop. A `200`
    /// with a changed `ETag` nudges the repository (`nudge(repository:)`,
    /// unchanged); a failure backs the repository off to
    /// `probeBackoffSeconds`, and a later success resets it.
    public static let probeIntervalSeconds: TimeInterval = 5
    public static let probeBackoffSeconds: TimeInterval = 60
    public static let watchSeconds: TimeInterval = 30
    public static let probeTimeoutSeconds: TimeInterval = 10
    /// `per_page` of the probe's own request; the full read keeps `limit`.
    public static let probePerPage = 5
    /// How long a `gh` that got `SIGTERM` at the timeout has before `SIGKILL`.
    public static let killGraceSeconds: TimeInterval = 1
    /// How long the pipes are read after `gh` ended, for a child of `gh`
    /// that keeps one open.
    public static let pipeGraceSeconds: TimeInterval = 0.5
    public static let maxOutputBytes = 8 << 20
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

    /// The change probe's own queue, apart from `queue`: a probe never
    /// blocks behind a list read, and a list read never blocks behind a
    /// probe. Concurrent, because `gh` takes about 0.8 s to start and a
    /// fleet view can watch several repositories at once: a serial queue
    /// would make their 5 s cadences collide, and one slow or hung `gh`
    /// would delay every other repository's probe behind it. `probeArmed`
    /// is the rule that still holds: one tick scheduled or running per
    /// repository, never two.
    static let probeQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "kitterm.pulls-probe", qos: .utility, attributes: .concurrent)
        queue.setSpecific(key: probeQueueMark.key, value: true)
        return queue
    }()
    private final class ProbeQueueMark: @unchecked Sendable {
        let key = DispatchSpecificKey<Bool>()
    }
    private static let probeQueueMark = ProbeQueueMark()
    /// True on `probeQueue`, so a test can tell where a probe ran.
    static var isOnProbeQueue: Bool { DispatchQueue.getSpecific(key: probeQueueMark.key) == true }

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
        /// When the pull request was opened and when it last changed, as
        /// `gh` prints them (`2026-10-06T08:10:36Z`); nil when `gh` gave
        /// none. The time a pull request left draft is not in `gh pr list`,
        /// so the fleet view counts a ready pull request's wait from
        /// `updatedAt`: a push, a review or a label moves it, so the wait is
        /// never longer than the true one (`sessions-workflow` round 7).
        public var createdAt: String?
        public var updatedAt: String?
        /// The head branch is in another repository (a fork). Not in `json`:
        /// `KnowledgeBase.goalBranches` alone reads it.
        public var crossRepository = false

        var json: [String: Any] {
            var item: [String: Any] = [
                "number": number, "title": title, "state": state, "draft": draft,
                "headRefName": headRefName, "url": url, "additions": additions, "deletions": deletions,
            ]
            if let mergedAt { item["mergedAt"] = mergedAt }
            if let ci { item["ci"] = ci }
            if let createdAt { item["createdAt"] = createdAt }
            if let updatedAt { item["updatedAt"] = updatedAt }
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

    /// The status line and the `ETag` header of one `gh api -i` answer to
    /// the change probe.
    public struct ProbeResult: Equatable, Sendable {
        public var status: Int
        public var etag: String?

        public init(status: Int, etag: String? = nil) {
            self.status = status
            self.etag = etag
        }
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

    /// What a repository's last list says about its open work, computed
    /// once per read so a request's `interval` is a few comparisons.
    public struct Activity: Equatable, Sendable {
        /// An open pull request whose `ci` is `pending`.
        public var pendingCI = false
        /// The newest `updatedAt` of any pull request, open or not.
        public var lastUpdatedAt: Date?
        /// The numbers of the open pull requests.
        public var openNumbers: Set<Int> = []

        public init(pendingCI: Bool = false, lastUpdatedAt: Date? = nil, openNumbers: Set<Int> = []) {
            self.pendingCI = pendingCI
            self.lastUpdatedAt = lastUpdatedAt
            self.openNumbers = openNumbers
        }

        public static func of(pulls: [Pull]) -> Activity {
            var activity = Activity()
            for pull in pulls {
                if pull.state == "open" {
                    activity.openNumbers.insert(pull.number)
                    if pull.ci == "pending" { activity.pendingCI = true }
                }
                if let updated = pull.updatedAt.flatMap(PullRequestStatus.date(iso8601:)),
                   activity.lastUpdatedAt.map({ updated > $0 }) ?? true {
                    activity.lastUpdatedAt = updated
                }
            }
            return activity
        }
    }

    /// A live session's `pr:<N>` label with the project the session belongs
    /// to, as the registry hands them to the route (`labelledPulls()`).
    public struct LabelledPull: Equatable, Sendable {
        public var project: String
        public var number: Int

        public init(project: String, number: Int) {
            self.project = project
            self.number = number
        }
    }

    /// Runs `work` after `delay`; the default is `queue.asyncAfter`, a test
    /// hands one it fires by hand.
    public typealias Scheduler = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    private enum ReadState {
        /// No read claimed.
        case idle
        /// A read is claimed and waits for the nudge gap or a slot under
        /// the ceiling; a nudge now changes nothing, the read sees it.
        case waiting
        /// `gh` runs; a nudge now queues one more read.
        case running
    }

    private struct Entry {
        var snapshot = Snapshot(reason: PullRequestStatus.notReadReason)
        var activity = Activity()
        /// The `pr:` labels last handed for the repository; a caller with
        /// no news (the knowledge route) keeps them.
        var labelledPulls: Set<Int> = []
        /// The projects that asked for the repository, each named on
        /// `pulls.changed`.
        var projects: Set<String> = []
        var startedAt: Date?
        var endedAt: Date?
        var state = ReadState.idle
        var nudgePending = false
        /// The change probe: the time this repository was last asked for by
        /// a full-grade page, plus the last probe's own tag and cadence.
        var watchedUntil: Date?
        var probeETag: String?
        var probeInterval: TimeInterval = PullRequestStatus.probeIntervalSeconds
        /// A probe tick is scheduled or running for this repository.
        var probeArmed = false
    }

    private let searchPath: String
    private let run: Runner
    private let probeRun: Runner
    private let clock: @Sendable () -> Date
    private let schedule: Scheduler
    private let probeSchedule: Scheduler
    private let eventLog: EventLog?
    private let lock = NIOLock()
    private var cache: [String: Entry] = [:]
    /// When each list read of the last minute started, oldest first: the
    /// ceiling's window.
    private var starts: [Date] = []

    /// `searchPath` is where `gh` is looked for, in `PATH` form. The default
    /// is the daemon's `PATH`, then the directories a `gh` is installed in:
    /// launchd starts the service with `/usr/bin:/bin:/usr/sbin:/sbin`.
    /// `probeRun` and `probeSchedule` default to the same runner and
    /// `probeQueue`, apart from `run` and `schedule`'s `queue`; a test hands
    /// each its own fake.
    public init(
        searchPath: String = PullRequestStatus.defaultSearchPath, run: Runner? = nil,
        probeRun: Runner? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        schedule: Scheduler? = nil,
        probeSchedule: Scheduler? = nil,
        eventLog: EventLog? = nil
    ) {
        self.searchPath = searchPath
        self.clock = clock
        self.schedule = schedule ?? { delay, work in
            PullRequestStatus.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        self.probeSchedule = probeSchedule ?? { delay, work in
            PullRequestStatus.probeQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        self.eventLog = eventLog
        self.run = run ?? { executable, args, keepOutput in
            PullRequestStatus.run(
                executable: executable, args: args, searchPath: searchPath,
                timeout: PullRequestStatus.timeoutSeconds, keepOutput: keepOutput
            )
        }
        self.probeRun = probeRun ?? { executable, args, keepOutput in
            PullRequestStatus.run(
                executable: executable, args: args, searchPath: searchPath,
                timeout: PullRequestStatus.probeTimeoutSeconds, keepOutput: keepOutput
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

    /// The interval between two reads of a repository: `activeSeconds` with
    /// open work, else `idleSeconds`. Pure; `labelledPulls` are the `pr:`
    /// labels of the live sessions of the repository's projects.
    public static func interval(activity: Activity, labelledPulls: Set<Int>, now: Date) -> TimeInterval {
        if activity.pendingCI { return activeSeconds }
        if let updated = activity.lastUpdatedAt, now.timeIntervalSince(updated) < recentSeconds { return activeSeconds }
        if !activity.openNumbers.isDisjoint(with: labelledPulls) { return activeSeconds }
        return idleSeconds
    }

    /// The interval a repository reads at now, from what the cache holds.
    public func interval(repository: String) -> TimeInterval {
        let now = clock()
        return lock.withLock {
            let entry = cache[repository] ?? Entry()
            return Self.interval(activity: entry.activity, labelledPulls: entry.labelledPulls, now: now)
        }
    }

    /// Start one read of `repository` on `queue` when none is claimed and
    /// the last one ended its `interval` ago or more. `project` is named on
    /// `pulls.changed` for the repository; `labelledPulls` replaces the
    /// labels the interval reads, nil keeps the last ones. True when a read
    /// was claimed (it may wait for a slot under the ceiling).
    @discardableResult
    public func refreshIfDue(repository: String, project: String? = nil, labelledPulls: Set<Int>? = nil) -> Bool {
        let now = clock()
        let claimed: Bool = lock.withLock {
            var entry = cache[repository] ?? Entry()
            defer { cache[repository] = entry }
            if let project { entry.projects.insert(project) }
            if let labelledPulls { entry.labelledPulls = labelledPulls }
            guard entry.state == .idle else { return false }
            if let last = entry.endedAt {
                let interval = Self.interval(activity: entry.activity, labelledPulls: entry.labelledPulls, now: now)
                if now.timeIntervalSince(last) < interval { return false }
            }
            entry.state = .waiting
            return true
        }
        guard claimed else { return false }
        begin(repository: repository, now: now)
        return true
    }

    /// Read `repository` at once: a session of one of its projects finished
    /// a `git push` or a `gh pr` command, or posted a `PROGRESS` or `DONE`
    /// note (`PullNudge`). The read starts `nudgeGapSeconds` after the last
    /// read's start at the earliest; while one runs, exactly one more is
    /// queued after it; while one waits, nothing changes, because that read
    /// sees what the nudge announces.
    public func nudge(repository: String) {
        let now = clock()
        let delay: TimeInterval?? = lock.withLock {
            var entry = cache[repository] ?? Entry()
            defer { cache[repository] = entry }
            switch entry.state {
            case .running:
                entry.nudgePending = true
                return nil
            case .waiting:
                return nil
            case .idle:
                entry.state = .waiting
                return .some(Self.gapLeft(since: entry.startedAt, now: now))
            }
        }
        guard case .some(let gap) = delay else { return }
        if let gap {
            schedule(gap) { self.begin(repository: repository, now: self.clock()) }
        } else {
            begin(repository: repository, now: now)
        }
    }

    /// What is left of the nudge gap after a read that started at `started`;
    /// nil when it has passed or no read started.
    private static func gapLeft(since started: Date?, now: Date) -> TimeInterval? {
        guard let started else { return nil }
        let left = nudgeGapSeconds - now.timeIntervalSince(started)
        return left > 0 ? left : nil
    }

    // MARK: - the change probe

    /// A full-grade page's pulls request named `repository` just now: keep
    /// probing it every `probeIntervalSeconds` until no such request has
    /// come for `watchSeconds` (`sessions-workflow` round 9,
    /// `corpus/04-change-probe.md`, rule 1). The caller only reaches this
    /// once it has resolved a repository, so a project with no
    /// `pullRequestBase` gets no probe. Repeated calls extend the window; a
    /// probe is armed once per repository, never twice.
    public func watch(repository: String) {
        let now = clock()
        let shouldArm: Bool = lock.withLock {
            var entry = cache[repository] ?? Entry()
            defer { cache[repository] = entry }
            entry.watchedUntil = now.addingTimeInterval(Self.watchSeconds)
            guard !entry.probeArmed else { return false }
            entry.probeArmed = true
            return true
        }
        guard shouldArm else { return }
        probeSchedule(Self.probeIntervalSeconds) { self.runProbe(repository: repository) }
    }

    private enum ProbeTick {
        /// The watch window closed: no more ticks.
        case stop
        /// A list read of the repository is in flight: try again at the
        /// same interval, with no `gh` call.
        case skip(TimeInterval)
        /// Run the probe with the stored `ETag`, nil for the first one.
        case run(String?)
    }

    /// What the next probe tick of `repository` should do, decided under
    /// the lock alone.
    private func probeTick(repository: String, now: Date) -> ProbeTick {
        lock.withLock {
            guard var entry = cache[repository] else { return .stop }
            guard let until = entry.watchedUntil, until > now else {
                entry.probeArmed = false
                entry.watchedUntil = nil
                cache[repository] = entry
                return .stop
            }
            if entry.state != .idle { return .skip(entry.probeInterval) }
            return .run(entry.probeETag)
        }
    }

    /// One probe tick of `repository`, on `probeQueue`: rule 3 of
    /// `corpus/04-change-probe.md`. `gh` runs synchronously on this queue,
    /// never the event loop, and never while a list read of the same
    /// repository is in flight (`probeTick`'s `.skip`, never `queue`).
    private func runProbe(repository: String) {
        switch probeTick(repository: repository, now: clock()) {
        case .stop:
            return
        case .skip(let interval):
            probeSchedule(interval) { self.runProbe(repository: repository) }
        case .run(let etag):
            let outcome = Self.fetchProbe(repository: repository, etag: etag, searchPath: searchPath, run: probeRun)
            let ended = clock()
            switch applyProbe(repository: repository, outcome: outcome, ended: ended) {
            case .stop:
                return
            case .reschedule(let interval):
                probeSchedule(interval) { self.runProbe(repository: repository) }
            }
        }
    }

    private enum ProbeNext {
        case stop
        case reschedule(TimeInterval)
    }

    /// Applies one probe's outcome under the lock: a `304` does nothing; a
    /// `200` with a changed `ETag` stores it and nudges, the first `200`
    /// only stores it (rule 2); a failure backs the repository off to
    /// `probeBackoffSeconds`, a success (`200` or `304`) resets it to
    /// `probeIntervalSeconds` (rule 3). The nudge itself runs after the lock
    /// is released, since `nudge(repository:)` takes it too.
    private func applyProbe(repository: String, outcome: Result<ProbeResult, Failure>, ended: Date) -> ProbeNext {
        var shouldNudge = false
        let next: ProbeNext = lock.withLock {
            var entry = cache[repository] ?? Entry()
            defer { cache[repository] = entry }
            switch outcome {
            case .success(let result):
                entry.probeInterval = Self.probeIntervalSeconds
                if result.status == 200, let newTag = result.etag {
                    if let old = entry.probeETag, old != newTag { shouldNudge = true }
                    entry.probeETag = newTag
                }
            case .failure:
                entry.probeInterval = Self.probeBackoffSeconds
            }
            guard let until = entry.watchedUntil, until > ended else {
                entry.probeArmed = false
                entry.watchedUntil = nil
                return .stop
            }
            return .reschedule(entry.probeInterval)
        }
        if shouldNudge { nudge(repository: repository) }
        return next
    }

    /// `gh api -i -H 'If-None-Match: <etag>' repos/<owner>/<repo>/pulls?…`,
    /// the conditional request of rule 1; no `-H` with no stored tag yet.
    static func probeArguments(repository: String, etag: String?) -> [String] {
        var args = ["api", "-i"]
        if let etag {
            args += ["-H", "If-None-Match: \(etag)"]
        }
        args.append("repos/\(repository)/pulls?state=all&sort=updated&direction=desc&per_page=\(probePerPage)")
        return args
    }

    /// The status and the `ETag` of one conditional read of `repository`'s
    /// pull requests, or why it failed. Synchronous, like `fetch`.
    static func fetchProbe(repository: String, etag: String?, searchPath: String, run: Runner) -> Result<ProbeResult, Failure> {
        guard let gh = locate("gh", in: searchPath) else { return .failure(Failure(reason: absentReason)) }
        guard let result = run(gh, probeArguments(repository: repository, etag: etag), true) else {
            return .failure(Failure(reason: "gh did not start"))
        }
        if result.timedOut {
            return .failure(Failure(reason: "gh api timed out after \(Int(probeTimeoutSeconds)) s"))
        }
        if let parsed = parseProbe(result.output) {
            return .success(parsed)
        }
        let line = result.error.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let exit = "gh api exited \(result.status)"
        return .failure(Failure(reason: line.isEmpty ? exit : exit + ": " + String(line.prefix(200))))
    }

    /// The status line and the `ETag` header of one `gh api -i` answer,
    /// parsed by hand so no HTTP client is pulled in for five lines of
    /// text; nil when the first line is not a status line. Both CRLF and
    /// LF split lines, so an `HTTP/1.1 200 OK` or an `HTTP/2.0 304 Not
    /// Modified` line parses the same either way; `ETag:` is matched
    /// case-insensitively and a weak tag (`W/"abc"`) is kept whole; a
    /// response with no `ETag` header answers a nil one.
    public static func parseProbe(_ output: Data) -> ProbeResult? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let head = normalized.components(separatedBy: "\n\n").first ?? normalized
        let lines = head.split(separator: "\n", omittingEmptySubsequences: true)
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return nil }
        var etag: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "etag" {
                etag = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return ProbeResult(status: status, etag: etag)
    }

    /// Start the claimed read of `repository`, or wait for the next slot
    /// under the ceiling: `readsPerMinute` starts in the last minute over
    /// every repository, and the slot opens a minute after the oldest.
    private func begin(repository: String, now: Date) {
        let wait: TimeInterval? = lock.withLock {
            starts.removeAll { now.timeIntervalSince($0) >= 60 }
            if starts.count >= Self.readsPerMinute, let oldest = starts.first {
                return max(0.01, 60 - now.timeIntervalSince(oldest))
            }
            starts.append(now)
            var entry = cache[repository] ?? Entry()
            entry.state = .running
            entry.startedAt = now
            cache[repository] = entry
            return nil
        }
        if let wait {
            schedule(wait) { self.begin(repository: repository, now: self.clock()) }
            return
        }
        Self.queue.async { self.refresh(repository: repository) }
    }

    /// One read, on `queue`: `gh pr list`, and `gh auth token` only after
    /// a list that failed, to say which failure it was. Then the
    /// `pulls.changed` events for a changed answer, and the read a nudge
    /// queued meanwhile.
    private func refresh(repository: String) {
        let outcome = Self.fetch(repository: repository, searchPath: searchPath, run: run)
        let ended = clock()
        var changedProjects: [String] = []
        var again: TimeInterval?? = nil
        lock.withLock {
            var entry = cache[repository] ?? Entry()
            let before = entry.snapshot
            entry.state = .idle
            entry.endedAt = ended
            switch outcome {
            case .success(let pulls):
                entry.snapshot = Snapshot(pulls: pulls, readAt: ended, reason: nil)
            case .failure(let failure):
                entry.snapshot.reason = failure.reason
            }
            entry.activity = Activity.of(pulls: entry.snapshot.pulls)
            // The answer less `readAt` and `ageSeconds`: a read that found
            // the same list again is not a change.
            if entry.snapshot.pulls != before.pulls || entry.snapshot.reason != before.reason {
                changedProjects = entry.projects.sorted()
            }
            if entry.nudgePending {
                entry.nudgePending = false
                entry.state = .waiting
                again = .some(Self.gapLeft(since: entry.startedAt, now: ended))
            }
            cache[repository] = entry
        }
        for project in changedProjects {
            eventLog?.append(type: "pulls.changed", session: nil, data: ["project": project])
        }
        guard case .some(let gap) = again else { return }
        if let gap {
            schedule(gap) { self.begin(repository: repository, now: self.clock()) }
        } else {
            begin(repository: repository, now: ended)
        }
    }

    /// A `gh` time, `2026-10-06T08:10:36Z` (a fraction of a second is
    /// accepted and dropped); nil for any other string. Parsed by hand
    /// through `timegm`, so no formatter is shared between threads.
    public static func date(iso8601 string: String) -> Date? {
        var tm = tm()
        let fields: [(start: Int, count: Int)] = [(0, 4), (5, 2), (8, 2), (11, 2), (14, 2), (17, 2)]
        let separators: [(index: Int, char: Character)] = [(4, "-"), (7, "-"), (10, "T"), (13, ":"), (16, ":")]
        let chars = Array(string)
        guard chars.count >= 20, chars.last == "Z" else { return nil }
        for separator in separators where chars[separator.index] != separator.char { return nil }
        var values: [Int32] = []
        for field in fields {
            let digits = chars[field.start..<field.start + field.count]
            guard digits.allSatisfy(\.isNumber), let value = Int32(String(digits)) else { return nil }
            values.append(value)
        }
        let rest = chars[19..<chars.count - 1]
        if !rest.isEmpty, rest.first != "." || !rest.dropFirst().allSatisfy(\.isNumber) { return nil }
        tm.tm_year = values[0] - 1900
        tm.tm_mon = values[1] - 1
        tm.tm_mday = values[2]
        tm.tm_hour = values[3]
        tm.tm_min = values[4]
        tm.tm_sec = values[5]
        let seconds = timegm(&tm)
        guard seconds != -1 || values == [1969, 12, 31, 23, 59, 59] else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    struct Failure: Error, Equatable {
        var reason: String
    }

    static func listArguments(repository: String) -> [String] {
        [
            "pr", "list", "--repo", repository, "--state", "all", "--limit", String(limit),
            "--json", "number,title,state,isDraft,headRefName,mergedAt,url,statusCheckRollup,additions,deletions,createdAt,updatedAt,isCrossRepository",
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
                deletions: item["deletions"] as? Int ?? 0,
                createdAt: item["createdAt"] as? String,
                updatedAt: item["updatedAt"] as? String,
                crossRepository: item["isCrossRepository"] as? Bool ?? false
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
    /// `input` is the program's whole stdin, handed over as a scratch file
    /// of mode 0600 that is removed when the run ends, so no write can
    /// block on a full pipe or take `SIGPIPE`; `environment` is laid over the daemon's own; stdout is
    /// kept up to `maxOutput` bytes. `KnowledgeBase` runs `git` with it.
    public static func run(
        executable: String, args: [String], searchPath: String, timeout: TimeInterval,
        killGrace: TimeInterval = PullRequestStatus.killGraceSeconds,
        pipeGrace: TimeInterval = PullRequestStatus.pipeGraceSeconds,
        keepOutput: Bool = true,
        input: Data? = nil, environment extra: [String: String] = [:],
        maxOutput: Int = PullRequestStatus.maxOutputBytes
    ) -> RunResult? {
        var inputPath: String?
        if let input {
            var template = Array((NSTemporaryDirectory() + "/kitterm-stdin-XXXXXX").utf8CString)
            let fd = mkstemp(&template)
            guard fd >= 0 else { return nil }
            let path = String(cString: template)
            let written = input.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            _ = close(fd)
            guard written == input.count else {
                unlink(path)
                return nil
            }
            inputPath = path
        }
        defer { if let inputPath { unlink(inputPath) } }
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
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, inputPath ?? "/dev/null", O_RDONLY, 0)
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
        environment.merge(extra) { _, new in new }
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
                        output.append(contentsOf: buffer[0..<min(count, max(0, maxOutput - output.count))])
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
