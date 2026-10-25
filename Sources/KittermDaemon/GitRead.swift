import Foundation
import NIOConcurrencyHelpers

/// The git reads behind the `/edit` page's git tab (`code-editor` round 5,
/// phase 3 of ADR 0005): the status of a file's repository and the unified
/// diff of one file, behind `GET /api/git/status` and `GET /api/git/diff`.
///
/// Every command runs through `KnowledgeBase.run` (its own process group,
/// a 20 s timeout, no prompt, literal pathspecs) with `--no-optional-locks`
/// and `-c core.fsmonitor=`, so a read never takes `index.lock` from under
/// an agent's `git commit` and a repository's own config runs no program on
/// a plain status (`corpus/01-research.md`, "Git command rules"). The reads
/// of one repository run on one serial queue, never on the event loop.
///
/// The repository is the one of the file's parent directory, as `git
/// rev-parse --show-toplevel` names it, so a file in a worktree reads the
/// worktree's status and not the main checkout's; it must sit on one chain
/// with the project that would jail the file's save (`FileEdit.locate`),
/// and a path outside both is refused.
public final class GitRead: @unchecked Sendable {
    /// Runs `git` with `args`; nil when it cannot start.
    public typealias Runner = @Sendable (_ args: [String]) -> PullRequestStatus.RunResult?

    /// The diff route's output cap; the answer says when it was cut.
    public static let diffMaxBytes = 512 << 10
    /// An untracked file larger than this gets no line count.
    public static let countMaxBytes = 1 << 20
    /// How long a directory's toplevel answer is kept.
    public static let toplevelCacheSeconds: TimeInterval = 60
    /// The options every read carries, before the subcommand.
    public static let readOptions = ["--no-optional-locks", "-c", "core.fsmonitor=", "-c", "color.ui=false"]

    public enum Failure: Error, Equatable {
        /// The file's parent is in no project.
        case noProject
        /// The file's parent is in no git repository.
        case noRepository
        /// The repository and the project are not on one chain, or the
        /// path is not under the repository.
        case outsideRepository
        case gitAbsent
        case failed(String)

        public var reason: String {
            switch self {
            case .noProject: return "outside every project"
            case .noRepository: return "no repository"
            case .outsideRepository: return "outside the repository"
            case .gitAbsent: return "git is not on PATH"
            case .failed(let text): return text
            }
        }
    }

    /// Where a file sits in git: the repository's toplevel (a real path)
    /// and the file's path under it, as a pathspec.
    public struct Repository: Sendable, Equatable {
        public let toplevel: String
        public let relative: String
    }

    /// The unified diff of one file.
    public struct Diff: Sendable, Equatable {
        public var untracked: Bool
        public var binary: Bool
        public var additions: Int?
        public var deletions: Int?
        public var text: String
        public var truncated: Bool
    }

    private let run: Runner
    private let clock: @Sendable () -> Date
    private let lock = NIOLock()
    private var queues: [String: DispatchQueue] = [:]
    private var toplevels: [String: (toplevel: String?, at: Date)] = [:]
    /// Where the resolution runs: `realpath`, the project walk and one
    /// `rev-parse`, off the loop and off every repository's queue.
    let resolveQueue = DispatchQueue(label: "kitterm.git.resolve")

    public init(
        searchPath: String = PullRequestStatus.defaultSearchPath, run: Runner? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clock = clock
        self.run = run ?? { args in
            guard let git = PullRequestStatus.locate("git", in: searchPath) else { return nil }
            return KnowledgeBase.run(
                executable: git, args: args, input: nil, maxOutput: GitRead.diffMaxBytes + 1, searchPath: searchPath
            )
        }
    }

    /// The serial queue of one repository.
    public func queue(for toplevel: String) -> DispatchQueue {
        lock.withLock {
            if let queue = queues[toplevel] { return queue }
            let queue = DispatchQueue(label: "kitterm.git." + toplevel)
            queues[toplevel] = queue
            return queue
        }
    }

    // MARK: - Resolution

    /// The repository of the lexical `path`, by the rules above. Blocking:
    /// the caller runs it on `resolveQueue`.
    public func repository(for path: String, projects: ProjectStore) -> Result<Repository, Failure> {
        // A directory is its own parent (the folder form of `/edit`, round
        // 7): its repository, with its path under the toplevel as `relative`,
        // `""` at the root, which `status` reads whole and `diff` never asks.
        if let location = FileEdit.locateDirectory(path, projects: projects) {
            guard let project = location.project else { return .failure(.noProject) }
            guard let real = FileEdit.realPath(path), let toplevel = toplevel(of: real) else {
                return .failure(.noRepository)
            }
            guard toplevel == project.root || ProjectStore.isPrefix(toplevel, of: project.root)
                || ProjectStore.isPrefix(project.root, of: toplevel)
            else { return .failure(.outsideRepository) }
            let parts = FileEdit.components(of: real, under: toplevel) ?? []
            return .success(Repository(toplevel: toplevel, relative: parts.joined(separator: "/")))
        }
        guard let location = FileEdit.locate(path, projects: projects), let project = location.project else {
            return .failure(.noProject)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = FileEdit.realPath(parent), let toplevel = toplevel(of: realParent) else {
            return .failure(.noRepository)
        }
        guard toplevel == project.root || ProjectStore.isPrefix(toplevel, of: project.root)
            || ProjectStore.isPrefix(project.root, of: toplevel)
        else { return .failure(.outsideRepository) }
        // The file's name under the real parent: the lexical path's last
        // component, so a symlinked parent still names the file git sees.
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", let parts = FileEdit.components(of: realParent + "/" + name, under: toplevel)
        else { return .failure(.outsideRepository) }
        return .success(Repository(toplevel: toplevel, relative: parts.joined(separator: "/")))
    }

    /// `git -C directory rev-parse --show-toplevel`, kept for
    /// `toplevelCacheSeconds`; nil for a directory in no repository.
    func toplevel(of directory: String) -> String? {
        let now = clock()
        if let kept: (toplevel: String?, at: Date) = lock.withLock({ toplevels[directory] }),
           now.timeIntervalSince(kept.at) < Self.toplevelCacheSeconds {
            return kept.toplevel
        }
        var answer: String?
        if let result = run(["-C", directory] + Self.readOptions + ["rev-parse", "--show-toplevel"]), result.status == 0 {
            let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
            if text.hasPrefix("/") { answer = ProjectStore.normalize(text) }
        }
        lock.withLock { toplevels[directory] = (answer, now) }
        return answer
    }

    // MARK: - Status

    /// The repository's status with `+a −d` per file. Blocking: the caller
    /// runs it on the repository's queue.
    public func status(of repository: Repository) throws -> GitStatus.Report {
        let base = ["-C", repository.toplevel] + Self.readOptions
        // `--ignored=matching` names a top-level ignored path without
        // descending into it (an ignored directory is one `!` record, not
        // one per file inside), measured at parity with a plain status on
        // this repository: both read in 0.02 s (`code-editor` round 13).
        guard let result = run(base + ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal", "--ignored=matching"]) else {
            throw Failure.gitAbsent
        }
        guard result.status == 0 else { throw Failure.failed(Self.failure("git status", result)) }
        var report = GitStatus.parse(result.output)
        var counts: [String: (Int?, Int?)] = [:]
        if report.oid != nil, let numstat = run(base + ["diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "HEAD", "--"]),
           numstat.status == 0 {
            for line in GitStatus.parseNumstat(numstat.output) { counts[line.path] = (line.additions, line.deletions) }
        }
        // The local branches for the switcher (round 6), the most recently
        // committed first, the current one always among them.
        if let refs = run(base + ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "--count=\(GitWrite.maxBranches)", "--", "refs/heads/"]),
           refs.status == 0 {
            report.branches = String(decoding: refs.output, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if let branch = report.branch, !report.branches.contains(branch) { report.branches.insert(branch, at: 0) }
        }
        for index in report.files.indices {
            let entry = report.files[index]
            if let known = counts[entry.path] {
                report.files[index].additions = known.0
                report.files[index].deletions = known.1
            } else if entry.kind == .untracked || (report.oid == nil && entry.index == "A") {
                report.files[index].additions = Self.lineCount(of: repository.toplevel + "/" + entry.path)
                report.files[index].deletions = report.files[index].additions == nil ? nil : 0
            }
        }
        return report
    }

    // MARK: - Diff

    /// The unified diff of `repository.relative`: the working tree against
    /// the index, or with `staged` the index against `HEAD`; an untracked
    /// file as all added. Blocking: the caller runs it on the repository's
    /// queue.
    public func diff(of repository: Repository, staged: Bool) throws -> Diff {
        let base = ["-C", repository.toplevel] + Self.readOptions
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "--numstat", "-p"]
        guard let result = run(base + ["diff"] + options + (staged ? ["--cached"] : []) + ["--", repository.relative]) else {
            throw Failure.gitAbsent
        }
        guard result.status == 0 else { throw Failure.failed(Self.failure("git diff", result)) }
        if !result.output.isEmpty || staged { return Self.parseDiff(result.output, untracked: false) }
        // Nothing to show: an untracked file is not in the index, and its
        // diff is the file against nothing.
        guard let listed = run(base + ["ls-files", "-z", "--", repository.relative]) else { throw Failure.gitAbsent }
        guard listed.status == 0, listed.output.isEmpty,
              FileManager.default.fileExists(atPath: repository.toplevel + "/" + repository.relative)
        else { return Self.parseDiff(Data(), untracked: false) }
        guard let whole = run(base + ["diff"] + options + ["--no-index", "--", "/dev/null", repository.relative]) else {
            throw Failure.gitAbsent
        }
        // `--no-index` exits 1 when the two differ, which is the point.
        guard whole.status == 0 || whole.status == 1 else { throw Failure.failed(Self.failure("git diff", whole)) }
        return Self.parseDiff(whole.output, untracked: true)
    }

    /// The `--numstat -p` output: the counts line, a blank line, the patch.
    static func parseDiff(_ output: Data, untracked: Bool) -> Diff {
        var diff = Diff(untracked: untracked, binary: false, additions: nil, deletions: nil, text: "", truncated: false)
        guard !output.isEmpty else { return diff }
        var body = output
        if body.count > diffMaxBytes {
            var cut = diffMaxBytes
            if let newline = body[..<diffMaxBytes].lastIndex(of: UInt8(ascii: "\n")) { cut = newline + 1 }
            body = body.prefix(cut)
            diff.truncated = true
        }
        let text = String(decoding: body, as: UTF8.self)
        guard let firstBreak = text.firstIndex(of: "\n") else { return diff }
        let counts = text[..<firstBreak].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        if counts.count == 3 {
            diff.additions = Int(counts[0])
            diff.deletions = Int(counts[1])
            diff.binary = counts[0] == "-"
            var rest = text[text.index(after: firstBreak)...]
            if rest.hasPrefix("\n") { rest = rest.dropFirst() }
            diff.text = String(rest)
        } else {
            diff.text = text
        }
        return diff
    }

    /// The newlines of the file, nil for one over `countMaxBytes` or with
    /// a NUL in its first bytes (binary), or that cannot be read.
    static func lineCount(of path: String) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: countMaxBytes + 1), data.count <= countMaxBytes else { return nil }
        if data.prefix(8192).contains(0) { return nil }
        var count = data.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        if let last = data.last, last != UInt8(ascii: "\n") { count += 1 }
        return count
    }

    private static func failure(_ command: String, _ result: PullRequestStatus.RunResult) -> String {
        if result.timedOut { return "\(command) timed out after \(Int(KnowledgeBase.timeoutSeconds)) s" }
        let line = result.error.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "\(command) exited \(result.status)" : "\(command) exited \(result.status): \(line)"
    }
}

/// `git status --porcelain=v2 -z --branch`, parsed. Pure.
public enum GitStatus {
    /// Paths `--ignored=matching` names at most, with `ignoredTruncated`
    /// set once a read holds more (rule 19 of `corpus/09-approved-frames.md`).
    public static let maxIgnored = 2000

    public enum Kind: String, Sendable {
        case ordinary, renamed, copied, unmerged, untracked
    }

    public struct Entry: Sendable, Equatable {
        public var path: String
        /// The old path of a renamed or copied entry.
        public var origPath: String?
        /// The index column of `XY`, `.` for unchanged.
        public var index: Character
        /// The worktree column of `XY`, `.` for unchanged.
        public var worktree: Character
        public var kind: Kind
        public var additions: Int?
        public var deletions: Int?

        public init(
            path: String, origPath: String? = nil, index: Character, worktree: Character, kind: Kind,
            additions: Int? = nil, deletions: Int? = nil
        ) {
            self.path = path
            self.origPath = origPath
            self.index = index
            self.worktree = worktree
            self.kind = kind
            self.additions = additions
            self.deletions = deletions
        }
    }

    public struct Counts: Sendable, Equatable {
        /// Every entry but an ignored one.
        public var changed = 0
        /// Entries with a change in the index.
        public var staged = 0
        /// Entries with a change in the working tree.
        public var unstaged = 0
        public var untracked = 0
        public var conflicts = 0
    }

    public struct Report: Sendable, Equatable {
        /// The branch, nil when detached.
        public var branch: String?
        /// The commit `HEAD` names, nil on an unborn branch.
        public var oid: String?
        public var upstream: String?
        public var ahead = 0
        public var behind = 0
        public var detached = false
        public var files: [Entry] = []
        /// The local branches, by last commit, at most `GitWrite.maxBranches`.
        public var branches: [String] = []
        /// Paths `.gitignore` excludes, a directory ending in `/` and not
        /// listed again for what sits under it; never in `files` or
        /// `counts` (rule 19). Capped at `GitStatus.maxIgnored`.
        public var ignored: [String] = []
        public var ignoredTruncated = false

        public var counts: Counts {
            var counts = Counts()
            for entry in files {
                switch entry.kind {
                case .untracked: counts.untracked += 1
                case .unmerged: counts.conflicts += 1
                case .ordinary, .renamed, .copied:
                    if entry.index != "." { counts.staged += 1 }
                    if entry.worktree != "." { counts.unstaged += 1 }
                }
                counts.changed += 1
            }
            return counts
        }
    }

    /// The report of one `-z` status output. A record the parser does not
    /// know is skipped; a malformed one yields no entry.
    public static func parse(_ data: Data) -> Report {
        var report = Report()
        let fields = nulFields(data)
        var at = 0
        while at < fields.count {
            let record = fields[at]
            at += 1
            guard let first = record.first else { continue }
            switch first {
            case "#":
                header(record, into: &report)
            case "1":
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9, let xy = columns(parts[1]) else { continue }
                report.files.append(Entry(path: String(parts[8]), index: xy.0, worktree: xy.1, kind: .ordinary))
            case "2":
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10, let xy = columns(parts[1]), at < fields.count else { continue }
                let orig = fields[at]
                at += 1
                let kind: Kind = parts[8].hasPrefix("C") ? .copied : .renamed
                report.files.append(Entry(path: String(parts[9]), origPath: orig, index: xy.0, worktree: xy.1, kind: kind))
            case "u":
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11, let xy = columns(parts[1]) else { continue }
                report.files.append(Entry(path: String(parts[10]), index: xy.0, worktree: xy.1, kind: .unmerged))
            case "?":
                guard record.count > 2, record.dropFirst().first == " " else { continue }
                let path = String(record.dropFirst(2))
                report.files.append(Entry(path: path, index: first, worktree: first, kind: .untracked))
            case "!":
                guard record.count > 2, record.dropFirst().first == " " else { continue }
                let path = String(record.dropFirst(2))
                if report.ignored.count < maxIgnored { report.ignored.append(path) } else { report.ignoredTruncated = true }
            default:
                continue
            }
        }
        return report
    }

    /// The NUL-terminated fields of `data`; the terminator of the last one
    /// opens no empty field after it.
    static func nulFields(_ data: Data) -> [String] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if fields.last == "" { fields.removeLast() }
        return fields
    }

    private static func columns(_ xy: Substring) -> (Character, Character)? {
        guard xy.count == 2, let x = xy.first, let y = xy.last else { return nil }
        return (x, y)
    }

    private static func header(_ record: String, into report: inout Report) {
        let parts = record.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid":
            report.oid = value == "(initial)" ? nil : value
        case "branch.head":
            report.detached = value == "(detached)"
            report.branch = report.detached ? nil : value
        case "branch.upstream":
            report.upstream = value
        case "branch.ab":
            for word in value.split(separator: " ") {
                if word.hasPrefix("+") { report.ahead = Int(word.dropFirst()) ?? 0 }
                if word.hasPrefix("-") { report.behind = Int(word.dropFirst()) ?? 0 }
            }
        default:
            return
        }
    }

    public struct NumstatLine: Sendable, Equatable {
        public var path: String
        public var origPath: String?
        /// nil for a binary file (`-`).
        public var additions: Int?
        public var deletions: Int?
    }

    /// `git diff --numstat -z`: `a\tb\tpath\0`, and for a rename
    /// `a\tb\t\0old\0new\0`.
    public static func parseNumstat(_ data: Data) -> [NumstatLine] {
        var lines: [NumstatLine] = []
        let fields = nulFields(data)
        var at = 0
        while at < fields.count {
            let record = fields[at]
            at += 1
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let additions = parts[0] == "-" ? nil : Int(parts[0])
            let deletions = parts[1] == "-" ? nil : Int(parts[1])
            if parts[2].isEmpty {
                guard at + 1 < fields.count else { break }
                lines.append(NumstatLine(path: fields[at + 1], origPath: fields[at], additions: additions, deletions: deletions))
                at += 2
            } else {
                lines.append(NumstatLine(path: String(parts[2]), additions: additions, deletions: deletions))
            }
        }
        return lines
    }
}
