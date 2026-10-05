import Foundation
import NIOConcurrencyHelpers

/// The pull requests of each GitHub repository a project's `origin` names,
/// read with `gh pr list` (`sessions-workflow` round 2) and served by
/// `GET /api/projects/<id>/pulls`. `gh` and the human's own `gh` login are
/// the only source: no token file, no REST client.
///
/// Every `gh` runs on `queue`, never on the event loop, with a timeout. A
/// request reads `snapshot` under the lock and calls `refreshIfDue`, which
/// starts at most one read per repository per `refreshSeconds`; no request
/// waits for `gh`. A read that fails keeps the last good list with its
/// `readAt` and adds the reason.
public final class PullRequestStatus: @unchecked Sendable {
    public static let refreshSeconds: TimeInterval = 60
    public static let timeoutSeconds: TimeInterval = 20
    public static let limit = 50
    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "kitterm.pulls", qos: .utility)
        queue.setSpecific(key: queueKey, value: true)
        return queue
    }()
    /// Set on `queue` alone, so a test can tell where a `gh` ran.
    static let queueKey = DispatchSpecificKey<Bool>()

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

    /// Runs the executable at a path with arguments; nil when it cannot start.
    public typealias Runner = @Sendable (_ executable: String, _ args: [String]) -> RunResult?

    private struct Entry {
        var snapshot = Snapshot(reason: PullRequestStatus.notReadReason)
        var attemptedAt: Date?
        var reading = false
    }

    private let searchPath: String
    private let run: Runner
    private let lock = NIOLock()
    private var cache: [String: Entry] = [:]

    /// `searchPath` is where `gh` is looked for, in `PATH` form. The default
    /// is the daemon's `PATH`, then the directories a `gh` is installed in:
    /// launchd starts the service with `/usr/bin:/bin:/usr/sbin:/sbin`.
    public init(searchPath: String = PullRequestStatus.defaultSearchPath, run: Runner? = nil) {
        self.searchPath = searchPath
        self.run = run ?? { executable, args in
            PullRequestStatus.run(
                executable: executable, args: args, searchPath: searchPath, timeout: PullRequestStatus.timeoutSeconds
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
    /// one started `refreshSeconds` ago or more. True when a read started.
    @discardableResult
    public func refreshIfDue(repository: String, now: Date = Date()) -> Bool {
        let due: Bool = lock.withLock {
            var entry = cache[repository] ?? Entry()
            if entry.reading { return false }
            if let last = entry.attemptedAt, now.timeIntervalSince(last) < Self.refreshSeconds { return false }
            entry.attemptedAt = now
            entry.reading = true
            cache[repository] = entry
            return true
        }
        guard due else { return false }
        Self.queue.async { self.read(repository: repository) }
        return true
    }

    /// One read, on `queue`: `gh pr list`, and `gh auth status` only after
    /// a list that failed, to say which failure it was.
    private func read(repository: String) {
        let outcome = Self.fetch(repository: repository, searchPath: searchPath, run: run)
        lock.withLock {
            var entry = cache[repository] ?? Entry()
            entry.reading = false
            switch outcome {
            case .success(let pulls):
                entry.snapshot = Snapshot(pulls: pulls, readAt: Date(), reason: nil)
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
        guard let list = run(gh, listArguments(repository: repository)) else {
            return .failure(Failure(reason: "gh did not start"))
        }
        if list.timedOut {
            return .failure(Failure(reason: "gh pr list timed out after \(Int(timeoutSeconds)) s"))
        }
        guard list.status == 0 else {
            if let auth = run(gh, ["auth", "status"]), !auth.timedOut, auth.status != 0 {
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

    /// The first executable file named `name` in the directories of `searchPath`.
    static func locate(_ name: String, in searchPath: String) -> String? {
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
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
    /// when it cannot start. Both pipes are read while it runs, so a long
    /// answer cannot fill one and hang; `timeout` ends the process, and the
    /// wait for the pipes is bounded too, for a child that keeps one open.
    public static func run(executable: String, args: [String], searchPath: String, timeout: TimeInterval) -> RunResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let collected = Collected()
        let readers = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: readers) {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            collected.lock.withLock { collected.output = data }
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            let data = error.fileHandleForReading.readDataToEndOfFile()
            collected.lock.withLock { collected.error = data }
        }
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            collected.lock.withLock { collected.timedOut = true }
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        _ = readers.wait(timeout: .now() + 2)
        return collected.lock.withLock {
            RunResult(
                status: process.terminationStatus, output: collected.output,
                error: String(decoding: collected.error, as: UTF8.self), timedOut: collected.timedOut
            )
        }
    }

    private final class Collected: @unchecked Sendable {
        let lock = NIOLock()
        var output = Data()
        var error = Data()
        var timedOut = false
    }
}
