import Foundation

/// The git writes behind the `/edit` page's git tab (`code-editor` round 6,
/// phase 4 of ADR 0005): stage, unstage, commit, push, and a branch switch
/// or create, behind `POST /api/git/{stage,unstage,commit,push,branch}`.
///
/// Every command is one of a fixed allowlist of subcommands with fixed
/// options; a ref or a branch name goes after `--end-of-options`, a path
/// after `--`, a name that starts with `-` is refused before any `git`
/// runs, and a branch name must come back unchanged from `git
/// check-ref-format --branch` (`corpus/01-research.md`, "Git command
/// rules"). A commit takes its message on stdin (`-F -`), so the message
/// is never an argument, and it keeps the user's global config: the name,
/// the email and the signing key live there, and a signing failure is
/// reported, never retried unsigned. The repository's hooks run; their
/// output comes back as the last `outputLines` lines.
///
/// A write takes `index.lock` by design, so a held lock is refused before
/// the command runs (409, never deleted), and git's own lock error maps to
/// the same answer. Every write runs on the repository's serial queue
/// (`GitRead.queue(for:)`), never on the event loop, after the resolution
/// `GitRead.repository(for:projects:)` makes.
public final class GitWrite: @unchecked Sendable {
    /// Runs `git` with `args`, `input` on stdin and a timeout; nil when it
    /// cannot start.
    public typealias Runner = @Sendable (_ args: [String], _ input: Data?, _ timeout: TimeInterval) -> PullRequestStatus.RunResult?

    /// A commit's hooks and a push's transfer take longer than a read.
    public static let longTimeoutSeconds: TimeInterval = 120
    /// How many lines of a command's output the answer carries.
    public static let outputLines = 8
    /// The most paths one stage or unstage takes.
    public static let maxPaths = 256
    /// How much of a command's stdout is kept.
    public static let maxOutputBytes = 1 << 20
    /// The options every write carries before its subcommand: a
    /// repository's own config runs no program, and nothing is coloured.
    public static let writeOptions = ["-c", "core.fsmonitor=", "-c", "color.ui=false"]
    /// How many local branches the status lists for the switcher.
    public static let maxBranches = 50

    public enum Kind: String, Sendable {
        case stage, unstage, commit, push, branch
    }

    public enum Failure: Error, Equatable {
        /// A malformed request: an empty message, a bad path or name.
        case refused(String)
        /// `index.lock` is held.
        case locked
        /// The repository cannot do it: a detached head to push, no remote.
        case conflict(String)
        case gitAbsent
        /// The command failed: `git push exited 1: ! [rejected] …` and the
        /// last lines it printed.
        case failed(String, [String])

        public var reason: String {
            switch self {
            case .refused(let text): return text
            case .locked: return "index.lock is held"
            case .conflict(let text): return text
            case .gitAbsent: return "git is not on PATH"
            case .failed(let text, _): return text
            }
        }
    }

    /// What a write answers: the last lines the command printed and the
    /// facts the route puts beside `ok` (`oid`, `branch`, `remote`).
    public struct Outcome: Sendable, Equatable {
        public var lines: [String]
        public var fields: [String: String]

        public init(lines: [String] = [], fields: [String: String] = [:]) {
            self.lines = lines
            self.fields = fields
        }
    }

    private let run: Runner

    public init(searchPath: String = PullRequestStatus.defaultSearchPath, run: Runner? = nil) {
        self.run = run ?? { args, input, timeout in
            guard let git = PullRequestStatus.locate("git", in: searchPath) else { return nil }
            return KnowledgeBase.run(
                executable: git, args: args, input: input, maxOutput: GitWrite.maxOutputBytes,
                searchPath: searchPath, timeout: timeout
            )
        }
    }

    // MARK: - Validation

    /// A path for `add` or `restore`: relative to the toplevel, no `..`,
    /// `.` or empty component, no NUL, not absolute. After `--` a leading
    /// `-` is data, but a path that names an option is refused too, so a
    /// typo never reads as one.
    public static func validatePath(_ path: String) -> String? {
        if path.isEmpty { return "a path is empty" }
        if path.hasPrefix("-") { return "a path starts with -: \(path)" }
        if path.hasPrefix("/") { return "a path is absolute: \(path)" }
        if path.utf8.contains(0) { return "a path holds a NUL" }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) where part.isEmpty || part == "." || part == ".." {
            return "a path holds a . or .. component: \(path)"
        }
        return nil
    }

    /// A branch name before `git check-ref-format --branch` sees it: not
    /// empty, no leading `-`, no control character, no space.
    public static func validateName(_ name: String) -> String? {
        if name.isEmpty { return "the branch name is empty" }
        if name.hasPrefix("-") { return "the branch name starts with -: \(name)" }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == " " }) {
            return "the branch name holds a space or a control character"
        }
        if name.utf8.count > 255 { return "the branch name is over 255 bytes" }
        return nil
    }

    /// The name `git check-ref-format --branch` answers unchanged, else the
    /// refusal.
    func checkedName(_ name: String, in repository: GitRead.Repository) -> Result<String, Failure> {
        if let refusal = Self.validateName(name) { return .failure(.refused(refusal)) }
        guard let result = run(base(repository) + ["check-ref-format", "--branch", name], nil, KnowledgeBase.timeoutSeconds) else {
            return .failure(.gitAbsent)
        }
        let answer = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard result.status == 0, answer == name else {
            return .failure(.refused("the branch name is refused: \(name)"))
        }
        return .success(name)
    }

    private func base(_ repository: GitRead.Repository) -> [String] {
        ["-C", repository.toplevel] + Self.writeOptions
    }

    // MARK: - The lock

    /// Where this repository's `index.lock` would be (a worktree's is in
    /// its own gitdir); nil when git cannot say.
    func indexLockPath(of repository: GitRead.Repository) -> String? {
        guard let result = run(base(repository) + ["rev-parse", "--git-path", "index.lock"], nil, KnowledgeBase.timeoutSeconds),
              result.status == 0
        else { return nil }
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return nil }
        return text.hasPrefix("/") ? text : repository.toplevel + "/" + text
    }

    /// `.locked` when the lock file exists. It is never deleted: the agent
    /// that holds it is mid-write.
    func refuseIfLocked(_ repository: GitRead.Repository) throws {
        if let lock = indexLockPath(of: repository), FileManager.default.fileExists(atPath: lock) { throw Failure.locked }
    }

    /// Git's own lock error, `Unable to create '…/index.lock': File exists`.
    static func isLockError(_ stderr: String) -> Bool {
        stderr.contains("index.lock") && stderr.contains("File exists")
    }

    // MARK: - The writes

    /// `git add -- <paths>`.
    public func stage(_ repository: GitRead.Repository, paths: [String]) throws -> Outcome {
        let checked = try checkedPaths(paths)
        try refuseIfLocked(repository)
        return try execute("git add", base(repository) + ["add", "--"] + checked, input: nil, timeout: KnowledgeBase.timeoutSeconds)
    }

    /// `git restore --staged -- <paths>`, or `git rm --cached` in a
    /// repository with no commit yet, where there is no `HEAD` to restore
    /// from.
    public func unstage(_ repository: GitRead.Repository, paths: [String]) throws -> Outcome {
        let checked = try checkedPaths(paths)
        try refuseIfLocked(repository)
        guard let head = run(base(repository) + ["rev-parse", "--verify", "--quiet", "HEAD"], nil, KnowledgeBase.timeoutSeconds) else {
            throw Failure.gitAbsent
        }
        let args = head.status == 0
            ? ["restore", "--staged", "--"] + checked
            : ["rm", "--cached", "-r", "-q", "--force", "--"] + checked
        return try execute("git " + args[0], base(repository) + args, input: nil, timeout: KnowledgeBase.timeoutSeconds)
    }

    /// `git commit -F -` with the message on stdin. The answer carries the
    /// new commit's id and the branch, with the last lines the command
    /// and the hooks printed.
    public func commit(_ repository: GitRead.Repository, message: String) throws -> Outcome {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.refused("the message is empty") }
        try refuseIfLocked(repository)
        var text = message
        if !text.hasSuffix("\n") { text += "\n" }
        var outcome = try execute("git commit", base(repository) + ["commit", "-F", "-"], input: Data(text.utf8), timeout: Self.longTimeoutSeconds)
        if let head = run(base(repository) + ["rev-parse", "--verify", "--quiet", "HEAD"], nil, KnowledgeBase.timeoutSeconds), head.status == 0 {
            outcome.fields["oid"] = String(decoding: head.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        if let branch = currentBranch(repository) { outcome.fields["branch"] = branch }
        return outcome
    }

    /// `git push` of the current branch to its upstream, or
    /// `--set-upstream origin <branch>` when it has none and `origin`
    /// exists. Never `--force`.
    public func push(_ repository: GitRead.Repository) throws -> Outcome {
        guard let branch = currentBranch(repository) else { throw Failure.conflict("HEAD is detached: nothing to push") }
        if let refusal = Self.validateName(branch) { throw Failure.refused(refusal) }
        guard let upstream = run(
            base(repository) + ["for-each-ref", "--format=%(upstream:remotename)%0a%(upstream:remoteref)", "--", "refs/heads/" + branch],
            nil, KnowledgeBase.timeoutSeconds
        ) else { throw Failure.gitAbsent }
        let parts = String(decoding: upstream.output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var args = ["push"]
        var remote: String
        if upstream.status == 0, parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[0].hasPrefix("-"), !parts[1].hasPrefix("-") {
            remote = parts[0]
            args += ["--end-of-options", remote, "refs/heads/\(branch):\(parts[1])"]
        } else {
            guard let origin = run(base(repository) + ["remote", "get-url", "origin"], nil, KnowledgeBase.timeoutSeconds) else {
                throw Failure.gitAbsent
            }
            guard origin.status == 0 else { throw Failure.conflict("no upstream and no origin remote") }
            remote = "origin"
            args += ["--set-upstream", "--end-of-options", "origin", branch]
        }
        var outcome = try execute("git push", base(repository) + args, input: nil, timeout: Self.longTimeoutSeconds)
        outcome.fields["branch"] = branch
        outcome.fields["remote"] = remote
        return outcome
    }

    /// `git switch <name>`, or `git switch --create <name>`. Git refuses
    /// a switch that would overwrite local changes, and that refusal is
    /// the answer.
    public func branch(_ repository: GitRead.Repository, name: String, create: Bool) throws -> Outcome {
        let checked = try checkedName(name, in: repository).get()
        try refuseIfLocked(repository)
        let args = create ? ["switch", "--create", checked] : ["switch", "--end-of-options", checked]
        var outcome = try execute("git switch", base(repository) + args, input: nil, timeout: KnowledgeBase.timeoutSeconds)
        outcome.fields["branch"] = checked
        return outcome
    }

    // MARK: - Helpers

    private func checkedPaths(_ paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { throw Failure.refused("no path to stage") }
        guard paths.count <= Self.maxPaths else { throw Failure.refused("over \(Self.maxPaths) paths") }
        for path in paths {
            if let refusal = Self.validatePath(path) { throw Failure.refused(refusal) }
        }
        return paths
    }

    /// The current branch's short name; nil when detached or unreadable.
    func currentBranch(_ repository: GitRead.Repository) -> String? {
        guard let result = run(base(repository) + ["symbolic-ref", "--quiet", "--short", "HEAD"], nil, KnowledgeBase.timeoutSeconds),
              result.status == 0
        else { return nil }
        let name = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        return name.isEmpty ? nil : name
    }

    /// One command: its last lines on success, `.locked` on git's lock
    /// error, else `.failed` with the first useful stderr line.
    private func execute(_ command: String, _ args: [String], input: Data?, timeout: TimeInterval) throws -> Outcome {
        guard let result = run(args, input, timeout) else { throw Failure.gitAbsent }
        let lines = Self.lastLines(stdout: result.output, stderr: result.error)
        guard result.status == 0, !result.timedOut else {
            if Self.isLockError(result.error) { throw Failure.locked }
            throw Failure.failed(Self.failure(command, result, timeout: timeout), lines)
        }
        return Outcome(lines: lines)
    }

    /// The last `outputLines` lines of what the command printed: stdout
    /// then stderr, each as it came, blank lines dropped. The two streams
    /// are read apart, so their interleaving is not known; most hooks print
    /// their progress to stdout, and git's own summary ends it.
    static func lastLines(stdout: Data, stderr: String, keep: Int = GitWrite.outputLines) -> [String] {
        let out = String(decoding: stdout, as: UTF8.self)
        let all = (out.split(separator: "\n") + stderr.split(separator: "\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(all.suffix(keep))
    }

    /// `git push exited 1: ! [rejected] main -> main (fetch first)`: the
    /// first stderr line that says something (not `To <url>`, not a
    /// `hint:`), its runs of spaces folded, else the last stdout line
    /// (`nothing to commit, working tree clean` comes on stdout), else the
    /// code alone; a timeout names the seconds.
    static func failure(_ command: String, _ result: PullRequestStatus.RunResult, timeout: TimeInterval) -> String {
        if result.timedOut { return "\(command) timed out after \(Int(timeout)) s" }
        let line = firstLine(stderr: result.error, stdout: result.output)
        return line.isEmpty ? "\(command) exited \(result.status)" : "\(command) exited \(result.status): \(line)"
    }

    static func firstLine(stderr: String, stdout: Data) -> String {
        let fold: (Substring) -> String = { line in
            line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        for line in stderr.split(separator: "\n") {
            let text = fold(line)
            if text.isEmpty || text.hasPrefix("To ") || text.hasPrefix("hint:") { continue }
            return text
        }
        let out = String(decoding: stdout, as: UTF8.self)
        for line in out.split(separator: "\n").reversed() {
            let text = fold(line)
            if !text.isEmpty { return text }
        }
        return ""
    }
}
