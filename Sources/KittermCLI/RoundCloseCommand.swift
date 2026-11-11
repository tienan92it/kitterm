#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import KittermDaemon

/// `kitterm round close <root> <slug>` — every step of a round after the
/// crew's `DONE` note that needs no judgment
/// (`docs/goals/round-commands/plan.md`, row 3).
///
/// The steps, in order. Each step reuses what is already there, so a second
/// run after a partial failure continues from what exists:
///
/// 1. `daemon`: `GET /api/sessions`.
/// 2. `worktree`: `<root>/.claude/worktrees/<slug>`, its branch, and the
///    goal folder in it (a chore: the `chores/` folder).
/// 3. `sessions`: the round is `--round`, else the `round:` label of the
///    live sessions that carry `crew:<slug>`, else of the newest archive
///    that does. The round's sessions are the live ones and the archived
///    ones with `crew:<slug>` and `round:<R>` (a chore: `crew:<slug>`).
/// 4. `archive`: `POST /api/sessions/<id>/archive` for each live one.
/// 5. `bills`: `ArchiveCommand.answer`, the reader of `kitterm archive
///    cost`, for each session, again every 2 s until every bill reads or
///    `--bill-timeout` ends; a session still without one gets
///    `- Cost: none recorded (<reason>)`.
/// 6. `record`: `rounds/NNN.md`, written once and never rewritten
///    (`RoundRecord.text`). `Started` is the first timestamp of the
///    earliest session's Claude Code transcript, `Ended` the time of the
///    run. The `- Foreman:` line prices the turns of the foreman's own
///    transcript between the two (`TranscriptEstimateCache.estimate(
///    forTranscriptAt:from:to:)`).
/// 7. `state`: `RoundRecord.closeState` on `STATE.md`.
/// 8. `commit`, with `--commit` only: refused while a marker remains in the
///    record, then one commit of the goal folder and a push, never with
///    force.
///
/// A chore writes `chores/<ISO date>-<slug>.md` in place of steps 6 and 7.
/// The command never merges, never marks a pull request ready, and runs
/// no floor.
extension RoundCommand {
    /// How long one wait between two bill reads lasts.
    static let billRetrySeconds: TimeInterval = 2

    struct CloseOptions: Equatable {
        var root: String
        var slug: String
        var chore = false
        var commit = false
        var round: Int?
        var billTimeout: TimeInterval = 60
        var foremanSession: String?
        var knowledge: String?
        var port: Int?

        static func parse(_ args: [String]) throws -> CloseOptions {
            var positional: [String] = []
            var options = CloseOptions(root: "", slug: "")
            var index = 0
            func value(_ flag: String) throws -> String {
                index += 1
                guard index < args.count else { throw CLIError.usage("\(flag) needs a value\n\(usage)") }
                return args[index]
            }
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--chore": options.chore = true
                case "--commit": options.commit = true
                case "--knowledge": options.knowledge = try value(arg)
                case "--round":
                    let text = try value(arg)
                    guard let number = Int(text), number > 0 else {
                        throw CLIError.usage("--round takes a round number, not \(text)\n\(usage)")
                    }
                    options.round = number
                case "--bill-timeout":
                    let text = try value(arg)
                    guard let seconds = TimeInterval(text), seconds >= 0, seconds.isFinite else {
                        throw CLIError.usage("--bill-timeout takes seconds, not \(text)\n\(usage)")
                    }
                    options.billTimeout = seconds
                case "--foreman-session":
                    let text = try value(arg)
                    guard let id = UUID(uuidString: text) else {
                        throw CLIError.usage("--foreman-session takes a session id (a UUID), not \(text)\n\(usage)")
                    }
                    options.foremanSession = id.uuidString
                case "--port":
                    let text = try value(arg)
                    guard let number = Int(text), (1...65535).contains(number) else {
                        throw CLIError.usage("--port takes a port number, not \(text)\n\(usage)")
                    }
                    options.port = number
                default:
                    if arg.hasPrefix("-") { throw CLIError.unknownOption("kitterm: unknown option \(arg)\n\(usage)") }
                    positional.append(arg)
                }
                index += 1
            }
            guard positional.count == 2 else { throw CLIError.usage(usage) }
            guard ProjectStore.isValidID(positional[1]) else {
                throw CLIError.usage("the slug \(positional[1]) is not a kebab word (a-z, 0-9, -)\n\(usage)")
            }
            guard !(options.chore && options.round != nil) else {
                throw CLIError.usage("a chore has no round; drop --round\n\(usage)")
            }
            options.root = positional[0]
            options.slug = positional[1]
            return options
        }
    }

    /// What a close wrote.
    struct Closed: Equatable {
        /// The record, or the chore file.
        var file: String
        var round: Int?
        var sessions: [String]
        var markers: Int
        var commit: String?

        var lines: [String] {
            var lines = ["file     \(file)"]
            if let round { lines.append("round    \(round)") }
            lines.append("sessions \(sessions.joined(separator: ", "))")
            lines.append("markers  \(markers)")
            if let commit { lines.append("commit   \(commit)") }
            return lines
        }
    }

    /// One session of the round as the close finds it.
    private struct Found {
        var id: UUID
        var labels: [String: String]
        var live: Bool
    }

    static func close(_ options: CloseOptions, runner: @escaping Runner, progress: (String) -> Void) throws -> Closed {
        let steps = Steps(command: "close", runner: runner)
        let fail = steps.fail
        @discardableResult
        func tool(_ step: String, _ name: String, _ args: [String], in directory: String) throws -> String {
            try steps.tool(step, name, args, in: directory)
        }

        // 1. daemon
        guard let port = options.port ?? KittermMain.readPort() else {
            throw fail("daemon", "no port file at \(DaemonPaths.portFile.path); start the daemon or pass --port")
        }
        let client = MCPHTTPClient(port: port)
        let rows = try sessions(client).get { fail("daemon", $0) }

        // 2. worktree
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: options.root, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw fail("worktree", "\(options.root) is not a directory") }
        let root = ProjectStore.canonicalRoot(
            try tool("worktree", "git", ["-C", options.root, "rev-parse", "--show-toplevel"], in: options.root)
        )
        let worktree = ProjectStore.canonicalRoot(root + "/.claude/worktrees/" + options.slug)
        guard FileManager.default.fileExists(atPath: worktree) else {
            throw fail("worktree", "no worktree at \(worktree); `kitterm round open` makes it")
        }
        let branch = try tool("worktree", "git", ["-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"], in: worktree)
        let knowledge = options.knowledge ?? ProjectStore.load().first { $0.root == root }?.knowledge
            ?? ProjectStore.defaultKnowledge
        let folder = knowledge + "/" + (options.chore ? "chores" : options.slug)
        let folderPath = worktree + "/" + folder
        let stateURL = URL(fileURLWithPath: folderPath + "/STATE.md")
        if !options.chore, !FileManager.default.fileExists(atPath: stateURL.path) {
            throw fail("worktree", "no \(stateURL.path)")
        }

        // 3. sessions
        let crew = options.slug
        func belongs(_ labels: [String: String]) -> Bool {
            labels[ForemanCommand.crewKey] == crew && (options.chore || labels[SessionLabels.goalKey] == crew)
        }
        let live = rows.compactMap { row -> Found? in
            guard let text = row["id"] as? String, let id = UUID(uuidString: text), belongs(labels(row)) else { return nil }
            return Found(id: id, labels: labels(row), live: true)
        }
        let archived = SessionArchive.readRecords().compactMap { json -> (Found, Int)? in
            guard let text = json["id"] as? String, let id = UUID(uuidString: text),
                  let labels = json["labels"] as? [String: String], belongs(labels) else { return nil }
            return (Found(id: id, labels: labels, live: false), json["archivedAt"] as? Int ?? 0)
        }
        var round: Int?
        if !options.chore {
            let liveRounds = Set(live.compactMap { $0.labels[SessionLabels.roundKey].flatMap(Int.init) })
            guard liveRounds.count <= 1 else {
                throw fail("sessions", "live sessions with crew:\(crew) carry rounds \(liveRounds.sorted()); pass --round")
            }
            round = options.round ?? liveRounds.first
                ?? archived.max { $0.1 < $1.1 }?.0.labels[SessionLabels.roundKey].flatMap(Int.init)
            guard round != nil else {
                throw fail("sessions", "no live or archived session carries crew:\(crew) with a round: label")
            }
        }
        func inRound(_ found: Found) -> Bool {
            options.chore || found.labels[SessionLabels.roundKey] == round.map(String.init)
        }
        var found = live.filter(inRound)
        for (archive, _) in archived where inRound(archive) && !found.contains(where: { $0.id == archive.id }) {
            found.append(archive)
        }
        guard !found.isEmpty else {
            throw fail("sessions", "no live or archived session carries crew:\(crew)"
                + (round.map { " and round:\($0)" } ?? ""))
        }
        let roundText = round.map { " round \($0)" } ?? ""
        progress("round close: \(options.slug)\(roundText): \(found.count) session(s)")

        // 4. archive
        for session in found where session.live {
            let call = MCPTools.Call(method: "POST", path: "/api/sessions/\(session.id.uuidString)/archive")
            switch client.send(call, timeout: daemonTimeoutSeconds) {
            case .failure(let why):
                throw fail("archive", "no answer on port \(port) (\(why))")
            case .success(let status, _, let data):
                guard (200..<300).contains(status) else {
                    throw fail("archive", "port \(port) answered \(status) to POST \(call.path): "
                        + String(decoding: data.prefix(200), as: UTF8.self))
                }
            }
            steps.exists.append("archive \(session.id.uuidString)")
            progress("round close: archived \(session.id.uuidString)")
        }

        // 5. bills
        var answers: [UUID: ArchiveCommand.Answer] = [:]
        let deadline = Date().addingTimeInterval(options.billTimeout)
        while true {
            for session in found {
                if case .bill = answers[session.id] { continue }
                answers[session.id] = ArchiveCommand.answer(for: session.id)
            }
            let waiting = found.filter { if case .bill = answers[$0.id] { return false } else { return true } }
            let left = deadline.timeIntervalSinceNow
            if waiting.isEmpty || left <= 0 { break }
            progress("round close: waiting on \(waiting.count) bill(s), \(Int(left.rounded(.up))) s left")
            usleep(useconds_t(min(billRetrySeconds, left) * 1_000_000))
        }

        // The sessions in the order they began; one with no transcript last.
        let dated = found.map { session -> (found: Found, record: RoundRecord.Session, start: Date?) in
            let join = SessionArchive.agentJoin(of: session.id)
            var model: String?
            if let path = join?.transcriptPath, case .model(let id) = TranscriptModel.read(path: path) { model = id }
            let start = join.flatMap { TranscriptEstimateCache.firstTimestamp(ofTranscriptAt: $0.transcriptPath) }
            let line = ArchiveCommand.line(for: answers[session.id] ?? .noSuchArchive)
            return (session, RoundRecord.Session(id: session.id.uuidString, model: model, costLine: line), start)
        }.sorted { lhs, rhs in
            switch (lhs.start, rhs.start) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.found.id.uuidString < rhs.found.id.uuidString
            }
        }
        let sessionRows = dated.map { $0.record }
        let labelled = { (key: String) in dated.lazy.compactMap { $0.found.labels[key] }.first }
        guard let pr = labelled(SessionLabels.prKey).flatMap(Int.init) else {
            throw fail("sessions", "no session of the round carries a pr: label")
        }
        let now = Date()

        // 6 and 7 for a chore: the one file, no record, no STATE.md.
        let file: String
        if options.chore {
            file = folderPath + "/\(RoundRecord.day(now))-\(options.slug).md"
            if FileManager.default.fileExists(atPath: file) {
                progress("round close: reused \(file)")
            } else {
                try write(RoundRecord.choreLine(day: RoundRecord.day(now), sessions: sessionRows, pr: pr), to: file, step: "chore", steps: steps)
                progress("round close: wrote \(file)")
            }
        } else {
            let round = round!
            let task = labelled(ForemanCommand.taskKey) ?? options.slug
            file = folderPath + String(format: "/rounds/%03d.md", round)
            let result = try tool("record", "git", ["-C", worktree, "rev-parse", "--short=7", "HEAD"], in: worktree)
            if FileManager.default.fileExists(atPath: file) {
                progress("round close: reused \(file)")
            } else {
                guard let started = dated.compactMap { $0.start }.min() else {
                    throw fail("record", "no session of the round has a Claude Code transcript with a timestamp, "
                        + "so the record has no Started")
                }
                let base: String
                if round == 1 {
                    let name = KnowledgeBase.baseBranch { steps.probe($0, in: root) }
                    let merge = try tool("record", "git", ["-C", worktree, "merge-base", "HEAD", "origin/\(name)"], in: worktree)
                    base = try tool("record", "git", ["-C", worktree, "rev-parse", "--short=7", merge], in: worktree)
                } else {
                    let previous = folderPath + String(format: "/rounds/%03d.md", round - 1)
                    guard let text = try? String(contentsOfFile: previous, encoding: .utf8),
                          let sha = GoalLedger.parse(text, number: round - 1).result else {
                        throw fail("record", "\(previous) names no Result sha, so round \(round) has no Base")
                    }
                    base = sha
                }
                let foreman = foremanLine(
                    session: options.foremanSession ?? ProcessInfo.processInfo.environment["KITTERM_SESSION_ID"],
                    rows: rows, from: started, to: now
                )
                let header = RoundRecord.Header(
                    round: round, task: task, goal: options.slug, started: started, ended: now,
                    sessions: sessionRows, base: base, result: result, branch: branch, pr: pr, foremanLine: foreman
                )
                try write(RoundRecord.text(header), to: file, step: "record", steps: steps)
                progress("round close: wrote \(file)")
            }
            steps.exists.append("record \(file)")

            // 7. state
            let state: String
            do {
                state = try String(contentsOf: stateURL, encoding: .utf8)
            } catch {
                throw fail("state", "cannot read \(stateURL.path): \(error.localizedDescription)")
            }
            let updated: String
            do {
                updated = try RoundRecord.closeState(
                    state, task: task, round: round, sha: result, pr: pr, day: RoundRecord.day(now)
                )
            } catch let error as RoundRecord.StateError {
                throw fail("state", error.reason)
            }
            if updated != state {
                try write(updated, to: stateURL.path, step: "state", steps: steps)
                progress("round close: updated \(stateURL.path)")
            }
        }

        // 8. commit
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let markers = RoundRecord.markerCount(text)
        var commit: String?
        if options.commit {
            guard markers == 0 else {
                throw fail("commit", "\(file) still holds \(markers) line(s) with \(RoundRecord.marker); replace them first")
            }
            try tool("commit", "git", ["-C", worktree, "add", "--", folder], in: worktree)
            let staged = runner("git", ["-C", worktree, "diff", "--cached", "--quiet", "--", folder], worktree)
            if staged?.status == 1 {
                let message = options.chore ? "\(options.slug): chore record" : "\(options.slug): round \(round!) record"
                try tool("commit", "git", ["-C", worktree, "commit", "--quiet", "-m", message, "--", folder], in: worktree)
                progress("round close: committed \(message)")
            }
            try tool("push", "git", ["-C", worktree, "push", "--quiet", "origin", "refs/heads/\(branch):refs/heads/\(branch)"], in: worktree)
            commit = try tool("push", "git", ["-C", worktree, "rev-parse", "HEAD"], in: worktree)
        }
        return Closed(file: file, round: round, sessions: sessionRows.map { $0.id }, markers: markers, commit: commit)
    }

    /// The `- Foreman:` line: the turns of the session `id`'s transcript
    /// from `from` to `to`. The transcript is the live row's join, else
    /// the archive's.
    static func foremanLine(session id: String?, rows: [[String: Any]], from: Date, to: Date) -> String {
        guard let id, let uuid = UUID(uuidString: id) else { return RoundRecord.foremanNone("no foreman session") }
        let row = rows.first { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == uuid }
        guard let path = row?["agentTranscript"] as? String ?? SessionArchive.agentJoin(of: uuid)?.transcriptPath else {
            return RoundRecord.foremanNone("no transcript")
        }
        return RoundRecord.foremanLine(TranscriptEstimateCache.estimate(
            forTranscriptAt: path,
            from: Int64(from.timeIntervalSince1970 * 1000), to: Int64(to.timeIntervalSince1970 * 1000)
        ))
    }

    private static func write(_ text: String, to path: String, step: String, steps: Steps) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw steps.fail(step, "cannot write \(path): \(error.localizedDescription)")
        }
    }
}
