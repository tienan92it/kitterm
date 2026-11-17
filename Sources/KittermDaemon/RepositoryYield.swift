import Foundation
import NIOConcurrencyHelpers

/// What a repository's own history says a range of days delivered: merged
/// pull requests, the lines they added, and releases. The counts behind the
/// `VALUE` tiles and the `project` rows of the fleet view's `WHERE` panel
/// (`agent-dashboard`, capability 7; `corpus/valuemaxxing.md`, finding 1).
///
/// ## Where each count comes from
///
/// Everything is read from `git` in the project root, never from the rollup
/// and never from the network:
///
/// - **The branch** is the remote's line of history: `origin/HEAD` when the
///   remote set it, else `origin/main`, else `origin/master`, else the
///   checkout's own `HEAD`. Merged means merged there.
/// - **A merged pull request** is a first-parent commit on that branch in the
///   range whose subject ends in `(#N)` (a squash merge, which is how this
///   repository merges) or starts with `Merge pull request #N`. The range
///   is by committer date, which is when the merge happened, with the
///   day bounds resolved in the zone the caller names.
/// - **Merged lines** are the insertions of those commits, from
///   `--shortstat` against the first parent.
/// - **A release** is a tag whose creation date falls in the range.
///
/// ## What is refused
///
/// A root that is not a git checkout has no history: every count is absent.
/// A checkout with no remote has commits but no pull requests, because a
/// pull request is the remote's concept: the two PR counts are absent and
/// the releases are counted from its tags. The page prints a dash for an
/// absent count and never a zero, because zero is a measurement.
public struct RepositoryYield: Codable, Equatable, Sendable {
    /// The root is a git checkout.
    public var checkout: Bool
    /// The checkout has at least one remote.
    public var remote: Bool
    /// The branch the commits were counted on; nil without a checkout.
    public var branch: String?
    public var mergedPullRequests: Int?
    public var mergedLines: Int?
    public var releases: Int?
    /// Each merged pull request in the range, by number, with the lines
    /// it added: what the fleet view's `WHERE` panel prices a goal's
    /// lines from, by the `PR #N` its round records name. Absent with
    /// `mergedPullRequests`; a merge commit whose subject names no number
    /// is counted above and left out here.
    public var pullRequests: [PullRequest]?

    /// One merged pull request: its number and the lines it added.
    public struct PullRequest: Codable, Equatable, Sendable {
        public var number: Int
        public var lines: Int

        public init(number: Int, lines: Int) {
            self.number = number
            self.lines = lines
        }
    }

    public init(
        checkout: Bool, remote: Bool, branch: String? = nil,
        mergedPullRequests: Int? = nil, mergedLines: Int? = nil, releases: Int? = nil,
        pullRequests: [PullRequest]? = nil
    ) {
        self.checkout = checkout
        self.remote = remote
        self.branch = branch
        self.mergedPullRequests = mergedPullRequests
        self.mergedLines = mergedLines
        self.releases = releases
        self.pullRequests = pullRequests
    }

    /// Not a checkout: nothing to count.
    public static let none = RepositoryYield(checkout: false, remote: false)

    /// One first-parent commit of the log, as `parseLog` reads it.
    public struct Commit: Equatable, Sendable {
        public var sha: String
        public var subject: String
        public var insertions: Int
    }

    /// `git`, run with these arguments; nil when it could not run, else its
    /// exit status and its standard output. A test passes a stub.
    public typealias Git = ([String]) -> (status: Int32, output: String)?

    /// The refs tried in order for the branch to count on.
    static let branchCandidates = ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master", "HEAD"]

    private static let separator = "\u{1E}"
    private static let field = "\u{1F}"

    /// Read `root`'s history for the days `from` through `to`, inclusive, in
    /// `zone`. Synchronous; `RepositoryYields` runs it on its queue.
    public static func read(
        root: String, from: DayKey, to: DayKey, zone: TimeZone, git: Git = { run(args: $0) }
    ) -> RepositoryYield {
        func at(_ args: [String]) -> (status: Int32, output: String)? { git(["-C", root] + args) }
        guard let inside = at(["rev-parse", "--is-inside-work-tree"]), inside.status == 0,
              inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return .none }
        let remotes = at(["remote"])
        let remote = remotes?.status == 0 && !(remotes?.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        var branch: String?
        for candidate in branchCandidates {
            if let found = at(["rev-parse", "--verify", "--quiet", candidate]), found.status == 0 {
                branch = candidate == "HEAD" ? "HEAD" : String(candidate.dropFirst("refs/remotes/".count))
                break
            }
        }
        var yield = RepositoryYield(checkout: true, remote: remote, branch: branch)
        // Epoch seconds, so `git` cannot read the bounds in the machine's
        // zone: a range ending on the 4th in `+07` ends at `16:59:59Z`.
        let since = Int(firstInstant(of: from, in: zone).timeIntervalSince1970)
        let until = Int(firstInstant(of: to.advanced(by: 1), in: zone).timeIntervalSince1970) - 1
        if remote, let branch, let log = at([
            "log", branch == "HEAD" ? "HEAD" : "refs/remotes/" + branch, "--first-parent", "--diff-merges=first-parent",
            "--shortstat", "--since=@\(since)", "--until=@\(until)",
            "--format=\(separator)%H\(field)%s",
        ]), log.status == 0 {
            let merged = parseLog(log.output).filter { isPullRequest($0.subject) }
            yield.mergedPullRequests = merged.count
            yield.mergedLines = merged.reduce(0) { $0 + $1.insertions }
            yield.pullRequests = merged.compactMap { commit in
                pullRequestNumber(commit.subject).map { PullRequest(number: $0, lines: commit.insertions) }
            }
        }
        if let tags = at(["for-each-ref", "refs/tags", "--format=%(creatordate:unix)"]), tags.status == 0 {
            yield.releases = tags.output.split(separator: "\n").filter { line in
                guard let seconds = Double(line.trimmingCharacters(in: .whitespaces)) else { return false }
                let day = DayKey(Date(timeIntervalSince1970: seconds), in: zone)
                return from <= day && day <= to
            }.count
        }
        return yield
    }

    /// The first instant of `day` in `zone`, DST-aware: the inverse of
    /// `DayKey(_:in:)`. The offset is read at the guessed instant and once
    /// more at the corrected one, so a transition at midnight lands right.
    static func firstInstant(of day: DayKey, in zone: TimeZone) -> Date {
        let naive = TimeInterval(day.number * 86_400)
        let guess = naive - TimeInterval(zone.secondsFromGMT(for: Date(timeIntervalSince1970: naive)))
        return Date(timeIntervalSince1970: naive - TimeInterval(zone.secondsFromGMT(for: Date(timeIntervalSince1970: guess))))
    }

    /// The pull request number a merged commit's subject names: `N` from a
    /// squash merge's `(#N)` suffix or a merge commit's `Merge pull request
    /// #N`; nil for a subject `isPullRequest` refuses.
    public static func pullRequestNumber(_ subject: String) -> Int? {
        guard isPullRequest(subject) else { return nil }
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Merge pull request #") {
            let digits = trimmed.dropFirst("Merge pull request #".count).prefix { $0.isASCII && $0.isNumber }
            return Int(digits)
        }
        guard let open = trimmed.lastIndex(of: "(") else { return nil }
        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return Int(inside.dropFirst())
    }

    /// A squash merge's `(#N)` suffix, or a merge commit's subject.
    public static func isPullRequest(_ subject: String) -> Bool {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Merge pull request #") { return true }
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return false }
        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return inside.hasPrefix("#") && inside.count > 1 && inside.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The commits of a `git log --shortstat --format=<RS>%H<US>%s` output:
    /// one record per record separator, the sha and the subject on its first
    /// line, and the insertions from the `N insertions(+)` of its stat line,
    /// 0 when the commit changed nothing.
    public static func parseLog(_ output: String) -> [Commit] {
        output.split(separator: Character(separator), omittingEmptySubsequences: true).compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
            guard let head = lines.first else { return nil }
            let parts = head.split(separator: Character(field), maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            var insertions = 0
            for line in lines.dropFirst() {
                guard let range = line.range(of: " insertion") else { continue }
                let before = line[..<range.lowerBound]
                let digits = before.split(separator: " ").last.map(String.init) ?? ""
                insertions = Int(digits) ?? 0
            }
            return Commit(sha: String(parts[0]), subject: String(parts[1]), insertions: insertions)
        }
    }

    /// Run `git` through `/usr/bin/env`, the way `GoalLedger` does; nil when
    /// it cannot start. The output is read to its end before the wait, so a
    /// long log cannot fill the pipe and hang.
    public static func run(args: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - the LIFETIME chart's day-by-day counts

    /// One day's slice of a root's history, the `readDaily` counterpart of
    /// `read`'s one total: the same absent-means-no-source rule, per day
    /// instead of over the whole range. A root that is not a checkout
    /// carries every field absent; a checkout with no remote carries the
    /// two pull-request fields absent and `releases` counted.
    public struct DailyCounts: Codable, Equatable, Sendable {
        public var day: String
        public var mergedPullRequests: Int?
        public var mergedLines: Int?
        public var releases: Int?

        public init(day: String, mergedPullRequests: Int? = nil, mergedLines: Int? = nil, releases: Int? = nil) {
            self.day = day
            self.mergedPullRequests = mergedPullRequests
            self.mergedLines = mergedLines
            self.releases = releases
        }
    }

    /// One commit's committer date, subject and insertions, read for
    /// `readDaily`'s bucketing. A separate shape from `Commit`: `read`'s
    /// one total never needs a date, and adding one to `Commit` would
    /// change a shape an existing test constructs by its exact fields.
    struct DatedCommit: Equatable {
        var subject: String
        var insertions: Int
        var committerDate: Date
    }

    /// `git log --format=<RS>%cI<FS>%s` parsed the way `parseLog` reads
    /// `<RS>%H<FS>%s`: one record per `RS`, the committer date and the
    /// subject on the first line, the insertions from the stat line that
    /// follows (`git`'s own `%cI`, strict ISO 8601 with the zone offset).
    static func parseLogWithDate(_ output: String) -> [DatedCommit] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return output.split(separator: Character(separator), omittingEmptySubsequences: true).compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
            guard let head = lines.first else { return nil }
            let parts = head.split(separator: Character(field), maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, let date = iso.date(from: String(parts[0])) else { return nil }
            var insertions = 0
            for line in lines.dropFirst() {
                guard let range = line.range(of: " insertion") else { continue }
                let before = line[..<range.lowerBound]
                let digits = before.split(separator: " ").last.map(String.init) ?? ""
                insertions = Int(digits) ?? 0
            }
            return DatedCommit(subject: String(parts[1]), insertions: insertions, committerDate: date)
        }
    }

    /// Read `root`'s history day by day for `from` through `to`, inclusive,
    /// in `zone`: one `DailyCounts` per day, zero-filled, from one `git
    /// log` and one tag listing for the whole range — never one `git log`
    /// per day. The same source and the same rules as `read`: the branch,
    /// the squash/merge subject test, `--shortstat` insertions, and a tag's
    /// creation date; only the bucketing (by committer day instead of
    /// summed) is new. Synchronous; `RepositoryYields` runs it on its queue.
    public static func readDaily(
        root: String, from: DayKey, to: DayKey, zone: TimeZone, git: Git = { run(args: $0) }
    ) -> [DailyCounts] {
        var range: [DayKey] = []
        var cursor = from
        while cursor <= to {
            range.append(cursor)
            cursor = cursor.advanced(by: 1)
        }
        func at(_ args: [String]) -> (status: Int32, output: String)? { git(["-C", root] + args) }
        guard let inside = at(["rev-parse", "--is-inside-work-tree"]), inside.status == 0,
              inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return range.map { DailyCounts(day: $0.description) } }
        let remotes = at(["remote"])
        let remote = remotes?.status == 0 && !(remotes?.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        var branch: String?
        for candidate in branchCandidates {
            if let found = at(["rev-parse", "--verify", "--quiet", candidate]), found.status == 0 {
                branch = candidate == "HEAD" ? "HEAD" : String(candidate.dropFirst("refs/remotes/".count))
                break
            }
        }
        var prsByDay: [String: Int] = [:]
        var linesByDay: [String: Int] = [:]
        let since = Int(firstInstant(of: from, in: zone).timeIntervalSince1970)
        let until = Int(firstInstant(of: to.advanced(by: 1), in: zone).timeIntervalSince1970) - 1
        if remote, let branch, let log = at([
            "log", branch == "HEAD" ? "HEAD" : "refs/remotes/" + branch, "--first-parent", "--diff-merges=first-parent",
            "--shortstat", "--since=@\(since)", "--until=@\(until)",
            "--format=\(separator)%cI\(field)%s",
        ]), log.status == 0 {
            for commit in parseLogWithDate(log.output) where isPullRequest(commit.subject) {
                let day = DayKey(commit.committerDate, in: zone).description
                prsByDay[day, default: 0] += 1
                linesByDay[day, default: 0] += commit.insertions
            }
        }
        var releasesByDay: [String: Int] = [:]
        if let tags = at(["for-each-ref", "refs/tags", "--format=%(creatordate:unix)"]), tags.status == 0 {
            for line in tags.output.split(separator: "\n") {
                guard let seconds = Double(line.trimmingCharacters(in: .whitespaces)) else { continue }
                let day = DayKey(Date(timeIntervalSince1970: seconds), in: zone)
                guard from <= day, day <= to else { continue }
                releasesByDay[day.description, default: 0] += 1
            }
        }
        return range.map { day in
            let key = day.description
            return DailyCounts(
                day: key,
                mergedPullRequests: remote ? (prsByDay[key] ?? 0) : nil,
                mergedLines: remote ? (linesByDay[key] ?? 0) : nil,
                releases: releasesByDay[key] ?? 0
            )
        }
    }
}

/// The yield of every project the daemon knows, behind `GET /api/yield`
/// and `GET /api/yield/daily`.
///
/// ## A request never waits for `git`
///
/// `report` and `dailyReport` answer what the cache holds under the lock
/// (`fleet-first-paint`, capability 2), the way `PullRequestStatus` answers
/// for `gh`. One key is a route, a root and a range. A request claims each
/// key that has no read running and either no answer or an answer
/// `ttlSeconds` old or more, and queues one read on `queue`; a claimed key
/// takes no second read. The answer says `pending` while a read of one of
/// its keys runs, and counts in `unread` the roots it has no figures for.
///
/// ## The midnight roll
///
/// A range that ends today is a new key each day. A root with no answer
/// for the exact range is served from the newest answer of an earlier
/// `to` while the read of the new key runs: for the totals, the answer of
/// the same `from`; for the day-by-day series, an answer that starts at
/// or before `from`, cut to the range, with the days it does not hold
/// absent. `readAt` and `ageSeconds` say how old that answer is. The
/// earlier `to` is at most `fallbackDays` before the asked `to`: after
/// more days with no request the root counts in `unread`.
///
/// ## The file
///
/// The answers are kept in `file` (`yield-cache.json`), so the first
/// request after a restart is served from them. The file is read once in
/// `init` and written on `queue` when the last claimed read ends. At each
/// write the cache drops every answer that no request asked for
/// `keepSeconds`, then keeps the most recently asked ranges per route.
/// A range is kept with every root or dropped with every root, because
/// one request asks every root of its range: the `wholeRanges` newest
/// ranges always stay, and an older range stays while the route holds
/// `maxEntries` answers or fewer. A file that does not decode, or that names another
/// `formatVersion` or another zone (the day bounds depend on the zone),
/// is ignored with one line on stderr and replaced by the next write.
public final class RepositoryYields: @unchecked Sendable {
    public static let ttlSeconds: TimeInterval = 300
    /// An answer that no request asked for this long is dropped at a write.
    public static let keepSeconds: TimeInterval = 48 * 3600
    /// The answers kept per route after a write, the most recently asked
    /// ranges first. The `wholeRanges` newest ranges can exceed it.
    public static let maxEntries = 64
    /// The newest ranges of a route that a write keeps with every root,
    /// whatever `maxEntries` says: one request can list more roots than
    /// `maxEntries`, and a dropped answer of a range that a page asks is
    /// read again at every request. The bound of a route is then the
    /// larger of `maxEntries` and `wholeRanges` times the roots asked.
    public static let wholeRanges = 4
    /// The midnight roll serves an answer whose `to` is at most this many
    /// days before the asked `to`.
    public static let fallbackDays = 7
    public static let formatVersion = 1
    static let queue = DispatchQueue(label: "kitterm.yield", qos: .utility)

    /// One project the page can name: what `GET /api/projects` lists.
    public struct ProjectRef: Equatable, Sendable {
        public var id: String
        public var name: String
        public var root: String
        public var registered: Bool

        public init(id: String, name: String, root: String, registered: Bool) {
            self.id = id
            self.name = name
            self.root = root
            self.registered = registered
        }
    }

    public struct ProjectYield: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var root: String
        public var registered: Bool
        public var yield: RepositoryYield
        /// True when no answer is kept for the root: `yield` then carries
        /// no count. Absent for a root that has figures.
        public var pending: Bool?
    }

    /// The counts summed over the projects that have them, and how many
    /// projects had each.
    public struct Totals: Codable, Equatable, Sendable {
        public var checkouts = 0
        public var counted = 0
        public var mergedPullRequests = 0
        public var mergedLines = 0
        public var releases = 0
    }

    public struct Report: Codable, Equatable, Sendable {
        public var ok = true
        public var from: String
        public var to: String
        public var projects: [ProjectYield]
        public var totals: Totals
        /// A read of one of the listed roots runs for this range.
        public var pending = false
        /// The listed roots with no answer kept. The figures are complete
        /// when it is 0 and `pending` is false: while `pending` is true a
        /// root's figures can be those of an earlier answer.
        public var unread = 0
        /// When the oldest answer served was read, ISO 8601; absent when
        /// no answer is kept.
        public var readAt: String?
        public var ageSeconds: Int?
    }

    /// One project's day in the `GET /api/yield/daily` series, the same
    /// absent-means-no-source rule as `ProjectYield.yield` per day.
    public struct ProjectDay: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var root: String
        public var registered: Bool
        public var mergedPullRequests: Int?
        public var mergedLines: Int?
        public var releases: Int?
    }

    /// One day of the `GET /api/yield/daily` series: every project's own
    /// counts, plus the day's sum over the projects counted (the same
    /// "counted" rule `Totals` sums by — a project with no remote
    /// contributes no pull requests or lines, but its releases).
    public struct Day: Codable, Equatable, Sendable {
        public var day: String
        public var mergedPullRequests = 0
        public var mergedLines = 0
        public var releases = 0
        public var projects: [ProjectDay]
    }

    /// The day-by-day counterpart of `Report`, behind `GET
    /// /api/yield/daily`: one entry per day in the range, zero-filled,
    /// oldest first. `pending`, `unread`, `readAt` and `ageSeconds` read
    /// as on `Report`; an unread root's counts are absent in every day.
    public struct DailyReport: Codable, Equatable, Sendable {
        public var ok = true
        public var from: String
        public var to: String
        public var days: [Day]
        public var pending = false
        public var unread = 0
        public var readAt: String?
        public var ageSeconds: Int?
    }

    private struct Key: Hashable {
        var root: String
        var from: Int
        var to: Int
    }

    /// One key's state: the answer and when its read was asked, the last
    /// request that named the key, and whether a read is claimed.
    private struct Entry<Value> {
        var value: Value?
        var readAt: Date?
        var askedAt: Date
        var running = false
    }

    /// What one key answers a request with.
    private struct Served<Value> {
        var value: Value?
        var readAt: Date?
        /// The key the value was read for; differs from the asked key
        /// after the midnight roll.
        var key: Key
        var running: Bool
        /// The request claimed the key: the caller queues the read.
        var claimed: Bool
    }

    /// One kept answer of the file: the key as `root` and the two day
    /// numbers, the two times in epoch milliseconds.
    private struct FileTotals: Codable {
        var root: String
        var from: Int
        var to: Int
        var readAt: Int64
        var askedAt: Int64
        var yield: RepositoryYield
    }

    private struct FileDaily: Codable {
        var root: String
        var from: Int
        var to: Int
        var readAt: Int64
        var askedAt: Int64
        var days: [RepositoryYield.DailyCounts]
    }

    private struct FileShape: Codable {
        var version: Int
        var zone: String
        var totals: [FileTotals]
        var daily: [FileDaily]
    }

    private let zone: TimeZone
    private let git: RepositoryYield.Git
    private let file: URL?
    private let queue: DispatchQueue
    private let lock = NIOLock()
    private var cache: [Key: Entry<RepositoryYield>] = [:]
    private var dailyCache: [Key: Entry<[RepositoryYield.DailyCounts]>] = [:]
    /// The reads claimed and not ended, over both routes.
    private var running = 0

    /// `file` is where the answers are kept across a restart, nil for
    /// none; `queue` is where the reads and the write run, a test passes
    /// its own so a stub that blocks holds no other test.
    public init(
        zone: TimeZone = .current,
        file: URL? = nil,
        queue: DispatchQueue? = nil,
        git: @escaping RepositoryYield.Git = { RepositoryYield.run(args: $0) }
    ) {
        self.zone = zone
        self.git = git
        self.file = file
        self.queue = queue ?? Self.queue
        if let file, let shape = Self.load(file, zone: zone) {
            for item in shape.totals {
                cache[Key(root: item.root, from: item.from, to: item.to)] = Entry(
                    value: item.yield, readAt: Self.date(item.readAt), askedAt: Self.date(item.askedAt)
                )
            }
            for item in shape.daily {
                dailyCache[Key(root: item.root, from: item.from, to: item.to)] = Entry(
                    value: item.days, readAt: Self.date(item.readAt), askedAt: Self.date(item.askedAt)
                )
            }
        }
    }

    /// The report for `projects` over the range, from what is kept; it
    /// never runs `git`. Each root whose answer is absent or `ttlSeconds`
    /// old gets one read on the queue.
    public func report(projects: [ProjectRef], from: DayKey, to: DayKey, now: Date = Date()) -> Report {
        let served: [Served<RepositoryYield>] = lock.withLock {
            projects.map { project in
                Self.serve(&cache, key: Key(root: project.root, from: from.number, to: to.number), now: now) {
                    $0.from == from.number
                }
            }
        }
        var items: [ProjectYield] = []
        var totals = Totals()
        for (project, answer) in zip(projects, served) {
            if answer.claimed {
                let key = Key(root: project.root, from: from.number, to: to.number)
                startRead(now: now) {
                    let value = RepositoryYield.read(root: key.root, from: from, to: to, zone: self.zone, git: self.git)
                    self.lock.withLock { Self.keep(&self.cache, key: key, value: value, at: now) }
                }
            }
            let yield = answer.value ?? .none
            items.append(ProjectYield(
                id: project.id, name: project.name, root: project.root, registered: project.registered,
                yield: yield, pending: answer.value == nil ? true : nil
            ))
            if yield.checkout { totals.checkouts += 1 }
            if let prs = yield.mergedPullRequests, let lines = yield.mergedLines {
                totals.counted += 1
                totals.mergedPullRequests += prs
                totals.mergedLines += lines
            }
            totals.releases += yield.releases ?? 0
        }
        let oldest = served.compactMap { $0.value == nil ? nil : $0.readAt }.min()
        return Report(
            from: from.description, to: to.description, projects: items, totals: totals,
            pending: served.contains { $0.running }, unread: served.filter { $0.value == nil }.count,
            readAt: oldest.map(Self.iso), ageSeconds: oldest.map { max(0, Int(now.timeIntervalSince($0))) }
        )
    }

    /// The day-by-day report for `projects` over the range, from what is
    /// kept; it never runs `git`. The series has its own cache, so a
    /// caller of one route never pays for the other's read: one `git log`
    /// per root per range (`RepositoryYield.readDaily`), never one per day.
    public func dailyReport(projects: [ProjectRef], from: DayKey, to: DayKey, now: Date = Date()) -> DailyReport {
        var range: [DayKey] = []
        var cursor = from
        while cursor <= to {
            range.append(cursor)
            cursor = cursor.advanced(by: 1)
        }
        let served: [Served<[RepositoryYield.DailyCounts]>] = lock.withLock {
            projects.map { project in
                Self.serve(&dailyCache, key: Key(root: project.root, from: from.number, to: to.number), now: now) {
                    $0.from <= from.number && $0.to >= from.number
                }
            }
        }
        for (project, answer) in zip(projects, served) where answer.claimed {
            let key = Key(root: project.root, from: from.number, to: to.number)
            startRead(now: now) {
                let value = RepositoryYield.readDaily(root: key.root, from: from, to: to, zone: self.zone, git: self.git)
                self.lock.withLock { Self.keep(&self.dailyCache, key: key, value: value, at: now) }
            }
        }
        let days: [Day] = range.enumerated().map { index, day in
            var result = Day(day: day.description, projects: [])
            for (project, answer) in zip(projects, served) {
                // A series read for an earlier range starts `offset` days
                // before `from` and may end before `to`.
                let at = index + (from.number - answer.key.from)
                let counts = answer.value.flatMap { $0.indices.contains(at) ? $0[at] : nil }
                    ?? RepositoryYield.DailyCounts(day: day.description)
                result.projects.append(ProjectDay(
                    id: project.id, name: project.name, root: project.root, registered: project.registered,
                    mergedPullRequests: counts.mergedPullRequests, mergedLines: counts.mergedLines, releases: counts.releases
                ))
                if let prs = counts.mergedPullRequests, let lines = counts.mergedLines {
                    result.mergedPullRequests += prs
                    result.mergedLines += lines
                }
                result.releases += counts.releases ?? 0
            }
            return result
        }
        let oldest = served.compactMap { $0.value == nil ? nil : $0.readAt }.min()
        return DailyReport(
            from: from.description, to: to.description, days: days,
            pending: served.contains { $0.running }, unread: served.filter { $0.value == nil }.count,
            readAt: oldest.map(Self.iso), ageSeconds: oldest.map { max(0, Int(now.timeIntervalSince($0))) }
        )
    }

    // MARK: - the cache

    /// What `key` answers at `now`, and the claim of its read when one is
    /// due. Caller holds `lock`. Without an answer for `key` itself, the
    /// newest answer of the same root with an earlier `to` that `earlier`
    /// accepts is served in its place, when that `to` is at most
    /// `fallbackDays` before the asked one.
    private static func serve<Value>(
        _ cache: inout [Key: Entry<Value>], key: Key, now: Date, earlier: (Key) -> Bool
    ) -> Served<Value> {
        var entry = cache[key] ?? Entry(askedAt: now)
        entry.askedAt = now
        var claimed = false
        if !entry.running, entry.readAt.map({ now.timeIntervalSince($0) >= ttlSeconds }) ?? true {
            entry.running = true
            claimed = true
        }
        cache[key] = entry
        if entry.value != nil {
            return Served(value: entry.value, readAt: entry.readAt, key: key, running: entry.running, claimed: claimed)
        }
        let fallback = cache
            .filter {
                $0.key.root == key.root && $0.key.to < key.to && key.to - $0.key.to <= fallbackDays
                    && $0.value.value != nil && earlier($0.key)
            }
            .max { $0.key.to < $1.key.to }
        return Served(
            value: fallback?.value.value, readAt: fallback?.value.readAt, key: fallback?.key ?? key,
            running: entry.running, claimed: claimed
        )
    }

    /// Keep `value` as the answer of `key`, read at `at`, and end its
    /// claim. Caller holds `lock`.
    private static func keep<Value>(_ cache: inout [Key: Entry<Value>], key: Key, value: Value, at: Date) {
        var entry = cache[key] ?? Entry(askedAt: at)
        entry.value = value
        entry.readAt = at
        entry.running = false
        cache[key] = entry
    }

    /// Queue the read a request claimed at `now`: `read` runs `git` and
    /// keeps the answer. The file is written when no claimed read is left.
    private func startRead(now: Date, read: @escaping @Sendable () -> Void) {
        lock.withLock { running += 1 }
        queue.async {
            read()
            let idle: Bool = self.lock.withLock {
                self.running -= 1
                return self.running == 0
            }
            if idle { self.save(now: now) }
        }
    }

    // MARK: - the file

    private static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
    private static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Drop the answers nobody asked for `keepSeconds`, then the least
    /// recently asked ranges. A range is the `from` and the `to` of a key,
    /// asked when its newest answer was asked; it stays or goes with every
    /// root. The `wholeRanges` newest ranges stay; an older range stays
    /// while the kept answers number `maxEntries` or fewer. A key with a
    /// read claimed stays.
    private static func prune<Value>(_ cache: inout [Key: Entry<Value>], now: Date) {
        cache = cache.filter { $0.value.running || now.timeIntervalSince($0.value.askedAt) < keepSeconds }
        guard cache.count > maxEntries else { return }
        // A range is a key with no root.
        var asked: [Key: Date] = [:]
        var sizes: [Key: Int] = [:]
        for (key, entry) in cache {
            let range = Key(root: "", from: key.from, to: key.to)
            asked[range] = max(asked[range] ?? entry.askedAt, entry.askedAt)
            sizes[range, default: 0] += 1
        }
        let newestFirst = asked.sorted { ($0.value, $0.key.to, $0.key.from) > ($1.value, $1.key.to, $1.key.from) }
        var kept: Set<Key> = []
        var total = 0
        for (index, item) in newestFirst.enumerated() {
            let size = sizes[item.key] ?? 0
            guard index < wholeRanges || total + size <= maxEntries else { break }
            kept.insert(item.key)
            total += size
        }
        cache = cache.filter { $0.value.running || kept.contains(Key(root: "", from: $0.key.from, to: $0.key.to)) }
    }

    /// Prune, then replace the file. Runs on `queue`.
    private func save(now: Date) {
        guard let file else {
            lock.withLock {
                Self.prune(&cache, now: now)
                Self.prune(&dailyCache, now: now)
            }
            return
        }
        let shape: FileShape = lock.withLock {
            Self.prune(&cache, now: now)
            Self.prune(&dailyCache, now: now)
            let totals: [FileTotals] = cache.compactMap { key, entry in
                guard let value = entry.value, let readAt = entry.readAt else { return nil }
                return FileTotals(
                    root: key.root, from: key.from, to: key.to,
                    readAt: Self.milliseconds(readAt), askedAt: Self.milliseconds(entry.askedAt), yield: value
                )
            }
            let daily: [FileDaily] = dailyCache.compactMap { key, entry in
                guard let value = entry.value, let readAt = entry.readAt else { return nil }
                return FileDaily(
                    root: key.root, from: key.from, to: key.to,
                    readAt: Self.milliseconds(readAt), askedAt: Self.milliseconds(entry.askedAt), days: value
                )
            }
            return FileShape(
                version: Self.formatVersion, zone: zone.identifier,
                totals: totals.sorted { ($0.root, $0.from, $0.to) < ($1.root, $1.from, $1.to) },
                daily: daily.sorted { ($0.root, $0.from, $0.to) < ($1.root, $1.from, $1.to) }
            )
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(shape).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            FileHandle.standardError.write(Data("kitterm: could not write \(file.path): \(error)\n".utf8))
        }
    }

    /// The file's answers; nil when the file is absent, does not decode,
    /// or names another format version or another zone.
    private static func load(_ file: URL, zone: TimeZone) -> FileShape? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        func ignore(_ why: String) -> FileShape? {
            FileHandle.standardError.write(Data("kitterm: ignoring \(file.path): \(why)\n".utf8))
            return nil
        }
        do {
            let shape = try JSONDecoder().decode(FileShape.self, from: data)
            guard shape.version == formatVersion else {
                return ignore("format version \(shape.version), expected \(formatVersion)")
            }
            guard shape.zone == zone.identifier else {
                return ignore("read in the zone \(shape.zone), the daemon counts in \(zone.identifier)")
            }
            return shape
        } catch {
            return ignore("\(error)")
        }
    }
}
