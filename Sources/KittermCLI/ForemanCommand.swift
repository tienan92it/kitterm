import Foundation
import KittermDaemon

/// `kitterm foreman catch-up [--scope <path>] [--json]` — what a new
/// foreman reads before anything else: the work of the foreman before it,
/// in one scope (`docs/goals/foreman-scope/corpus/01-two-handovers.md`).
///
/// The scope is a directory: `--scope`, else the working directory, as a
/// real path like a project root. The command prints four sections, and
/// nothing from outside the scope:
///
/// 1. The predecessor: the newest session labelled `crew:foreman`, or
///    `crew:foreman-<anything>` with no `goal:` label, whose `scope:` label,
///    else whose cwd, is the scope or under it. A live session is newer
///    than an archived one. Every live foreman in the scope is listed,
///    because two of them is the conflict the skill stops on. The caller's
///    own session (`KITTERM_SESSION_ID`) is not counted.
/// 2. The goals that are not done, per project whose root is under the
///    scope: the registered projects, and the ones the live session rows
///    discovered.
/// 3. The live sessions with a `goal:` label whose cwd is under the scope.
/// 4. The worktrees under each project's `.claude/worktrees/`.
///
/// The files need no daemon: the archives and `projects.json` are read
/// under `DaemonPaths.stateDirectory` (`KITTERM_STATE_DIR` moves it), the
/// goals with `KnowledgeFile.summaries`, the worktrees with `git`. The live
/// sessions come from `GET /api/sessions`; when the daemon does not answer,
/// one line says so and the files go on. The command writes nothing.
enum ForemanCommand {
    static let usage = "usage: kitterm foreman catch-up [--scope <path>] [--json]"

    /// Run one subcommand. `out` takes every line meant for stdout.
    static func run<S: Sequence>(_ args: S, out: (String) -> Void = { print($0) }) throws
    where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "catch-up":
            try catchUp(Array(array.dropFirst()), out: out)
        default:
            throw CLIError.usage(usage)
        }
    }

    // MARK: - Labels

    static let crewKey = "crew"
    static let taskKey = "task"
    static let foremanCrew = "foreman"

    /// Is a session with these labels a foreman's own pane? `crew:foreman`
    /// always. `crew:foreman-<anything>` only with no `goal:` label: a crew
    /// session carries its goal's slug in `crew:`, and the goals
    /// `foreman-scope`, `foreman-flow` and `foreman-harness` start with the
    /// same word, so their crews carry `crew:foreman-…` beside `goal:`.
    static func isForeman(_ labels: [String: String]) -> Bool {
        guard let crew = labels[crewKey] else { return false }
        if crew == foremanCrew { return true }
        return crew.hasPrefix(foremanCrew + "-") && labels[SessionLabels.goalKey] == nil
    }

    /// The directory a foreman's session claims: its `scope:` label when
    /// that is an absolute path, else its cwd.
    static func claimedScope(labels: [String: String], cwd: String) -> String {
        if let label = labels[SessionLabels.scopeKey], label.hasPrefix("/") { return ProjectStore.canonicalRoot(label) }
        return ProjectStore.canonicalRoot(cwd)
    }

    // MARK: - The live sessions

    /// What the daemon said about the live sessions.
    enum Live {
        /// The rows of `GET /api/sessions`.
        case rows([[String: Any]])
        /// The daemon did not answer; the text says how.
        case unavailable(String)
    }

    /// How long the command waits for the session list.
    static let liveTimeoutSeconds: TimeInterval = 5

    /// `GET /api/sessions` on the port the port file names. No port file is
    /// no daemon: the command never falls back to the default port, so a
    /// scratch state directory never reads the installed daemon's sessions.
    static func liveSessions() -> Live {
        guard let port = KittermMain.readPort() else {
            return .unavailable("no port file at \(DaemonPaths.portFile.path)")
        }
        let call = MCPTools.Call(method: "GET", path: "/api/sessions")
        switch MCPHTTPClient(port: port).send(call, timeout: liveTimeoutSeconds) {
        case .failure(let why):
            return .unavailable("no answer on port \(port) (\(why))")
        case .success(let status, _, let data):
            guard status == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rows = json["sessions"] as? [[String: Any]]
            else { return .unavailable("port \(port) answered \(status) to GET /api/sessions") }
            return .rows(rows)
        }
    }

    // MARK: - The report

    struct Report: Encodable, Equatable {
        var scope: String
        var daemon: Daemon
        /// The newest foreman in the scope: the first live one, else the
        /// newest archived one. Absent when the scope never had one.
        var predecessor: Foreman?
        /// Every live foreman in the scope, the caller's session left out.
        var liveForemen: [Foreman]
        var projects: [ProjectGoals]
        var sessions: [CrewSession]
        var worktrees: [Worktree]
    }

    struct Daemon: Encodable, Equatable {
        var answered: Bool
        /// The live sessions the daemon listed, in and out of the scope.
        var sessions: Int?
        /// Why there is no list.
        var reason: String?
    }

    struct Foreman: Encodable, Equatable {
        var id: String
        var name: String?
        /// `live` or `archived`.
        var state: String
        /// Epoch milliseconds, for an archived session.
        var archivedAt: Int?
        /// Epoch milliseconds, for a live session that printed something.
        var lastOutputAt: Int?
        /// The row's `mergedState`, for a live session.
        var mergedState: String?
        var cwd: String
        var scopeLabel: String?
        var note: String?
        var agentTranscript: String?
        /// The text of the transcript's last assistant message.
        var lastMessage: String?
        /// That line's `timestamp`, as Claude Code wrote it.
        var lastMessageAt: String?
        /// The file the message is in: `agentTranscript`, or the file its
        /// `continued-in` record names.
        var lastMessageTranscript: String?
        var lastMessageTruncated: Bool?
        /// Why `lastMessage` is absent.
        var noLastMessage: String?
    }

    struct ProjectGoals: Encodable, Equatable {
        var id: String
        var name: String
        var root: String
        var registered: Bool
        var knowledge: String
        /// False when the knowledge directory is missing or refused.
        var hasKnowledge: Bool
        /// The goals whose status is not `done`.
        var goals: [Goal]
    }

    struct Goal: Encodable, Equatable {
        var slug: String
        var status: String?
        var round: Int?
        var budget: Int?
        var proposals: Int
        var nextAction: String?
    }

    struct CrewSession: Encodable, Equatable {
        var id: String
        var name: String?
        var cwd: String
        /// The `goal`, `round`, `task` and `pr` labels the session carries.
        var labels: [String: String]
        var mergedState: String?
        /// Epoch milliseconds, when the linger clock holds the session.
        var heldSince: Int?
    }

    struct Worktree: Encodable, Equatable {
        var project: String
        var path: String
        /// Absent for a detached worktree.
        var branch: String?
    }

    /// Build the report for `scope`, a canonical directory. `ownSession` is
    /// the caller's session id, which is never its own predecessor.
    static func report(scope: String, live: Live, ownSession: String?) -> Report {
        let rows: [[String: Any]]
        let daemon: Daemon
        switch live {
        case .rows(let listed):
            rows = listed
            daemon = Daemon(answered: true, sessions: listed.count, reason: nil)
        case .unavailable(let reason):
            rows = []
            daemon = Daemon(answered: false, sessions: nil, reason: reason)
        }
        func isOwn(_ record: [String: Any]) -> Bool {
            guard let ownSession, let id = record["id"] as? String else { return false }
            return id.caseInsensitiveCompare(ownSession) == .orderedSame
        }
        func isForemanInScope(_ record: [String: Any]) -> Bool {
            let labels = record["labels"] as? [String: String] ?? [:]
            guard isForeman(labels), !isOwn(record), let cwd = record["cwd"] as? String else { return false }
            return ProjectStore.isPrefix(scope, of: claimedScope(labels: labels, cwd: cwd))
        }

        let liveForemen = rows.filter(isForemanInScope)
            .sorted { a, b in
                let (ta, tb) = (a["lastOutputAt"] as? Int ?? 0, b["lastOutputAt"] as? Int ?? 0)
                return ta != tb ? ta > tb : (a["id"] as? String ?? "") < (b["id"] as? String ?? "")
            }
            .compactMap { foreman($0, live: true) }
        var predecessor = liveForemen.first
        if predecessor == nil {
            predecessor = SessionArchive.readRecords().filter(isForemanInScope)
                .max { ($0["archivedAt"] as? Int ?? 0) < ($1["archivedAt"] as? Int ?? 0) }
                .flatMap { foreman($0, live: false) }
        }

        let projects = projects(under: scope, rows: rows)
        return Report(
            scope: scope, daemon: daemon, predecessor: predecessor, liveForemen: liveForemen,
            projects: projects.map(goals), sessions: crewSessions(under: scope, rows: rows),
            worktrees: projects.flatMap(worktrees)
        )
    }

    /// One foreman from a session row or an archive record, with the last
    /// assistant message of its transcript.
    private static func foreman(_ record: [String: Any], live: Bool) -> Foreman? {
        guard let id = record["id"] as? String, let cwd = record["cwd"] as? String else { return nil }
        let labels = record["labels"] as? [String: String] ?? [:]
        var foreman = Foreman(
            id: id, name: record["name"] as? String, state: live ? "live" : "archived",
            archivedAt: live ? nil : record["archivedAt"] as? Int,
            lastOutputAt: live ? record["lastOutputAt"] as? Int : nil,
            mergedState: live ? record["mergedState"] as? String : nil,
            cwd: cwd, scopeLabel: labels[SessionLabels.scopeKey], note: record["note"] as? String,
            agentTranscript: record["agentTranscript"] as? String
        )
        guard let transcript = foreman.agentTranscript else {
            foreman.noLastMessage = "no transcript: the session never ran claude"
            return foreman
        }
        switch TranscriptLastMessage.read(path: transcript) {
        case .message(let message):
            foreman.lastMessage = message.text
            foreman.lastMessageAt = message.timestamp
            foreman.lastMessageTranscript = message.path
            foreman.lastMessageTruncated = message.truncated
        case .none:
            let kib = TranscriptLastMessage.tailWindowBytes / 1024
            foreman.noLastMessage = "no assistant message in the last \(kib) KiB of \(transcript)"
        case .unreadable(let detail):
            foreman.noLastMessage = "transcript not found: \(detail)"
        }
        return foreman
    }

    /// The projects whose root is the scope or under it, by root: the
    /// registered ones, then the ones a live session row names.
    private static func projects(under scope: String, rows: [[String: Any]]) -> [ResolvedProject] {
        var byRoot: [String: ResolvedProject] = [:]
        for row in rows {
            guard let project = row["project"] as? [String: Any],
                  let id = project["id"] as? String, let name = project["name"] as? String,
                  let root = project["root"] as? String, ProjectStore.isPrefix(scope, of: root)
            else { continue }
            byRoot[root] = ResolvedProject(
                id: id, name: name, root: root, registered: false, knowledge: ProjectStore.defaultKnowledge
            )
        }
        for project in ProjectStore.load() where ProjectStore.isPrefix(scope, of: project.root) {
            byRoot[project.root] = ResolvedProject(
                id: project.id, name: project.name, root: project.root, registered: true,
                knowledge: project.knowledge
            )
        }
        return byRoot.values.sorted { ($0.root ?? "") < ($1.root ?? "") }
    }

    private static func goals(of project: ResolvedProject) -> ProjectGoals {
        let root = project.root ?? ""
        let summaries = KnowledgeFile.summaries(root: root, knowledge: project.knowledge)
        let goals = (summaries ?? []).filter { $0.status != "done" }.map { summary in
            Goal(
                slug: summary.slug ?? "", status: summary.status, round: summary.round, budget: summary.budget,
                proposals: summary.proposals ?? 0, nextAction: summary.nextAction
            )
        }
        return ProjectGoals(
            id: project.id, name: project.name, root: root, registered: project.registered,
            knowledge: project.knowledge, hasKnowledge: summaries != nil, goals: goals
        )
    }

    /// The labels of a crew session the report keeps, in print order.
    static let crewLabelKeys = [SessionLabels.goalKey, SessionLabels.roundKey, taskKey, SessionLabels.prKey]

    private static func crewSessions(under scope: String, rows: [[String: Any]]) -> [CrewSession] {
        let sessions: [CrewSession] = rows.compactMap { row in
            let labels = row["labels"] as? [String: String] ?? [:]
            guard labels[SessionLabels.goalKey] != nil,
                  let id = row["id"] as? String, let cwd = row["cwd"] as? String,
                  ProjectStore.isPrefix(scope, of: ProjectStore.canonicalRoot(cwd))
            else { return nil }
            return CrewSession(
                id: id, name: row["name"] as? String, cwd: cwd,
                labels: labels.filter { crewLabelKeys.contains($0.key) },
                mergedState: row["mergedState"] as? String, heldSince: row["heldSince"] as? Int
            )
        }
        return sessions.sorted { a, b in
            let (ka, kb) = (crewLabelKeys.map { a.labels[$0] ?? "" }, crewLabelKeys.map { b.labels[$0] ?? "" })
            return ka != kb ? ka.lexicographicallyPrecedes(kb) : a.id < b.id
        }
    }

    /// The worktrees of `project` under its `.claude/worktrees/`, by path,
    /// from `git worktree list --porcelain`. A root that is no checkout, or
    /// a machine with no `git`, has none.
    private static func worktrees(of project: ResolvedProject) -> [Worktree] {
        guard let root = project.root else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root, "worktree", "list", "--porcelain"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let listing = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let home = root + "/.claude/worktrees"
        return parseWorktrees(String(decoding: listing, as: UTF8.self))
            .map { (path: ProjectStore.canonicalRoot($0.path), branch: $0.branch) }
            .filter { $0.path != home && ProjectStore.isPrefix(home, of: $0.path) }
            .sorted { $0.path < $1.path }
            .map { Worktree(project: project.id, path: $0.path, branch: $0.branch) }
    }

    /// The `worktree <path>` blocks of `git worktree list --porcelain`,
    /// each with the branch of its `branch refs/heads/<name>` line; a
    /// detached worktree has none.
    static func parseWorktrees(_ listing: String) -> [(path: String, branch: String?)] {
        var worktrees: [(path: String, branch: String?)] = []
        for line in listing.split(separator: "\n") {
            if line.hasPrefix("worktree ") {
                worktrees.append((String(line.dropFirst("worktree ".count)), nil))
            } else if line.hasPrefix("branch "), !worktrees.isEmpty {
                let ref = String(line.dropFirst("branch ".count))
                let heads = "refs/heads/"
                worktrees[worktrees.count - 1].branch = ref.hasPrefix(heads) ? String(ref.dropFirst(heads.count)) : ref
            }
        }
        return worktrees
    }

    // MARK: - The text

    /// The report as lines, the four sections in order. Times print in
    /// `timeZone`, ISO 8601 with the offset.
    static func lines(_ report: Report, timeZone: TimeZone = .current) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        func time(_ millis: Int) -> String {
            formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
        }

        var lines = ["scope: \(report.scope)"]
        if report.daemon.answered {
            lines.append("daemon: \(report.daemon.sessions ?? 0) live sessions read from GET /api/sessions")
        } else {
            lines.append("daemon: \(report.daemon.reason ?? "no answer"); live sessions not read, files only")
        }

        lines += ["", "PREDECESSOR"]
        if report.liveForemen.count > 1 {
            lines.append("conflict: \(report.liveForemen.count) live foremen share this scope")
        }
        let foremen = report.liveForemen.isEmpty ? [report.predecessor].compactMap { $0 } : report.liveForemen
        if foremen.isEmpty {
            lines.append("none: no session labelled crew:foreman in this scope")
        }
        for foreman in foremen {
            var head = "\(foreman.id)  \(foreman.name ?? "(no name)")  \(foreman.state)"
            if let state = foreman.mergedState { head += ", \(state)" }
            if let at = foreman.archivedAt { head += " \(time(at))" }
            if let at = foreman.lastOutputAt { head += ", last output \(time(at))" }
            lines.append(head)
            lines.append("  cwd: \(foreman.cwd)")
            if let scope = foreman.scopeLabel { lines.append("  scope label: \(scope)") }
            lines.append("  note: \(foreman.note ?? "none")")
            if let transcript = foreman.lastMessageTranscript ?? foreman.agentTranscript {
                lines.append("  transcript: \(transcript)")
            }
            if let message = foreman.lastMessage {
                lines.append("  last message\(foreman.lastMessageAt.map { ", \($0)" } ?? ""):")
                // A bar on every line, so a blank line of the message is
                // not read as the end of the section.
                lines += message.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? "  |" : "  | \($0)" }
                if foreman.lastMessageTruncated == true {
                    lines.append("  [cut at \(TranscriptLastMessage.maxCharacters) characters]")
                }
            } else {
                lines.append("  last message: none (\(foreman.noLastMessage ?? "not read"))")
            }
        }

        lines += ["", "GOALS NOT DONE"]
        if report.projects.isEmpty {
            lines.append("none: no project root under this scope")
        }
        for project in report.projects {
            lines.append("\(project.id)  \(project.root)  \(project.registered ? "registered" : "discovered")")
            if !project.hasKnowledge {
                lines.append("  no goal folder: \(project.root)/\(project.knowledge) does not open")
            } else if project.goals.isEmpty {
                lines.append("  no goal that is not done")
            }
            for goal in project.goals {
                let round = goal.round.map { n in "\(n) of \(goal.budget.map(String.init) ?? "?")" } ?? "none"
                lines.append(
                    "  \(goal.slug)  \(goal.status ?? "unknown")  Round: \(round)  proposals: \(goal.proposals)"
                )
                let next = goal.nextAction?.split(separator: "\n").first.map(String.init)
                lines.append("    next: \(next ?? "none")")
            }
        }

        lines += ["", "CREW SESSIONS"]
        if !report.daemon.answered {
            lines.append("not read: the daemon did not answer")
        } else if report.sessions.isEmpty {
            lines.append("none: no live session with a goal label in this scope")
        }
        for session in report.sessions {
            let labels = crewLabelKeys.compactMap { key in session.labels[key].map { "\(key):\($0)" } }
            var line = "\(session.id)  \(session.name ?? "(no name)")  \(session.mergedState ?? "unknown")  "
                + labels.joined(separator: " ")
            if let held = session.heldSince { line += "  held since \(time(held))" }
            lines.append(line)
        }

        lines += ["", "WORKTREES"]
        if report.worktrees.isEmpty {
            lines.append("none: no worktree under a project's .claude/worktrees/")
        }
        var heading: String?
        for worktree in report.worktrees {
            if worktree.project != heading {
                lines.append(worktree.project)
                heading = worktree.project
            }
            lines.append("  \(worktree.path)  \(worktree.branch ?? "(detached)")")
        }
        return lines
    }

    static func json(_ report: Report) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    // MARK: - The command

    /// `catch-up`. `live` reads the session list, `ownSession` is the
    /// caller's session id, and `timeZone` is the zone the times print in;
    /// a test passes all three.
    static func catchUp(
        _ args: [String],
        live: () -> Live = ForemanCommand.liveSessions,
        ownSession: String? = ProcessInfo.processInfo.environment["KITTERM_SESSION_ID"],
        timeZone: TimeZone = .current,
        out: (String) -> Void
    ) throws {
        var scopeOption: String?
        var asJSON = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--json":
                asJSON = true
            case "--scope":
                guard index + 1 < args.count else { throw CLIError.usage("--scope needs a value\n\(usage)") }
                scopeOption = args[index + 1]
                index += 1
            case _ where arg.hasPrefix("--scope="):
                scopeOption = String(arg.dropFirst("--scope=".count))
            default:
                throw CLIError.usage("unknown argument \(arg)\n\(usage)")
            }
            index += 1
        }
        let scope = try ProjectCommand.canonicalRoot(scopeOption ?? FileManager.default.currentDirectoryPath)
        let report = report(scope: scope, live: live(), ownSession: ownSession)
        if asJSON {
            out(try json(report))
        } else {
            for line in lines(report, timeZone: timeZone) { out(line) }
        }
    }
}
