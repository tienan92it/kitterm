import Foundation
import NIOConcurrencyHelpers

/// The knowledge package of each registered project as its merged base
/// branch holds it (`sessions-workflow` round 3). Nobody pulls the main
/// checkout after a merge, so the working tree shows an old `STATE.md`;
/// `origin/<base>` after a fetch shows the merged one.
///
/// One read per root, on `queue`, never on the event loop: `git fetch` of
/// the base branch, then the summaries from the commit's tree through git
/// objects (`ls-tree`, `cat-file --batch`), with no checkout. The daemon
/// writes no working tree, no index and no `HEAD`: a fetch updates
/// remote-tracking refs only. A request reads `snapshot` under the lock and
/// calls `refreshIfDue`, which starts a read when none runs and the last
/// one ended `refreshSeconds` ago or more, so no request waits for a fetch.
///
/// The tree reader keeps the rules of `KnowledgeFile`: the same slug rule,
/// the same `maxGoalFolders` and `maxBytes` caps, and an entry of mode
/// 120000 (a symlink) or 160000 (a submodule) is refused and skipped like a
/// symlink on disk. Only the knowledge directory is listed, and only an
/// object that listing names is read.
///
/// A fetch that fails keeps reading the `origin/<base>` the checkout
/// already holds, and the snapshot's reason names the failure and the last
/// good fetch. With no `origin`, a refused base name, no local
/// `origin/<base>` or no knowledge directory on the base, the snapshot
/// holds no summaries and the reason; the routes then read the working
/// tree as before.
///
/// The base name comes from the remote, so it is data: a name that starts
/// with `-` or fails `git check-ref-format --branch` is refused before any
/// fetch, and the fetch names the branch only inside a full refspec after
/// `--`, never as a bare argument.
public final class KnowledgeBase: @unchecked Sendable {
    public static let refreshSeconds: TimeInterval = 60
    public static let timeoutSeconds: TimeInterval = 20
    /// The blobs one read may hold together. A package over it is read from
    /// the working tree, with the reason.
    static let maxPackageBytes = 64 << 20
    static let maxListingBytes = 8 << 20
    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "kitterm.knowledge-base", qos: .utility)
        queue.setSpecific(key: queueMark.key, value: true)
        return queue
    }()
    /// The key `queue` alone carries, boxed because corelibs Dispatch does
    /// not mark the key `Sendable`.
    private final class QueueMark: @unchecked Sendable {
        let key = DispatchSpecificKey<Bool>()
    }
    private static let queueMark = QueueMark()
    /// True on `queue`, so a test can tell where a fetch ran.
    static var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueMark.key) == true }

    public static let workingTree = "working tree"
    public static let notReadReason = "not read yet"
    public static let absentReason = "git is not on PATH"
    public static let noRemoteReason = "no origin remote"

    /// One entry of the knowledge directory's tree.
    struct Entry: Equatable, Sendable {
        var mode: String
        var oid: String
        /// The blob's size; nil for a tree or a submodule.
        var size: Int?

        var isDirectory: Bool { mode == "040000" }
        var isSymlink: Bool { mode == "120000" }
        /// A regular file. A symlink is a blob too, with mode 120000.
        var isFile: Bool { mode == "100644" || mode == "100755" }
    }

    /// The knowledge directory of one commit: every entry under it by its
    /// path relative to the directory, and the names in each directory
    /// (`""` is the knowledge directory itself).
    struct Tree: Equatable, Sendable {
        var entries: [String: Entry] = [:]
        var children: [String: [String]] = [:]
    }

    /// What the cache holds for one root: the summaries of `source`
    /// (`origin/main`), or none and why. With summaries, `reason` is set
    /// only when the latest fetch failed and the local ref was read.
    public struct Snapshot: Equatable, Sendable {
        public var source: String?
        public var goals: [KnowledgeSummary]?
        public var reason: String?
        /// The commit the summaries came from.
        public var commit: String?
        var tree: Tree?
    }

    /// Runs `git` at `executable`; nil when it cannot start. `input` is its
    /// stdin, `maxOutput` the stdout bytes kept.
    public typealias Git = @Sendable (_ executable: String, _ args: [String], _ input: Data?, _ maxOutput: Int)
        -> PullRequestStatus.RunResult?

    private struct Record {
        var snapshot = Snapshot(reason: KnowledgeBase.notReadReason)
        var listing: Data?
        /// The end of the last fetch that succeeded.
        var fetchedAt: Date?
        var endedAt: Date?
        var reading = false
    }

    private let searchPath: String
    private let git: Git
    private let clock: @Sendable () -> Date
    private let lock = NIOLock()
    private var cache: [String: Record] = [:]

    public init(
        searchPath: String = PullRequestStatus.defaultSearchPath, git: Git? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.searchPath = searchPath
        self.clock = clock
        self.git = git ?? { executable, args, input, maxOutput in
            KnowledgeBase.run(
                executable: executable, args: args, input: input, maxOutput: maxOutput, searchPath: searchPath
            )
        }
    }

    /// What every `git` here runs under, laid over the daemon's own
    /// environment. Nothing may ask a human: no terminal prompt, an askpass
    /// that answers nothing, and `ssh` in batch mode. `GIT_SSH_COMMAND` is
    /// replaced, not kept: the daemon's fetch must never wait on a
    /// passphrase, and a fetch that needs the human's own ssh command fails
    /// with its exit code and reads the local ref. Replace refs are off, so
    /// an object id reads the object it names. A pathspec is literal, so a
    /// knowledge directory named with `*` matches itself alone.
    static let environment = [
        "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "true", "GIT_SSH_COMMAND": "ssh -oBatchMode=yes",
        "GIT_NO_REPLACE_OBJECTS": "1", "GIT_LITERAL_PATHSPECS": "1",
    ]

    /// One `git` through the runner of `PullRequestStatus`: its own process
    /// group, a timeout, `environment`.
    public static func run(
        executable: String, args: [String], input: Data?, maxOutput: Int, searchPath: String,
        timeout: TimeInterval = KnowledgeBase.timeoutSeconds
    ) -> PullRequestStatus.RunResult? {
        PullRequestStatus.run(
            executable: executable, args: args, searchPath: searchPath, timeout: timeout,
            input: input, environment: environment, maxOutput: maxOutput
        )
    }

    private static func key(_ root: String, _ knowledge: String) -> String { root + "\0" + knowledge }

    /// What the cache holds for `root`, under the lock alone.
    public func snapshot(root: String, knowledge: String) -> Snapshot {
        lock.withLock { cache[Self.key(root, knowledge)]?.snapshot ?? Snapshot(reason: Self.notReadReason) }
    }

    /// Start one read of `root` on `queue` when none runs and the last one
    /// ended `refreshSeconds` ago or more. True when a read started.
    @discardableResult
    public func refreshIfDue(root: String, knowledge: String) -> Bool {
        let now = clock()
        let key = Self.key(root, knowledge)
        let due: Bool = lock.withLock {
            var record = cache[key] ?? Record()
            if record.reading { return false }
            if let last = record.endedAt, now.timeIntervalSince(last) < Self.refreshSeconds { return false }
            record.reading = true
            cache[key] = record
            return true
        }
        guard due else { return false }
        Self.queue.async { self.refresh(root: root, knowledge: knowledge) }
        return true
    }

    /// One read, on `queue`. The minute counts from its end.
    private func refresh(root: String, knowledge: String) {
        let key = Self.key(root, knowledge)
        let before = lock.withLock { cache[key] }
        let known = before.flatMap { $0.snapshot.goals == nil ? nil : (listing: $0.listing, snapshot: $0.snapshot) }
        let outcome = read(root: root, knowledge: knowledge, known: known, fetchedAt: before?.fetchedAt)
        let ended = clock()
        lock.withLock {
            var record = cache[key] ?? Record()
            record.reading = false
            record.endedAt = ended
            record.snapshot = outcome.snapshot
            record.listing = outcome.snapshot.goals == nil ? nil : outcome.listing
            if outcome.fetched { record.fetchedAt = ended }
            cache[key] = record
        }
    }

    /// The end of one read: the snapshot, the listing its summaries came
    /// from, and whether the fetch succeeded.
    private struct Outcome {
        var snapshot: Snapshot
        var listing: Data?
        var fetched = false

        static func none(_ reason: String, fetched: Bool = false) -> Outcome {
            Outcome(snapshot: Snapshot(reason: reason), fetched: fetched)
        }
    }

    /// The options of the fetch come first and the branch comes last,
    /// inside a full refspec after `--`, so no name from the remote is read
    /// as an option. The refspec writes `origin/<base>` in a single-branch
    /// clone too. No `FETCH_HEAD` is written, so the human's own stays; no
    /// tag, no submodule, no gc and no maintenance run.
    static func fetchArguments(root: String, base: String) -> [String] {
        [
            "-C", root, "-c", "gc.auto=0", "-c", "maintenance.auto=false",
            "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules",
            "--", "origin", "+refs/heads/\(base):refs/remotes/origin/\(base)",
        ]
    }

    /// A time as `2026-10-05T09:20:00Z`. A formatter per call: it is not
    /// `Sendable`, and only a failed fetch asks.
    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Fetch the base branch of `root` and build the summaries of its
    /// knowledge directory from `origin/<base>`. A fetch that fails reads
    /// the `origin/<base>` already here and says so. `known` is the last
    /// good read: a listing equal to its listing keeps its summaries, so an
    /// unchanged package costs no object read. Synchronous.
    private func read(
        root: String, knowledge: String, known: (listing: Data?, snapshot: Snapshot)?, fetchedAt: Date?
    ) -> Outcome {
        guard let executable = PullRequestStatus.locate("git", in: searchPath) else {
            return .none(Self.absentReason)
        }
        func run(_ args: [String], input: Data? = nil, maxOutput: Int = 64 << 10) -> PullRequestStatus.RunResult? {
            git(executable, ["-C", root] + args, input, maxOutput)
        }
        func word(_ result: PullRequestStatus.RunResult?) -> String? {
            guard let result, !result.timedOut, result.status == 0 else { return nil }
            let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let path = knowledge.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
        guard !path.isEmpty else {
            return .none("the knowledge directory is the project root")
        }
        guard word(run(["remote", "get-url", "origin"])) != nil else {
            return .none(Self.noRemoteReason)
        }
        // What `origin/HEAD` names, else `main`, else `master`.
        var base = "main"
        if let head = word(run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])), head.hasPrefix("origin/") {
            base = String(head.dropFirst("origin/".count))
        } else if word(run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"])) == nil,
                  word(run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/master"])) != nil {
            base = "master"
        }
        // The remote chose this name. A name git would read as an option,
        // or would not take as a branch, reaches no other command.
        guard !base.hasPrefix("-"), word(run(["check-ref-format", "--branch", base])) == base else {
            return .none("the base branch name is refused: " + String(base.prefix(100)))
        }
        let source = "origin/" + base

        // The exit code alone: the stderr of a fetch can hold the remote's
        // URL with a credential in it, and the route answers at watch grade.
        var failed: String?
        if let fetch = git(executable, Self.fetchArguments(root: root, base: base), nil, 0) {
            if fetch.timedOut {
                failed = "git fetch timed out after \(Int(Self.timeoutSeconds)) s"
            } else if fetch.status != 0 {
                failed = "git fetch exited \(fetch.status)"
            }
        } else {
            failed = "git did not start"
        }
        let fetched = failed == nil
        guard let commit = word(run(["rev-parse", "--verify", "--quiet", "refs/remotes/\(source)^{commit}"])),
              Self.isObjectID(commit)
        else {
            return .none(failed.map { "\($0); no local \(source)" } ?? "\(source) is missing", fetched: fetched)
        }
        // The local ref is read after a failed fetch, with what failed and
        // how old the ref is.
        let note = failed.map { failure in
            failure + (fetchedAt.map { "; last good fetch " + Self.stamp($0) } ?? "; no good fetch yet")
        }
        guard let listed = run(["ls-tree", "-r", "-t", "-l", "-z", commit, "--", path], maxOutput: Self.maxListingBytes),
              !listed.timedOut, listed.status == 0, listed.output.count < Self.maxListingBytes
        else {
            return .none("git ls-tree of \(source) failed", fetched: fetched)
        }
        if let known, known.listing == listed.output, known.snapshot.source == source {
            var snapshot = known.snapshot
            snapshot.commit = commit
            snapshot.reason = note
            return Outcome(snapshot: snapshot, listing: listed.output, fetched: fetched)
        }
        guard let tree = Self.tree(listing: listed.output, knowledge: path) else {
            return .none("no \(path) directory on \(source)", fetched: fetched)
        }

        let plan = Self.goalFolders(tree)
        let wanted = Set(plan.flatMap(\.blobs))
        var total = 0
        for file in wanted { total += tree.entries[file]?.size ?? 0 }
        guard total <= Self.maxPackageBytes else {
            return .none("\(path) on \(source) is over \(Self.maxPackageBytes >> 20) MiB", fetched: fetched)
        }
        var texts: [String: String] = [:]
        if !wanted.isEmpty {
            let oids = Set(wanted.compactMap { tree.entries[$0]?.oid })
            let input = Data(oids.sorted().joined(separator: "\n").utf8 + [0x0a])
            guard let batch = run(["cat-file", "--batch"], input: input, maxOutput: total + oids.count * 128 + 1024),
                  !batch.timedOut, batch.status == 0
            else {
                return .none("git cat-file of \(source) failed", fetched: fetched)
            }
            let blobs = Self.blobs(batch: batch.output)
            for file in wanted {
                guard let oid = tree.entries[file]?.oid, let data = blobs[oid] else { continue }
                texts[file] = String(data: data, encoding: .utf8)
            }
        }
        var goals: [KnowledgeSummary] = []
        for folder in plan {
            var summary = KnowledgeFile.assemble(
                state: texts[folder.name + "/STATE.md"], goal: texts[folder.name + "/goal.md"],
                roundNames: folder.roundNames
            ) { texts[folder.name + "/rounds/" + $0] }
            summary.slug = folder.name
            summary.lastRecord = summary.lastRecord.map { folder.name + "/" + $0 }
            goals.append(summary)
        }
        goals.sort(by: KnowledgeSummary.isOrderedBefore)
        let snapshot = Snapshot(source: source, goals: goals, reason: note, commit: commit, tree: tree)
        return Outcome(snapshot: snapshot, listing: listed.output, fetched: fetched)
    }

    // MARK: - the tree

    static func isObjectID(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy { $0.isHexDigit }
    }

    /// The tree of `git ls-tree -r -t -l -z <commit> -- <knowledge>`, or nil
    /// when the knowledge path is not a directory there (missing, a file, a
    /// symlink, a submodule). An entry is
    /// `<mode> <type> <oid> <size>\t<path>\0`; a path outside the knowledge
    /// directory, the ancestors `-t` prints included, is dropped.
    static func tree(listing: Data, knowledge: String) -> Tree? {
        var tree = Tree()
        var isDirectory = false
        for record in listing.split(separator: 0) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            guard fields.count == 4, isObjectID(String(fields[2])) else { continue }
            let entry = Entry(mode: String(fields[0]), oid: String(fields[2]), size: Int(fields[3]))
            if path == knowledge {
                isDirectory = entry.isDirectory
                continue
            }
            guard path.hasPrefix(knowledge + "/") else { continue }
            let relative = String(path.dropFirst(knowledge.count + 1))
            tree.entries[relative] = entry
            let cut = relative.lastIndex(of: "/")
            let parent = cut.map { String(relative[..<$0]) } ?? ""
            let name = cut.map { String(relative[relative.index(after: $0)...]) } ?? relative
            tree.children[parent, default: []].append(name)
        }
        return isDirectory ? tree : nil
    }

    /// One goal folder of a tree: its name, the names under its `rounds/`,
    /// and the paths of the blobs its summary reads.
    struct GoalFolder: Equatable {
        var name: String
        var roundNames: [String] = []
        var blobs: [String] = []
    }

    /// The goal folders of `tree`, by `KnowledgeFile.summaries`' rules: the
    /// first `maxGoalFolders` slug names in name order, then each must be a
    /// directory with a regular `STATE.md`. A symlink or a submodule at the
    /// folder, at `STATE.md`, at `goal.md`, at `rounds` or at a record is
    /// not read. A blob over `maxBytes` is not read either, which leaves
    /// its text absent as on disk.
    static func goalFolders(_ tree: Tree) -> [GoalFolder] {
        func readable(_ path: String) -> Bool {
            guard let entry = tree.entries[path], entry.isFile, let size = entry.size else { return false }
            return size <= KnowledgeFile.maxBytes
        }
        let names = (tree.children[""] ?? []).filter(ProjectStore.isValidID).sorted().prefix(KnowledgeFile.maxGoalFolders)
        var folders: [GoalFolder] = []
        for name in names {
            guard tree.entries[name]?.isDirectory == true, tree.entries[name + "/STATE.md"]?.isFile == true
            else { continue }
            var folder = GoalFolder(name: name)
            for file in ["STATE.md", "goal.md"] where readable(name + "/" + file) {
                folder.blobs.append(name + "/" + file)
            }
            if tree.entries[name + "/rounds"]?.isDirectory == true {
                folder.roundNames = tree.children[name + "/rounds"] ?? []
                for round in folder.roundNames
                where KnowledgeSummary.roundNumber(round) != nil && readable(name + "/rounds/" + round) {
                    folder.blobs.append(name + "/rounds/" + round)
                }
            }
            folders.append(folder)
        }
        return folders
    }

    /// The blobs of a `git cat-file --batch` output by object id. An object
    /// is `<oid> <type> <size>\n<bytes>\n`; a missing one is
    /// `<oid> missing\n`. A cut output yields the objects before the cut.
    static func blobs(batch: Data) -> [String: Data] {
        var blobs: [String: Data] = [:]
        var index = batch.startIndex
        while index < batch.endIndex, let newline = batch[index...].firstIndex(of: 0x0a) {
            let header = String(decoding: batch[index..<newline], as: UTF8.self).split(separator: " ")
            index = batch.index(after: newline)
            guard header.count == 3, let size = Int(header[2]), size >= 0 else { continue }
            guard batch.distance(from: index, to: batch.endIndex) >= size else { break }
            let end = batch.index(index, offsetBy: size)
            if header[1] == "blob" { blobs[String(header[0])] = Data(batch[index..<end]) }
            index = end < batch.endIndex ? batch.index(after: end) : end
        }
        return blobs
    }

    // MARK: - one file

    /// The file at `path` under the knowledge directory of the commit the
    /// summaries came from, or nil when the cache holds no such commit and
    /// the caller reads the working tree. The jail is `KnowledgeFile.read`'s:
    /// a symlink anywhere in the chain is `refused`, a directory, a
    /// submodule or a missing file is `notFound`, a file over `maxBytes` is
    /// `tooLarge`. The blob is read by the object id the cached listing
    /// names, so nothing outside the knowledge directory is reachable. One
    /// local `git cat-file`, no fetch; synchronous, off the loop.
    func file(root: String, knowledge: String, path: String) throws -> KnowledgeFile.Payload? {
        guard let tree = snapshot(root: root, knowledge: knowledge).tree else { return nil }
        guard KnowledgeFile.isValidRelative(path) else { throw KnowledgeFile.Failure.badPath }
        let segments = path.split(separator: "/").map(String.init)
        var walked = ""
        for (index, segment) in segments.enumerated() {
            walked = walked.isEmpty ? segment : walked + "/" + segment
            guard let entry = tree.entries[walked] else { throw KnowledgeFile.Failure.notFound }
            if entry.isSymlink { throw KnowledgeFile.Failure.refused }
            let isLast = index == segments.count - 1
            guard isLast ? entry.isFile : entry.isDirectory else { throw KnowledgeFile.Failure.notFound }
        }
        guard let entry = tree.entries[path], let size = entry.size else { throw KnowledgeFile.Failure.notFound }
        guard size <= KnowledgeFile.maxBytes else { throw KnowledgeFile.Failure.tooLarge }
        guard let executable = PullRequestStatus.locate("git", in: searchPath),
              let blob = git(executable, ["-C", root, "cat-file", "blob", entry.oid], nil, KnowledgeFile.maxBytes),
              !blob.timedOut, blob.status == 0, blob.output.count == size
        else { throw KnowledgeFile.Failure.notFound }
        return KnowledgeFile.Payload(data: blob.output, contentType: KnowledgeFile.contentType)
    }
}
