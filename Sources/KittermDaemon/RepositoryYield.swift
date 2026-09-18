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
///   is by committer date, which is when the merge happened.
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

    public init(
        checkout: Bool, remote: Bool, branch: String? = nil,
        mergedPullRequests: Int? = nil, mergedLines: Int? = nil, releases: Int? = nil
    ) {
        self.checkout = checkout
        self.remote = remote
        self.branch = branch
        self.mergedPullRequests = mergedPullRequests
        self.mergedLines = mergedLines
        self.releases = releases
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
        if remote, let branch, let log = at([
            "log", branch == "HEAD" ? "HEAD" : "refs/remotes/" + branch, "--first-parent", "--diff-merges=first-parent",
            "--shortstat", "--since=\(from.description)T00:00:00", "--until=\(to.description)T23:59:59",
            "--format=\(separator)%H\(field)%s",
        ]), log.status == 0 {
            let merged = parseLog(log.output).filter { isPullRequest($0.subject) }
            yield.mergedPullRequests = merged.count
            yield.mergedLines = merged.reduce(0) { $0 + $1.insertions }
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
}

/// The yield of every project the daemon knows, behind `GET /api/yield`.
/// Reads run on `queue`, never on the event loop, and an answer is kept for
/// `ttlSeconds` per root and range, the rollup's own refresh interval, so
/// a page that polls every thirty seconds costs one `git log` per project
/// every five minutes.
public final class RepositoryYields: @unchecked Sendable {
    public static let ttlSeconds: TimeInterval = 300
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
    }

    private struct Key: Hashable {
        var root: String
        var from: Int
        var to: Int
    }

    private let zone: TimeZone
    private let git: RepositoryYield.Git
    private let lock = NIOLock()
    private var cache: [Key: (at: Date, yield: RepositoryYield)] = [:]

    public init(zone: TimeZone = .current, git: @escaping RepositoryYield.Git = { RepositoryYield.run(args: $0) }) {
        self.zone = zone
        self.git = git
    }

    /// The report for `projects` over the range, reading each root whose
    /// answer is older than `ttlSeconds` or not kept. Synchronous; the route
    /// calls it on `queue`.
    public func report(projects: [ProjectRef], from: DayKey, to: DayKey, now: Date = Date()) -> Report {
        var items: [ProjectYield] = []
        var totals = Totals()
        for project in projects {
            let key = Key(root: project.root, from: from.number, to: to.number)
            let kept = lock.withLock { cache[key] }
            let yield: RepositoryYield
            if let kept, now.timeIntervalSince(kept.at) < Self.ttlSeconds {
                yield = kept.yield
            } else {
                yield = RepositoryYield.read(root: project.root, from: from, to: to, zone: zone, git: git)
                lock.withLock { cache[key] = (now, yield) }
            }
            items.append(ProjectYield(id: project.id, name: project.name, root: project.root, registered: project.registered, yield: yield))
            if yield.checkout { totals.checkouts += 1 }
            if let prs = yield.mergedPullRequests, let lines = yield.mergedLines {
                totals.counted += 1
                totals.mergedPullRequests += prs
                totals.mergedLines += lines
            }
            totals.releases += yield.releases ?? 0
        }
        return Report(from: from.description, to: to.description, projects: items, totals: totals)
    }
}
