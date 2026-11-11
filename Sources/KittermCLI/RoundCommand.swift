#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import KittermDaemon

/// `kitterm round open <root> <slug> --task <item>` — every step of a round
/// before the crew's prompt (`docs/goals/round-commands/plan.md`, row 2).
///
/// The steps, in order. Each step reuses what is already there, so a second
/// run after a partial failure continues from what exists:
///
/// 1. `daemon`: `GET /api/sessions`. A session that has not exited and
///    carries `crew:<slug>` refuses the round before anything changes.
/// 2. `base`: the base branch by `KnowledgeBase.baseBranch`, then a fetch.
/// 3. `branch`: `goal/<slug>` (`chore/<slug>`), from `origin/<base>`.
/// 4. `worktree`: `<root>/.claude/worktrees/<slug>` on that branch.
/// 5. `goal`: the goal folder in the worktree must hold `STATE.md` with the
///    item under `## Queue`. The round is the highest `rounds/NNN.md` plus
///    one. A chore has no folder: it gets one empty commit instead.
/// 6. `pull request`: the open pull request of the branch, else a draft
///    one after the queue line names the round and the branch is pushed.
/// 7. `queue line`: the item's first line ends `, round R, PR #N.`; the
///    command commits the goal folder and pushes, never with force.
/// 8. `spawn`: `POST /api/sessions` with the worktree as cwd, the name
///    `<slug> round <R>`, and the labels `crew`, `goal`, `round`, `task`
///    and `pr`. No input is typed.
///
/// The command never merges, force-pushes or marks a pull request ready.
/// Every `git` and `gh` goes through one `Runner`, so a test hands it a
/// fake `gh`.
///
/// `kitterm round close`, the steps after the crew, is in
/// `RoundCloseCommand.swift`; it shares `Steps`, `StepFailure` and the
/// `Runner`.
enum RoundCommand {
    static let usage = """
    usage: kitterm round open <root> <slug> --task <item> [--chore] [--title <text>] [--body <text>] \
    [--knowledge <dir>] [--port <n>] [--json]
           kitterm round close <root> <slug> [--chore] [--commit] [--round <n>] [--bill-timeout <s>] \
    [--foreman-session <id>] [--knowledge <dir>] [--port <n>]
    """

    /// Runs `tool` (`git` or `gh`) with `args` in `directory`; nil when it
    /// cannot start.
    typealias Runner = @Sendable (_ tool: String, _ args: [String], _ directory: String) -> PullRequestStatus.RunResult?

    /// What one `git` or `gh` may take before it is killed. A push or a
    /// `gh pr create` talks to the network.
    static let toolTimeoutSeconds: TimeInterval = 120
    /// What one daemon request may take.
    static let daemonTimeoutSeconds: TimeInterval = 10

    /// One subcommand. `out` takes every line meant for stdout, `progress`
    /// every line meant for stderr.
    static func run<S: Sequence>(
        _ args: S, runner: @escaping Runner = defaultRunner,
        out: (String) -> Void = { print($0) },
        progress: (String) -> Void = { writeError($0 + "\n") }
    ) throws where S.Element == String {
        let array = Array(args)
        if array.first == "close" {
            let options = try CloseOptions.parse(Array(array.dropFirst()))
            try close(options, runner: runner, progress: progress).lines.forEach(out)
            return
        }
        guard array.first == "open" else { throw CLIError.usage(usage) }
        let options = try Options.parse(Array(array.dropFirst()))
        let opened = try open(options, runner: runner, progress: progress)
        if options.json {
            out(try opened.json())
        } else {
            opened.lines.forEach(out)
        }
    }

    // MARK: - Options

    struct Options: Equatable {
        var root: String
        var slug: String
        var task: String
        var chore = false
        var title: String?
        var body: String?
        var knowledge: String?
        var port: Int?
        var json = false

        static func parse(_ args: [String]) throws -> Options {
            var positional: [String] = []
            var task: String?, title: String?, body: String?, knowledge: String?, port: Int?
            var chore = false, json = false
            var index = 0
            func value(_ flag: String) throws -> String {
                index += 1
                guard index < args.count else { throw CLIError.usage("\(flag) needs a value\n\(usage)") }
                return args[index]
            }
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--task": task = try value(arg)
                case "--title": title = try value(arg)
                case "--body": body = try value(arg)
                case "--knowledge": knowledge = try value(arg)
                case "--port":
                    let text = try value(arg)
                    guard let number = Int(text), (1...65535).contains(number) else {
                        throw CLIError.usage("--port takes a port number, not \(text)\n\(usage)")
                    }
                    port = number
                case "--chore": chore = true
                case "--json": json = true
                default:
                    if arg.hasPrefix("-") { throw CLIError.unknownOption("kitterm: unknown option \(arg)\n\(usage)") }
                    positional.append(arg)
                }
                index += 1
            }
            guard positional.count == 2 else { throw CLIError.usage(usage) }
            let slug = positional[1]
            guard ProjectStore.isValidID(slug) else {
                throw CLIError.usage("the slug \(slug) is not a kebab word (a-z, 0-9, -)\n\(usage)")
            }
            if chore, task == nil { task = slug }
            guard let task else { throw CLIError.usage("a goal round needs --task <item>\n\(usage)") }
            guard ProjectStore.isValidID(task) else {
                throw CLIError.usage("the item \(task) is not a kebab word (a-z, 0-9, -)\n\(usage)")
            }
            return Options(
                root: positional[0], slug: slug, task: task, chore: chore, title: title, body: body,
                knowledge: knowledge, port: port, json: json
            )
        }
    }

    // MARK: - The result

    struct Opened: Equatable {
        var session: String
        var worktree: String
        var branch: String
        var pr: Int
        var round: Int
        var base: String
        var task: String
        var slug: String
        var chore: Bool

        var lines: [String] {
            [
                "session  \(session)", "worktree \(worktree)", "branch   \(branch)",
                "pr       \(pr)", "round    \(round)", "base     \(base)",
            ]
        }

        func json() throws -> String {
            let object: [String: Any] = [
                "session": session, "worktree": worktree, "branch": branch, "pr": pr, "round": round,
                "base": base, "task": task, "slug": slug, "chore": chore,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// A step that failed: its name, the reason, and what already exists,
    /// so the human knows what a second run reuses.
    struct StepFailure: Error, LocalizedError, Equatable {
        var step: String
        var reason: String
        var exists: [String]
        /// `open` or `close`.
        var command = "open"

        var errorDescription: String? {
            let there = exists.isEmpty ? "nothing changed" : "already there: " + exists.joined(separator: ", ")
            return "round \(command): \(step) failed: \(reason)\n\(there)"
        }
    }

    /// The runner of one subcommand with what its steps made so far, so a
    /// failure names its step and what a second run reuses.
    final class Steps {
        let command: String
        let runner: Runner
        var exists: [String] = []

        init(command: String, runner: @escaping Runner) {
            self.command = command
            self.runner = runner
        }

        func fail(_ step: String, _ reason: String) -> StepFailure {
            StepFailure(step: step, reason: reason, exists: exists, command: command)
        }

        /// Runs a tool and answers its trimmed stdout; a failure throws as
        /// `step` with the tool's stderr.
        @discardableResult
        func tool(_ step: String, _ name: String, _ args: [String], in directory: String) throws -> String {
            guard let result = runner(name, args, directory) else {
                throw fail(step, "\(name) did not start (is it on PATH?)")
            }
            if result.timedOut {
                throw fail(step, "\(name) \(args.first ?? "") timed out after \(Int(toolTimeoutSeconds)) s")
            }
            guard result.status == 0 else {
                let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                throw fail(step, "\(name) \(args.prefix(3).joined(separator: " ")) exited \(result.status)"
                    + (detail.isEmpty ? "" : ": " + String(detail.prefix(400))))
            }
            return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// `git -C directory args`, its trimmed stdout, or nil on a failure
        /// or an empty answer.
        func probe(_ args: [String], in directory: String) -> String? {
            guard let result = runner("git", ["-C", directory] + args, directory), !result.timedOut,
                  result.status == 0 else { return nil }
            let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    // MARK: - The steps

    static func open(_ options: Options, runner: @escaping Runner, progress: (String) -> Void) throws -> Opened {
        let steps = Steps(command: "open", runner: runner)
        let fail = steps.fail
        func probe(_ args: [String], in directory: String) -> String? { steps.probe(args, in: directory) }
        @discardableResult
        func tool(_ step: String, _ name: String, _ args: [String], in directory: String) throws -> String {
            try steps.tool(step, name, args, in: directory)
        }

        // 1. daemon
        let crew = options.slug
        guard let port = options.port ?? KittermMain.readPort() else {
            throw fail("daemon", "no port file at \(DaemonPaths.portFile.path); start the daemon or pass --port")
        }
        let client = MCPHTTPClient(port: port)
        let rows = try sessions(client).get { fail("daemon", $0) }
        if let live = rows.first(where: { isLive($0) && labels($0)[ForemanCommand.crewKey] == crew }) {
            throw fail("daemon", "session \(live["id"] as? String ?? "?") is live with crew:\(crew); end it first")
        }

        // 2. base
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: options.root, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw fail("base", "\(options.root) is not a directory") }
        let root = ProjectStore.canonicalRoot(try tool("base", "git", ["-C", options.root, "rev-parse", "--show-toplevel"], in: options.root))
        try tool("base", "git", ["-C", root, "remote", "get-url", "origin"], in: root)
        let base = KnowledgeBase.baseBranch { probe($0, in: root) }
        guard !base.hasPrefix("-"), probe(["check-ref-format", "--branch", base], in: root) == base else {
            throw fail("base", "the base branch name is refused: \(base)")
        }
        let branch = (options.chore ? "chore/" : "goal/") + options.slug
        try tool("base", "git", ["-C", root, "fetch", "--quiet", "origin", "--", "+refs/heads/\(base):refs/remotes/origin/\(base)"], in: root)
        // The branch may not be on the remote yet; that fetch may fail.
        _ = probe(["fetch", "--quiet", "origin", "--", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"], in: root)

        // 3. branch
        if probe(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root) != nil {
            progress("round open: reused branch \(branch)")
        } else if probe(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], in: root) != nil {
            try tool("branch", "git", ["-C", root, "branch", "--track", branch, "origin/\(branch)"], in: root)
            progress("round open: created branch \(branch) from origin/\(branch)")
        } else {
            try tool("branch", "git", ["-C", root, "branch", "--no-track", branch, "origin/\(base)"], in: root)
            progress("round open: created branch \(branch) from origin/\(base)")
        }
        steps.exists.append("branch \(branch)")

        // 4. worktree
        let worktree = ProjectStore.canonicalRoot(root + "/.claude/worktrees/" + options.slug)
        let listing = try tool("worktree", "git", ["-C", root, "worktree", "list", "--porcelain"], in: root)
        let trees = ForemanCommand.parseWorktrees(listing).map { (path: ProjectStore.canonicalRoot($0.path), branch: $0.branch) }
        if let tree = trees.first(where: { $0.path == worktree }) {
            guard tree.branch == branch else {
                throw fail("worktree", "\(worktree) is on \(tree.branch ?? "a detached HEAD"), not \(branch)")
            }
            progress("round open: reused worktree \(worktree)")
        } else {
            if let other = trees.first(where: { $0.branch == branch }) {
                throw fail("worktree", "\(branch) is checked out at \(other.path)")
            }
            guard !FileManager.default.fileExists(atPath: worktree) else {
                throw fail("worktree", "\(worktree) exists and is not a worktree of \(root)")
            }
            try tool("worktree", "git", ["-C", root, "worktree", "add", "--quiet", worktree, branch], in: root)
            progress("round open: created worktree \(worktree)")
        }
        steps.exists.append("worktree \(worktree)")

        // 5. goal
        let knowledge = options.knowledge ?? ProjectStore.load().first { $0.root == root }?.knowledge
            ?? ProjectStore.defaultKnowledge
        let folder = knowledge + "/" + options.slug
        let stateURL = URL(fileURLWithPath: worktree + "/" + folder + "/STATE.md")
        var round = 1
        var title = options.slug
        if options.chore {
            let ahead = try tool("goal", "git", ["-C", worktree, "rev-list", "--count", "origin/\(base)..HEAD"], in: worktree)
            if ahead == "0" {
                try tool("goal", "git", ["-C", worktree, "commit", "--quiet", "--allow-empty", "-m", "\(options.slug): open the chore"], in: worktree)
                progress("round open: committed the empty opening commit of \(branch)")
            }
        } else {
            guard let state = try? String(contentsOf: stateURL, encoding: .utf8) else {
                throw fail("goal", "no \(stateURL.path); write the goal package there and run again")
            }
            let folderURL = stateURL.deletingLastPathComponent()
            let roundNames = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path + "/rounds")) ?? []
            let goalText = try? String(contentsOf: folderURL.appendingPathComponent("goal.md"), encoding: .utf8)
            let summary = KnowledgeSummary.parse(state: state, goal: goalText, roundNames: roundNames, latestRound: nil)
            guard summary.tasks?.contains(where: { $0.slug == options.task && $0.state == .pending }) == true else {
                throw fail("goal", "the ## Queue of \(stateURL.path) holds no item `\(options.task)`")
            }
            round = (summary.lastRound ?? 0) + 1
            title = summary.goal.map { "\(options.slug): \($0)" } ?? options.slug
        }

        // 6 and 7. queue line and pull request
        func writeQueueLine(pr: Int?) throws {
            guard !options.chore else { return }
            let state = try String(contentsOf: stateURL, encoding: .utf8)
            guard let updated = queueLine(in: state, task: options.task, round: round, pr: pr) else {
                throw fail("queue line", "no `\(options.task)` item under ## Queue of \(stateURL.path)")
            }
            guard updated != state else { return }
            do {
                try updated.write(to: stateURL, atomically: true, encoding: .utf8)
            } catch {
                throw fail("queue line", "cannot write \(stateURL.path): \(error.localizedDescription)")
            }
        }
        func commitGoalFolder(_ message: String) throws {
            guard !options.chore else { return }
            try tool("queue line", "git", ["-C", worktree, "add", "--", folder], in: worktree)
            let staged = runner("git", ["-C", worktree, "diff", "--cached", "--quiet", "--", folder], worktree)
            guard staged?.status == 1 else { return }
            try tool("queue line", "git", ["-C", worktree, "commit", "--quiet", "-m", message, "--", folder], in: worktree)
            progress("round open: committed \(message)")
        }
        func push() throws {
            try tool("push", "git", ["-C", worktree, "push", "--quiet", "-u", "origin", "refs/heads/\(branch):refs/heads/\(branch)"], in: worktree)
        }
        func openPull() throws -> Int? {
            let text = try tool("pull request", "gh", ["pr", "list", "--head", branch, "--state", "open", "--json", "number"], in: worktree)
            let rows = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]]
            return rows?.compactMap { $0["number"] as? Int }.min()
        }

        var pr = try openPull()
        if let pr {
            progress("round open: reused PR #\(pr)")
            steps.exists.append("PR #\(pr)")
        } else {
            try writeQueueLine(pr: nil)
            try commitGoalFolder("\(options.slug): round \(round) queues \(options.task)")
            try push()
            let body = options.body ?? (options.chore
                ? "Chore `\(options.slug)`."
                : "The goal's objective and completion conditions are in `\(folder)/goal.md`.")
            let created = try tool("pull request", "gh", [
                "pr", "create", "--draft", "--base", base, "--head", branch,
                "--title", options.title ?? title, "--body", body,
            ], in: worktree)
            var found = pullNumber(created)
            if found == nil { found = try openPull() }
            guard let number = found else {
                throw fail("pull request", "gh pr create printed no pull request URL: \(created.prefix(200))")
            }
            pr = number
            progress("round open: opened draft PR #\(number)")
            steps.exists.append("PR #\(number)")
        }
        let number = pr!
        try writeQueueLine(pr: number)
        try commitGoalFolder("\(options.slug): round \(round) names PR #\(number)")
        try push()
        let head = try tool("push", "git", ["-C", worktree, "rev-parse", "HEAD"], in: worktree)

        // 8. spawn
        var labelValues = [
            ForemanCommand.crewKey: crew, ForemanCommand.taskKey: options.task, SessionLabels.prKey: String(number),
        ]
        if !options.chore {
            labelValues[SessionLabels.goalKey] = options.slug
            labelValues[SessionLabels.roundKey] = String(round)
        }
        let name = options.chore ? options.slug : "\(options.slug) round \(round)"
        let call = MCPTools.Call(method: "POST", path: "/api/sessions", jsonBody: [
            "name": name, "cwd": worktree, "labels": labelValues,
        ])
        let session: String
        switch client.send(call, timeout: daemonTimeoutSeconds) {
        case .failure(let why):
            throw fail("spawn", "no answer on port \(port) (\(why))")
        case .success(let status, _, let data):
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard status == 201 || status == 200, let id = json?["id"] as? String else {
                throw fail("spawn", "port \(port) answered \(status) to POST /api/sessions: \(String(decoding: data.prefix(200), as: UTF8.self))")
            }
            session = id
        }
        progress("round open: spawned session \(session)")

        return Opened(
            session: session, worktree: worktree, branch: branch, pr: number, round: round, base: head,
            task: options.task, slug: options.slug, chore: options.chore
        )
    }

    // MARK: - Pieces

    /// `GET /api/sessions`, the rows or the reason.
    static func sessions(_ client: MCPHTTPClient) -> Result<[[String: Any]], ReasonError> {
        switch client.send(MCPTools.Call(method: "GET", path: "/api/sessions"), timeout: daemonTimeoutSeconds) {
        case .failure(let why):
            return .failure(ReasonError("no answer on port \(client.port) (\(why))"))
        case .success(let status, _, let data):
            guard status == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rows = json["sessions"] as? [[String: Any]]
            else { return .failure(ReasonError("port \(client.port) answered \(status) to GET /api/sessions")) }
            return .success(rows)
        }
    }

    struct ReasonError: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// A row whose session has not exited. A lingering exited session
    /// still has a row, and it does not hold the round.
    static func isLive(_ row: [String: Any]) -> Bool {
        row["mergedState"] as? String != "exited" && row["state"] as? String != "exited"
    }

    static func labels(_ row: [String: Any]) -> [String: String] {
        row["labels"] as? [String: String] ?? [:]
    }

    /// The number at the end of the `…/pull/<N>` URL `gh pr create` prints.
    static func pullNumber(_ output: String) -> Int? {
        for line in output.split(separator: "\n").reversed() {
            if let range = line.range(of: "/pull/", options: .backwards),
               let number = Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) {
                return number
            }
        }
        return nil
    }

    /// `state` with the first line of the item `task` under `## Queue`
    /// rewritten to `<head>, round R.` or `<head>, round R, PR #N.`, where
    /// the head is the text before the line's first comma less a final
    /// `.`. Nil when the queue holds no column-0 item whose head names
    /// `` `task` ``.
    static func queueLine(in state: String, task: String, round: Int, pr: Int?) -> String? {
        var lines = state.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("## ") && $0.dropFirst(3).trimmingCharacters(in: .whitespaces) == "Queue"
        }) else { return nil }
        var index = start + 1
        while index < lines.count, !lines[index].hasPrefix("## "), !lines[index].hasPrefix("# ") {
            let line = lines[index]
            let mark: String?
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                mark = String(line.prefix(2))
            } else {
                let digits = line.prefix { $0.isASCII && $0.isNumber }
                mark = !digits.isEmpty && line.dropFirst(digits.count).hasPrefix(". ") ? digits + ". " : nil
            }
            if let mark {
                let item = line.dropFirst(mark.count)
                var head = item.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first
                    .map(String.init) ?? String(item)
                if head.contains("`\(task)`") {
                    head = head.trimmingCharacters(in: .whitespaces)
                    if head.hasSuffix(".") { head.removeLast() }
                    lines[index] = mark + head + ", round \(round)" + (pr.map { ", PR #\($0)" } ?? "") + "."
                    return lines.joined(separator: "\n")
                }
            }
            index += 1
        }
        return nil
    }

    /// The runner of the real command: `tool` from `PATH`, run by
    /// `PullRequestStatus.run` with `directory` as the working directory.
    /// `gh` finds the repository from its working directory, and
    /// `PullRequestStatus.run` takes none, so the process changes its own
    /// for the run and restores it after. `git` always gets `-C` as well.
    static let defaultRunner: Runner = { tool, args, directory in
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let executable = searchPath.split(separator: ":").map { $0 + "/" + tool }
            .first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { return nil }
        let previous = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(directory) else { return nil }
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        return PullRequestStatus.run(
            executable: executable, args: args, searchPath: searchPath, timeout: toolTimeoutSeconds
        )
    }
}

extension Result where Failure == RoundCommand.ReasonError {
    /// The value, or the reason thrown as the error `wrap` makes.
    func get(_ wrap: (String) -> Error) throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw wrap(error.reason)
        }
    }
}
