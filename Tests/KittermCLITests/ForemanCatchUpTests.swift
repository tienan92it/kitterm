import Foundation
import KittermDaemon
import XCTest

@testable import KittermCLI

/// `kitterm foreman catch-up` — capability 2 of `foreman-scope`. One
/// fixture state directory holds two scopes, `scope-one` and `scope-two`,
/// each with a registered project, a goal package, and archived foremen.
/// The command for one scope must print that scope's predecessor, goals,
/// crew sessions and worktrees, and no line from the other scope.
final class ForemanCatchUpTests: XCTestCase {
    private var stateDir: URL!
    private var one: String!
    private var two: String!

    private let oldForemanOne = "11111111-1111-4111-8111-111111111111"
    private let foremanOne = "22222222-2222-4222-8222-222222222222"
    private let foremanTwo = "33333333-3333-4333-8333-333333333333"
    private let crewOne = "44444444-4444-4444-8444-444444444444"
    private let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-foreman-catch-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        one = try directory("work/scope-one")
        two = try directory("work/scope-two")

        // Scope one: the project `app`, a checkout with one worktree.
        let app = try directory("work/scope-one/app")
        try goal(app, "ship-it", status: "active", round: "2 of 3 in this budget (first budget)",
                 proposals: ["- Raise the budget of `ship-it`."],
                 next: "Round 3: `the-next-item`.\nWait for CI first.\n\nA second paragraph.")
        try goal(app, "old-work", status: "done", round: "3 of 3", next: "None.")
        try goal(app, "parked", status: "waiting", round: nil, next: nil)
        try git(app, "init", "-q", "-b", "main")
        try git(app, "add", "-A")
        try git(app, "commit", "-q", "-m", "fixture")
        try git(app, "worktree", "add", "-q", "-b", "feature/x", ".claude/worktrees/feature")
        try ProjectCommand.run(["add", app]) { _ in }

        // Scope two: the project `two-service`, with a goal and a newer foreman.
        let service = try directory("work/scope-two/two-service")
        try goal(service, "two-goal", status: "active", round: "1 of 3", next: "Round 2: `two-item`.")
        try ProjectCommand.run(["add", service]) { _ in }

        let transcript = stateDir.appendingPathComponent("one.jsonl").path
        try [
            assistantLine(text: "Round 3 is done.\n\nThe human said: merge PR 12 first."),
            #"{"type":"assistant","timestamp":"2026-09-25T03:28:06.062Z","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#,
            #"{"type":"cost-state","totalCostUSD":1,"totalDuration":1,"totalAPIDuration":1,"totalLinesAdded":0,"totalLinesRemoved":0,"modelUsage":{}}"#,
        ].joined(separator: "\n").appending("\n").write(toFile: transcript, atomically: true, encoding: .utf8)
        let transcriptTwo = stateDir.appendingPathComponent("two.jsonl").path
        try (assistantLine(text: "two-secret words") + "\n").write(toFile: transcriptTwo, atomically: true, encoding: .utf8)

        try archive(oldForemanOne, name: "foreman", labels: ["crew": "foreman"], cwd: one,
                    note: "The first foreman of scope one.", archivedAt: 1_790_300_000_000)
        try archive(foremanOne, name: "foreman", labels: ["crew": "foreman"], cwd: one,
                    note: "Foreman for scope one. The human wants PR 12 merged first.",
                    archivedAt: 1_790_306_887_090, transcript: transcript)
        try archive(foremanTwo, name: "foreman", labels: ["crew": "foreman"], cwd: two,
                    note: "two-note", archivedAt: 1_790_320_000_000, transcript: transcriptTwo)
        // A crew of a goal named `foreman-…`, newer than every foreman of
        // scope one: `crew:foreman-scope` beside `goal:` is not a foreman.
        try archive(crewOne, name: "foreman-scope round 1",
                    labels: ["crew": "foreman-scope", "goal": "foreman-scope", "round": "1"],
                    cwd: app, note: nil, archivedAt: 1_790_310_000_000)
    }

    override func tearDownWithError() throws {
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
    }

    // MARK: - Fixture

    /// A directory under the state directory, as its real path: the kernel
    /// reports a cwd that way, so an archive's `cwd` holds one.
    private func directory(_ name: String) throws -> String {
        let url = stateDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ProjectStore.canonicalRoot(url.path)
    }

    private func goal(
        _ project: String, _ slug: String, status: String, round: String?, proposals: [String] = [],
        next: String?
    ) throws {
        let folder = URL(fileURLWithPath: project).appendingPathComponent("docs/goals/\(slug)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var state = "# STATE: \(slug)\n\n- Status: \(status)\n"
        if let round { state += "- Round: \(round)\n" }
        state += "\n## Proposals waiting on the human\n\n" + (proposals.isEmpty ? "None." : proposals.joined(separator: "\n")) + "\n"
        if let next { state += "\n## Next action\n\n\(next)\n" }
        try state.write(to: folder.appendingPathComponent("STATE.md"), atomically: true, encoding: .utf8)
    }

    private func git(_ root: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.test",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.test",
        ]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        waitForExit(of: process)
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
    }

    private func assistantLine(text: String) throws -> String {
        let line: [String: Any] = [
            "type": "assistant", "timestamp": "2026-09-25T03:28:05.703Z",
            "message": ["model": "claude-opus-5-5", "content": [["type": "text", "text": text]]] as [String: Any],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }

    private func archive(
        _ id: String, name: String, labels: [String: String], cwd: String, note: String?, archivedAt: Int,
        transcript: String? = nil
    ) throws {
        var record: [String: Any] = [
            "version": 1, "id": id, "name": name, "labels": labels, "cwd": cwd, "shell": "/bin/zsh",
            "archivedAt": archivedAt, "commands": [[String: Any]](), "marks": [[String: Any]](),
        ]
        if let note { record["note"] = note }
        if let transcript {
            record["agentSessionId"] = "agent-\(id)"
            record["agentTranscript"] = transcript
        }
        let dir = DaemonPaths.archiveDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record).write(to: dir.appendingPathComponent("archive.json"))
    }

    /// One row of `GET /api/sessions`, the fields the command reads.
    private func row(
        _ id: String, name: String, labels: [String: String], cwd: String, state: String = "working",
        lastOutputAt: Int? = nil, heldSince: Int? = nil, note: String? = nil, project: [String: Any]? = nil
    ) -> [String: Any] {
        var row: [String: Any] = ["id": id, "name": name, "labels": labels, "cwd": cwd, "mergedState": state]
        if let lastOutputAt { row["lastOutputAt"] = lastOutputAt }
        if let heldSince { row["heldSince"] = heldSince }
        if let note { row["note"] = note }
        if let project { row["project"] = project }
        return row
    }

    private func run(
        _ args: [String], live: ForemanCommand.Live? = nil, ownSession: String? = nil
    ) throws -> [String] {
        var lines: [String] = []
        if let live {
            try ForemanCommand.catchUp(args, live: { live }, ownSession: ownSession, timeZone: utc) { lines.append($0) }
        } else {
            try ForemanCommand.catchUp(args, ownSession: ownSession, timeZone: utc) { lines.append($0) }
        }
        return lines
    }

    /// Nothing of scope two may be on a line of scope one's report.
    private func assertNothingOfScopeTwo(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        let words = [
            "scope-two", "two-service", "two-goal", "two-item", "two-note", "two-secret", foremanTwo,
            "55555555-5555-4555-8555-555555555555", "66666666-6666-4666-8666-666666666666",
        ]
        for word in words {
            XCTAssertFalse(
                lines.contains { $0.contains(word) }, "\(word) is outside the scope", file: file, line: line
            )
        }
    }

    // MARK: - The files, with no daemon

    /// The whole report of scope one from the files alone: the fixture
    /// state directory has no port file, so the real reader says so.
    func testTheReportOfOneScopeHoldsThatScopeOnly() throws {
        let lines = try run(["--scope", one])

        XCTAssertEqual(lines, [
            "scope: \(one!)",
            "daemon: no port file at \(DaemonPaths.portFile.path); live sessions not read, files only",
            "",
            "PREDECESSOR",
            "\(foremanOne)  foreman  archived 2026-09-25T03:28:07Z",
            "  cwd: \(one!)",
            "  note: Foreman for scope one. The human wants PR 12 merged first.",
            "  transcript: \(stateDir.path)/one.jsonl",
            "  last message, 2026-09-25T03:28:05.703Z:",
            "  | Round 3 is done.",
            "  |",
            "  | The human said: merge PR 12 first.",
            "",
            "GOALS NOT DONE",
            "app  \(one!)/app  registered",
            "  ship-it  active  Round: 2 of 3  proposals: 1",
            "    next: Round 3: `the-next-item`. Wait for CI first.",
            "  parked  waiting  Round: none  proposals: 0",
            "    next: none",
            "",
            "CREW SESSIONS",
            "not read: the daemon did not answer",
            "",
            "WORKTREES",
            "app",
            "  \(one!)/app/.claude/worktrees/feature  feature/x",
        ])
        assertNothingOfScopeTwo(lines)
    }

    func testTheOtherScopeHasItsOwnPredecessorAndNoWorktree() throws {
        let lines = try run(["--scope=\(two!)"])

        XCTAssertTrue(lines.contains("\(foremanTwo)  foreman  archived 2026-09-25T07:06:40Z"), "\(lines)")
        XCTAssertTrue(lines.contains("  | two-secret words"))
        XCTAssertTrue(lines.contains("  two-goal  active  Round: 1 of 3  proposals: 0"))
        XCTAssertTrue(lines.contains("none: no worktree under a project's .claude/worktrees/"))
        for word in ["scope-one", "ship-it", "PR 12", foremanOne, oldForemanOne] {
            XCTAssertFalse(lines.contains { $0.contains(word) }, "\(word) is outside the scope")
        }
    }

    /// The daemon-down path through the real reader: a port file that
    /// names a port nothing listens on.
    func testADaemonThatDoesNotAnswerIsOneLineAndTheFilesGoOn() throws {
        try "1".write(to: DaemonPaths.portFile, atomically: true, encoding: .utf8)

        let lines = try run(["--scope", one])

        XCTAssertTrue(lines[1].hasPrefix("daemon: no answer on port 1 ("), lines[1])
        XCTAssertTrue(lines[1].hasSuffix("; live sessions not read, files only"), lines[1])
        XCTAssertTrue(lines.contains("\(foremanOne)  foreman  archived 2026-09-25T03:28:07Z"))
        XCTAssertTrue(lines.contains("  ship-it  active  Round: 2 of 3  proposals: 1"))
        XCTAssertTrue(lines.contains("not read: the daemon did not answer"))
        assertNothingOfScopeTwo(lines)
    }

    func testAnArchivedForemanWithNoTranscriptSaysSo() throws {
        try FileManager.default.removeItem(at: DaemonPaths.archiveDirectory.appendingPathComponent(foremanOne))

        let lines = try run(["--scope", one])

        XCTAssertTrue(lines.contains("\(oldForemanOne)  foreman  archived 2026-09-25T01:33:20Z"), "\(lines)")
        XCTAssertTrue(lines.contains("  last message: none (no transcript: the session never ran claude)"))
    }

    /// The `scope:` label decides before the cwd, in both directions.
    func testTheScopeLabelWinsOverTheCwd() throws {
        let labelledOne = "77777777-7777-4777-8777-777777777777"
        let labelledTwo = "88888888-8888-4888-8888-888888888888"
        try archive(labelledOne, name: "foreman-one", labels: ["crew": "foreman-one", "scope": one], cwd: two,
                    note: "labelled into scope one", archivedAt: 1_790_330_000_000)
        try archive(labelledTwo, name: "foreman", labels: ["crew": "foreman", "scope": two], cwd: one,
                    note: "two-note", archivedAt: 1_790_340_000_000)

        let lines = try run(["--scope", one])

        XCTAssertTrue(lines.contains { $0.hasPrefix("\(labelledOne)  foreman-one  archived ") }, "\(lines)")
        XCTAssertTrue(lines.contains("  scope label: \(one!)"))
        XCTAssertFalse(lines.contains { $0.contains(labelledTwo) })
    }

    // MARK: - The live sessions

    private var liveRows: [[String: Any]] {
        [
            // The caller's own pane, and a foreman of the other scope.
            row("99999999-9999-4999-8999-999999999999", name: "foreman", labels: ["crew": "foreman"], cwd: one),
            row("55555555-5555-4555-8555-555555555555", name: "foreman", labels: ["crew": "foreman"], cwd: two,
                lastOutputAt: 1_790_900_000_000, note: "two-note"),
            // A live foreman of scope one, in a subdirectory of it.
            row("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", name: "foreman", labels: ["crew": "foreman"],
                cwd: one + "/app", state: "needs-input", lastOutputAt: 1_790_844_482_000, note: "the live one"),
            // The crews: one per scope, and a session with no goal label.
            row("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", name: "ship-it round 3",
                labels: ["crew": "ship-it", "goal": "ship-it", "round": "3", "task": "the-next-item", "pr": "12", "model": "m"],
                cwd: one + "/app/.claude/worktrees/feature", heldSince: 1_790_844_000_000,
                project: ["id": "app", "name": "app", "root": one + "/app", "registered": true]),
            row("66666666-6666-4666-8666-666666666666", name: "two-goal round 2",
                labels: ["crew": "two-goal", "goal": "two-goal", "round": "2"], cwd: two + "/two-service",
                project: ["id": "two-service", "name": "two-service", "root": two + "/two-service", "registered": true]),
            row("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC", name: "a shell", labels: [:], cwd: one + "/tool",
                state: "idle", project: ["id": "tool", "name": "tool", "root": one + "/tool", "registered": false]),
        ]
    }

    func testALiveForemanIsThePredecessorAndTheCrewsOfTheScopeAreListed() throws {
        _ = try directory("work/scope-one/tool")

        let lines = try run(
            ["--scope", one], live: .rows(liveRows), ownSession: "99999999-9999-4999-8999-999999999999"
        )

        XCTAssertEqual(Array(lines[0..<8]), [
            "scope: \(one!)",
            "daemon: 6 live sessions read from GET /api/sessions",
            "",
            "PREDECESSOR",
            "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA  foreman  live, needs-input, last output 2026-10-01T08:48:02Z",
            "  cwd: \(one!)/app",
            "  note: the live one",
            "  last message: none (no transcript: the session never ran claude)",
        ])
        XCTAssertFalse(lines.contains { $0.contains(foremanOne) }, "a live foreman is newer than an archive")
        XCTAssertFalse(lines.contains { $0.hasPrefix("99999999") }, "the caller is not its own predecessor")
        XCTAssertFalse(lines.contains { $0.hasPrefix("conflict:") })

        let crew = try XCTUnwrap(lines.firstIndex(of: "CREW SESSIONS"))
        XCTAssertEqual(Array(lines[crew...]), [
            "CREW SESSIONS",
            "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB  ship-it round 3  working  "
                + "goal:ship-it round:3 task:the-next-item pr:12  held since 2026-10-01T08:40:00Z",
            "",
            "WORKTREES",
            "app",
            "  \(one!)/app/.claude/worktrees/feature  feature/x",
        ])
        // A project a live row discovered, with no goal folder and no git.
        XCTAssertTrue(lines.contains("tool  \(one!)/tool  discovered"), "\(lines)")
        XCTAssertTrue(lines.contains("  no goal folder: \(one!)/tool/docs/goals does not open"))
        assertNothingOfScopeTwo(lines)
    }

    func testSeveralLiveForemenInOneScopeAreAllListedAsAConflict() throws {
        let second = row("DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD", name: "foreman-b", labels: ["crew": "foreman-b"],
                         cwd: one, lastOutputAt: 1_790_844_500_000)
        // A live crew of a goal named `foreman-…` is not a third foreman.
        let crew = row("EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE", name: "foreman-scope round 2",
                       labels: ["crew": "foreman-scope", "goal": "foreman-scope", "round": "2"], cwd: one + "/app")

        let lines = try run(["--scope", one], live: .rows(liveRows + [second, crew]))

        let section = Array(lines[lines.firstIndex(of: "PREDECESSOR")!..<lines.firstIndex(of: "GOALS NOT DONE")!])
        XCTAssertEqual(section[1], "conflict: 3 live foremen share this scope")
        // Newest output first; the pane with no output yet is last.
        XCTAssertEqual(section.filter { $0.contains("  live") }.map { String($0.prefix(8)) },
                       ["DDDDDDDD", "AAAAAAAA", "99999999"])
        XCTAssertFalse(section.contains { $0.contains("EEEEEEEE") })
        assertNothingOfScopeTwo(lines)
    }

    func testAScopeWithNothingSaysSoInEverySection() throws {
        let empty = try directory("work/scope-three")

        let lines = try run(["--scope", empty], live: .rows(liveRows))

        XCTAssertEqual(lines, [
            "scope: \(empty)",
            "daemon: 6 live sessions read from GET /api/sessions",
            "",
            "PREDECESSOR",
            "none: no session labelled crew:foreman in this scope",
            "",
            "GOALS NOT DONE",
            "none: no project root under this scope",
            "",
            "CREW SESSIONS",
            "none: no live session with a goal label in this scope",
            "",
            "WORKTREES",
            "none: no worktree under a project's .claude/worktrees/",
        ])
    }

    // MARK: - JSON

    func testJSONPrintsTheSameReportAsOneObject() throws {
        let lines = try run(["--scope", one, "--json"], live: .rows(liveRows), ownSession: "99999999-9999-4999-8999-999999999999")

        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["scope"] as? String, one)
        XCTAssertEqual((object["daemon"] as? [String: Any])?["answered"] as? Bool, true)
        let predecessor = try XCTUnwrap(object["predecessor"] as? [String: Any])
        XCTAssertEqual(predecessor["id"] as? String, "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        XCTAssertEqual(predecessor["state"] as? String, "live")
        XCTAssertEqual((object["liveForemen"] as? [[String: Any]])?.count, 1)
        let projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.map { $0["id"] as? String }, ["app", "tool"])
        XCTAssertEqual(projects.map { $0["registered"] as? Bool }, [true, false])
        let goals = try XCTUnwrap(projects[0]["goals"] as? [[String: Any]])
        XCTAssertEqual(goals.map { $0["slug"] as? String }, ["ship-it", "parked"])
        XCTAssertEqual(goals[0]["nextAction"] as? String, "Round 3: `the-next-item`. Wait for CI first.")
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.map { $0["id"] as? String }, ["BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"])
        XCTAssertEqual(sessions[0]["labels"] as? [String: String],
                       ["goal": "ship-it", "round": "3", "task": "the-next-item", "pr": "12"])
        let worktrees = try XCTUnwrap(object["worktrees"] as? [[String: Any]])
        XCTAssertEqual(worktrees.map { $0["branch"] as? String }, ["feature/x"])
        assertNothingOfScopeTwo(lines)
    }

    func testAnArchivedPredecessorInJSONCarriesItsNoteAndLastMessage() throws {
        let lines = try run(["--json", "--scope", one])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let predecessor = try XCTUnwrap(object["predecessor"] as? [String: Any])
        XCTAssertEqual(predecessor["id"] as? String, foremanOne)
        XCTAssertEqual(predecessor["state"] as? String, "archived")
        XCTAssertEqual(predecessor["archivedAt"] as? Int, 1_790_306_887_090)
        XCTAssertEqual(predecessor["note"] as? String, "Foreman for scope one. The human wants PR 12 merged first.")
        XCTAssertEqual(predecessor["lastMessage"] as? String, "Round 3 is done.\n\nThe human said: merge PR 12 first.")
        XCTAssertEqual(predecessor["lastMessageTranscript"] as? String, stateDir.path + "/one.jsonl")
        XCTAssertEqual((object["daemon"] as? [String: Any])?["answered"] as? Bool, false)
        XCTAssertEqual((object["liveForemen"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - Rules and usage

    func testWhichLabelsMakeAForeman() {
        XCTAssertTrue(ForemanCommand.isForeman(["crew": "foreman"]))
        XCTAssertTrue(ForemanCommand.isForeman(["crew": "foreman-kitterm"]))
        XCTAssertTrue(ForemanCommand.isForeman(["crew": "foreman", "goal": "dogfood"]))
        XCTAssertFalse(ForemanCommand.isForeman(["crew": "foreman-scope", "goal": "foreman-scope"]))
        XCTAssertFalse(ForemanCommand.isForeman(["crew": "foremanx"]))
        XCTAssertFalse(ForemanCommand.isForeman(["crew": "helper"]))
        XCTAssertFalse(ForemanCommand.isForeman([:]))
    }

    func testADetachedWorktreeHasNoBranch() {
        let listing = """
            worktree /r
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            worktree /r/.claude/worktrees/a
            HEAD 2222222222222222222222222222222222222222
            detached

            worktree /r/.claude/worktrees/b
            HEAD 3333333333333333333333333333333333333333
            branch refs/heads/goal/rounds

            """
        let parsed = ForemanCommand.parseWorktrees(listing)
        XCTAssertEqual(parsed.map(\.path), ["/r", "/r/.claude/worktrees/a", "/r/.claude/worktrees/b"])
        XCTAssertEqual(parsed.map(\.branch), ["main", nil, "goal/rounds"])
    }

    func testUsageErrors() throws {
        XCTAssertThrowsError(try ForemanCommand.run(["status"]) { _ in })
        XCTAssertThrowsError(try run(["--scope"]))
        XCTAssertThrowsError(try run(["extra"]))
        XCTAssertThrowsError(try run(["--scope", stateDir.path + "/no/such/dir"]))
    }
}
