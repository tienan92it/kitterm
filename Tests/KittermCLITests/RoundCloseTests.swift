import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KittermDaemon
import NIOConcurrencyHelpers
import XCTest

@testable import KittermCLI

/// `kitterm round close` — completion conditions 5, 6 and 7 of
/// `docs/goals/round-commands/goal.md`. Each test opens a round with
/// `kitterm round open` on a scratch repository whose `origin` is a bare
/// repository, with real `git`, a fake `gh`, and a scratch daemon in
/// process (`KITTERM_STATE_DIR`, port 0). The transcripts are fixtures
/// written in the scratch folder with neutral data. No test touches the
/// installed daemon, the human's transcripts, or GitHub.
final class RoundCloseTests: XCTestCase {
    private var scratch: URL!
    private var stateDir: URL!
    private var server: DaemonServer!
    private var port = 0
    private var root: String!
    private var remote: String!
    private var worktree: String { ProjectStore.canonicalRoot(root + "/.claude/worktrees/demo") }
    private var folder: String { worktree + "/docs/goals/demo" }

    /// The crew's transcript begins ten minutes before the test; the
    /// foreman's turns sit 20 minutes before, 5 minutes before, and one
    /// hour after, so only the middle one is inside the round.
    private let now = Date()
    private var crewStart: Date { now.addingTimeInterval(-600) }

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: RoundCloseTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-round-close-\(UUID().uuidString)", isDirectory: true)
        stateDir = scratch.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        server = DaemonServer(config: DaemonConfig(port: 0, agentControl: true))
        try server.start()
        port = try XCTUnwrap(server.boundPort)

        remote = scratch.appendingPathComponent("remote.git").path
        let seed = scratch.appendingPathComponent("seed").path
        root = scratch.appendingPathComponent("root").path
        try git(["init", "--quiet", "--bare", "-b", "main", remote], in: scratch.path)
        try git(["init", "--quiet", "-b", "main", seed], in: scratch.path)
        try configure(seed)
        try write("# demo\n", to: seed + "/README.md")
        try writeGoalPackage(in: seed)
        try git(["add", "."], in: seed)
        try git(["commit", "--quiet", "-m", "seed"], in: seed)
        try git(["push", "--quiet", remote, "main"], in: seed)
        try git(["clone", "--quiet", remote, root], in: scratch.path)
        try configure(root)
    }

    override func tearDownWithError() throws {
        try? server?.stop()
        server = nil
        unsetenv("KITTERM_STATE_DIR")
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Condition 5: the record, the archive, the bill, STATE.md

    /// One close archives the round's session, reads its bill, writes
    /// every header field and the six sections with their markers, and
    /// updates `STATE.md`. Both parsers read the record unchanged.
    func testCloseArchivesTheSessionAndWritesEveryFieldOfTheRecord() throws {
        let crew = try openRound(task: "first-item")
        try join(crew, transcript: try crewTranscript("crew", billed: true))
        let foreman = try spawnForeman()
        let base = try git(["rev-parse", "--short=7", "origin/main"], in: worktree)
        let head = try git(["rev-parse", "--short=7", "HEAD"], in: worktree)

        let lines = try close(["--foreman-session", foreman])
        XCTAssertEqual(lines.first, "file     \(folder)/rounds/001.md")
        XCTAssertTrue(lines.contains("markers  7"), "\(lines)")

        // Archived: no live row, an archive with the five labels.
        XCTAssertFalse(try liveRows().contains { $0["id"] as? String == crew })
        XCTAssertTrue(SessionArchive.exists(try XCTUnwrap(UUID(uuidString: crew))))

        let record = try String(contentsOfFile: folder + "/rounds/001.md", encoding: .utf8)
        let header = record.components(separatedBy: "\n## ")[0].components(separatedBy: "\n")
        XCTAssertEqual(header[0], "# Round 001: first-item")
        XCTAssertEqual(header[2], "- Goal: demo")
        let started = RoundRecord.stamp(crewStart)
        XCTAssertTrue(header[3].hasPrefix("- Started: \(started)  Ended: "), header[3])
        let ended = String(header[3].dropFirst("- Started: \(started)  Ended: ".count))
        XCTAssertNotNil(ended.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}[+-]\d{2}:\d{2}$"#, options: .regularExpression), ended)
        XCTAssertEqual(header[4], "- Sessions: \(crew) (claude-fable-5-1)   Archives: \(crew)")
        XCTAssertEqual(header[5], "- Base: \(base)   Result: \(head) on `goal/demo`, PR #7")
        XCTAssertEqual(header[6], "- Cost: $3.00 · 20k in (92% cached) · 1k out · 0h 05m")
        XCTAssertEqual(header[7], try expectedForemanLine())
        XCTAssertEqual(header.count, 9, "\(header)")

        // The six sections, in order, each with its marker.
        let marker = RoundRecord.marker
        XCTAssertTrue(record.hasSuffix("""
        ## Prompt

        \(marker)

        ## Floor

        before: \(marker)
        after: \(marker)

        ## Effects

        \(marker)

        ## Gap

        \(marker)

        ## Decision

        \(marker)

        ## Reflection

        \(marker)

        """), record)

        // STATE.md: the counter, the total, the day, the item under Done.
        let state = try String(contentsOfFile: folder + "/STATE.md", encoding: .utf8)
        XCTAssertTrue(state.contains("\n- Round: 1 of 2 in this budget (first budget)\n"), state)
        XCTAssertTrue(state.contains("\n- Rounds total: 1\n"), state)
        XCTAssertTrue(state.contains("\n- Updated: \(RoundRecord.day(Date()))\n"), state)
        XCTAssertTrue(state.contains("\n- Last floor: green (2026-11-11, round 0)\n"), "Last floor stays the foreman's")
        XCTAssertTrue(state.contains("## Queue\n\n- `second-item` (2).\n\n## Failures"), state)
        XCTAssertTrue(state.contains("## Done\n\n- `first-item`, round 1, `\(head)`, PR #7. See `rounds/001.md`.\n"), state)

        // The two parsers read it with no change to either.
        let summary = KnowledgeSummary.parse(state: state, goal: nil, roundNames: ["001.md"], latestRound: nil)
        XCTAssertEqual(summary.tasks?.first { $0.slug == "first-item" }?.state, .done)
        let parsed = KnowledgeSummary.roundRecord(number: 1, text: record)
        XCTAssertEqual(parsed.pr, 7)
        XCTAssertEqual(parsed.started, RoundRecord.day(crewStart))
        XCTAssertEqual(parsed.task, "first-item")
        XCTAssertEqual(parsed.costUSD, 3.0)
        let ledger = GoalLedger.parse(record, number: 1)
        XCTAssertEqual(ledger.slug, "first-item")
        XCTAssertEqual(ledger.sessions, [UUID(uuidString: crew)!])
        XCTAssertEqual(ledger.archives, [UUID(uuidString: crew)!])
        XCTAssertEqual(ledger.base, base)
        XCTAssertEqual(ledger.result, head)
        XCTAssertEqual(ledger.pr, 7)
        XCTAssertEqual(ledger.costLines.count, 1)
    }

    /// A bill that lands after the archive is read on a later retry, inside
    /// `--bill-timeout`.
    func testABillThatLandsLateIsReadOnARetry() throws {
        let crew = try openRound(task: "first-item")
        let transcript = try crewTranscript("crew", billed: false)
        try join(crew, transcript: transcript)
        let bill = Self.billLine
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            guard let handle = FileHandle(forWritingAtPath: transcript) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(bill.utf8))
            try? handle.close()
        }
        _ = try close(["--bill-timeout", "20"])
        let record = try String(contentsOfFile: folder + "/rounds/001.md", encoding: .utf8)
        XCTAssertTrue(record.contains("\n- Cost: $3.00 · 20k in (92% cached) · 1k out · 0h 05m\n"), record)
    }

    /// No bill within `--bill-timeout`: the line says why, and the run
    /// still writes the record. No foreman session: its line says so.
    func testNoBillWithinTheTimeoutWritesNoneRecorded() throws {
        let crew = try openRound(task: "first-item")
        try join(crew, transcript: try crewTranscript("crew", billed: false))
        let started = Date()
        _ = try close(["--bill-timeout", "0"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        let record = try String(contentsOfFile: folder + "/rounds/001.md", encoding: .utf8)
        XCTAssertTrue(record.contains("\n- Cost: none recorded (noCostStateLine)\n"), record)
        XCTAssertEqual(KnowledgeSummary.costLines(record), [])
    }

    /// A second close finds the round's session among the archives, keeps
    /// the record the foreman edited, and leaves `STATE.md` as it is.
    func testASecondCloseReusesTheRecordAndTheArchivedSessions() throws {
        let crew = try openRound(task: "first-item")
        try join(crew, transcript: try crewTranscript("crew", billed: true))
        _ = try close([])
        let path = folder + "/rounds/001.md"
        let edited = try String(contentsOfFile: path, encoding: .utf8)
            .replacingOccurrences(of: "## Gap\n\n\(RoundRecord.marker)", with: "## Gap\n\nclass: none")
        try write(edited, to: path)
        let state = try String(contentsOfFile: folder + "/STATE.md", encoding: .utf8)

        let lines = try close([])
        XCTAssertTrue(lines.contains("sessions \(crew)"), "\(lines)")
        XCTAssertTrue(lines.contains("markers  6"), "\(lines)")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), edited)
        XCTAssertEqual(try String(contentsOfFile: folder + "/STATE.md", encoding: .utf8), state)
    }

    /// A close with no session of the goal fails at its step and changes
    /// nothing.
    func testACloseWithNoSessionFailsAndChangesNothing() throws {
        _ = try openRound(task: "first-item")
        let rows = try liveRows()
        for row in rows { try endSession(try XCTUnwrap(row["id"] as? String)) }
        let state = try String(contentsOfFile: folder + "/STATE.md", encoding: .utf8)
        XCTAssertThrowsError(try close([])) { error in
            XCTAssertEqual((error as? RoundCommand.StepFailure)?.step, "sessions")
            XCTAssertTrue(error.localizedDescription.hasPrefix("round close: sessions failed"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOfFile: folder + "/STATE.md", encoding: .utf8), state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/rounds/001.md"))
    }

    // MARK: - Condition 6: --commit

    /// `--commit` refuses while a marker remains; once the foreman replaced
    /// them it makes one commit of the goal folder and pushes it. The next
    /// round's Base is this round's Result.
    func testCommitRefusesWhileAMarkerRemainsThenCommitsAndPushesTheGoalFolder() throws {
        let crew = try openRound(task: "first-item")
        try join(crew, transcript: try crewTranscript("crew", billed: true))
        let before = try git(["rev-parse", "HEAD"], in: worktree)
        XCTAssertThrowsError(try close(["--commit"])) { error in
            XCTAssertEqual((error as? RoundCommand.StepFailure)?.step, "commit")
            XCTAssertTrue(error.localizedDescription.contains("7 line(s)"), error.localizedDescription)
        }
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: worktree), before)

        let path = folder + "/rounds/001.md"
        let filled = try String(contentsOfFile: path, encoding: .utf8)
            .replacingOccurrences(of: RoundRecord.marker, with: "written by the foreman")
        try write(filled, to: path)
        let lines = try close(["--commit"])
        let head = try git(["rev-parse", "HEAD"], in: worktree)
        XCTAssertTrue(lines.contains("commit   \(head)"), "\(lines)")
        XCTAssertEqual(try git(["rev-list", "--count", "\(before)..HEAD"], in: worktree), "1")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/goal/demo"], in: remote), head)
        XCTAssertEqual(
            try git(["diff", "--name-only", before, head], in: worktree).split(separator: "\n"),
            ["docs/goals/demo/STATE.md", "docs/goals/demo/rounds/001.md"]
        )
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], in: worktree), "demo: round 1 record")

        // A second `--commit` has nothing to commit and pushes nothing new.
        _ = try close(["--commit"])
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: worktree), head)

        // Round 2: the Base is round 1's Result.
        let result = try XCTUnwrap(GoalLedger.parse(filled, number: 1).result)
        let second = try openRound(task: "second-item")
        try join(second, transcript: try crewTranscript("second", billed: true))
        _ = try close([])
        let record = try String(contentsOfFile: folder + "/rounds/002.md", encoding: .utf8)
        XCTAssertTrue(record.contains("\n- Base: \(result)   Result: "), record)
        let state = try String(contentsOfFile: folder + "/STATE.md", encoding: .utf8)
        XCTAssertTrue(state.contains("## Queue\n\nNone.\n\n## Failures"), state)
        XCTAssertTrue(state.contains("\n- Round: 2 of 2 in this budget (first budget)\n"), state)
    }

    /// `--commit` reads `gh pr checks <N>` for the `pr:` label and refuses
    /// a failed, a pending or an empty answer, naming each check that is
    /// not green; `--no-checks` commits with no read
    /// (`one-rule-one-place` round 3).
    func testCommitRefusesUntilThePullRequestChecksAreGreen() throws {
        let crew = try openRound(task: "first-item")
        try join(crew, transcript: try crewTranscript("crew", billed: true))
        _ = try close([])
        let path = folder + "/rounds/001.md"
        try write(
            try String(contentsOfFile: path, encoding: .utf8)
                .replacingOccurrences(of: RoundRecord.marker, with: "written by the foreman"),
            to: path
        )
        let before = try git(["rev-parse", "HEAD"], in: worktree)

        sharedGH.answerChecks(
            status: 8,
            output: #"[{"bucket":"pass","name":"lint"},{"bucket":"fail","name":"test"},{"bucket":"pending","name":"linux-build"}]"#
        )
        XCTAssertThrowsError(try close(["--commit"])) { error in
            XCTAssertEqual((error as? RoundCommand.StepFailure)?.step, "checks")
            XCTAssertTrue(error.localizedDescription.contains(
                "PR #7 is not green on its head: test fail, linux-build pending; wait for green, "
                    + "or pass --no-checks for a repository with no CI"
            ), error.localizedDescription)
        }
        XCTAssertEqual(sharedGH.checkCalls.last, ["pr", "checks", "7", "--json", "name,bucket"])

        sharedGH.answerChecks(status: 1, error: "no checks reported on the 'goal/demo' branch\n")
        XCTAssertThrowsError(try close(["--commit"])) { error in
            XCTAssertTrue(error.localizedDescription.contains(
                "gh pr checks 7 reports no checks; pass --no-checks for a repository with no CI"
            ), error.localizedDescription)
        }
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: worktree), before)

        let calls = sharedGH.checkCalls.count
        let lines = try close(["--commit", "--no-checks"])
        XCTAssertEqual(sharedGH.checkCalls.count, calls, "--no-checks reads no checks")
        let head = try git(["rev-parse", "HEAD"], in: worktree)
        XCTAssertNotEqual(head, before)
        XCTAssertTrue(lines.contains("commit   \(head)"), "\(lines)")
    }

    /// `--decision failed` files the item under `## Failures`; a later
    /// `--commit` run with no `--decision` keeps it there instead of
    /// moving it to `## Done`, and a later `--decision done` refuses
    /// (`one-rule-one-place` round 1, "Gap").
    func testAFailedRoundStaysUnderFailuresOnALaterCommitRun() throws {
        let crew = try openRound(task: "first-item")
        try join(crew, transcript: try crewTranscript("crew", billed: true))
        let head = try git(["rev-parse", "--short=7", "HEAD"], in: worktree)
        let lines = try close(["--decision", "failed"])
        XCTAssertTrue(lines.contains("decision failed"), "\(lines)")
        let failedLine = "- `first-item`, round 1, `\(head)`, PR #7. See `rounds/001.md`."
        var state = try String(contentsOfFile: folder + "/STATE.md", encoding: .utf8)
        XCTAssertTrue(state.contains("## Failures\n\n\(failedLine)\n\n## Proposals"), state)
        XCTAssertTrue(state.contains("## Done\n\nNone.\n"), state)
        XCTAssertTrue(state.contains("\n- Round: 1 of 2 in this budget (first budget)\n"), "a failed round spends the budget")

        let path = folder + "/rounds/001.md"
        try write(
            try String(contentsOfFile: path, encoding: .utf8)
                .replacingOccurrences(of: RoundRecord.marker, with: "written by the foreman"),
            to: path
        )
        XCTAssertThrowsError(try close(["--decision", "done"])) { error in
            XCTAssertEqual((error as? RoundCommand.StepFailure)?.step, "state")
            XCTAssertTrue(error.localizedDescription.contains(
                "the first run filed `first-item` under ## Failures; pass --decision failed, or edit STATE.md by hand"
            ), error.localizedDescription)
        }
        let committed = try close(["--commit"])
        XCTAssertTrue(committed.contains("decision failed"), "\(committed)")
        state = try String(contentsOfFile: folder + "/STATE.md", encoding: .utf8)
        XCTAssertTrue(state.contains("## Failures\n\n\(failedLine)\n\n## Proposals"), state)
        XCTAssertTrue(state.contains("## Done\n\nNone.\n"), state)
        let summary = KnowledgeSummary.parse(state: state, goal: nil, roundNames: ["001.md"], latestRound: nil)
        XCTAssertEqual(summary.tasks?.first { $0.slug == "first-item" }?.state, .failed)
    }

    /// A failed or a `propose` round commits its record on a red check:
    /// the check is the reason the round failed, so `--commit` names it in
    /// one stderr line and goes on (`one-rule-one-place` round 3,
    /// correction 1). A `done` round still refuses.
    func testAFailedOrProposeRoundCommitsOnARedCheckAndNamesIt() throws {
        let red = #"[{"bucket":"fail","name":"test"}]"#
        for (task, decision) in [("first-item", "failed"), ("second-item", "propose")] {
            let crew = try openRound(task: task)
            try join(crew, transcript: try crewTranscript(task, billed: true))
            _ = try close(["--decision", decision])
            let round = task == "first-item" ? "001" : "002"
            let path = folder + "/rounds/\(round).md"
            try write(
                try String(contentsOfFile: path, encoding: .utf8)
                    .replacingOccurrences(of: RoundRecord.marker, with: "written by the foreman"),
                to: path
            )
            sharedGH.answerChecks(status: 1, output: red)
            let before = try git(["rev-parse", "HEAD"], in: worktree)
            var progress: [String] = []
            let lines = try close(["--commit"], progress: { progress.append($0) })
            let head = try git(["rev-parse", "HEAD"], in: worktree)
            XCTAssertNotEqual(head, before, decision)
            XCTAssertTrue(lines.contains("commit   \(head)"), "\(lines)")
            XCTAssertEqual(progress.filter { $0.contains("not green") }, [
                "round close: PR #7 is not green on its head: test fail; the round is \(decision), so its record commits",
            ])
        }
    }

    /// `propose` leaves the item under `## Queue` and counts the round; a
    /// later run keeps it there, and a later `failed` refuses.
    func testCloseStateFilesAProposeRoundUnderQueueAndKeepsIt() throws {
        let state = Self.unitState
        let once = try RoundRecord.closeState(state, task: "a", round: 5, sha: "1b1b1b1", pr: 9, day: "2026-11-02", decision: .propose)
        XCTAssertTrue(once.contains("\n- Rounds total: 5\n"), once)
        XCTAssertTrue(once.contains("## Queue\n\n- `a` (1), round 5, PR #9.\n  A continuation line.\n- `b` (2).\n"), once)
        XCTAssertEqual(RoundRecord.filed(once, task: "a", round: 5), .propose)
        XCTAssertEqual(try RoundRecord.closeState(once, task: "a", round: 5, sha: "1b1b1b1", pr: 9, day: "2026-11-02"), once)
        XCTAssertThrowsError(
            try RoundRecord.closeState(once, task: "a", round: 5, sha: "1b1b1b1", pr: 9, day: "2026-11-02", decision: .failed)
        ) { error in
            XCTAssertEqual(
                (error as? RoundRecord.StateError)?.reason,
                "the first run filed `a` under ## Queue; pass --decision propose, or edit STATE.md by hand"
            )
        }
    }

    /// `failed` moves the item to `## Failures`, after a line already there.
    func testCloseStateFilesAFailedRoundUnderFailures() throws {
        let once = try RoundRecord.closeState(
            Self.unitState, task: "a", round: 5, sha: "1b1b1b1", pr: 9, day: "2026-11-02", decision: .failed
        )
        XCTAssertTrue(once.contains(
            "## Failures\n\n- attempt killed: 2026-10-30, the host slept\n- `a`, round 5, `1b1b1b1`, PR #9. See `rounds/005.md`.\n"
        ), once)
        XCTAssertTrue(once.contains("## Queue\n\n- `b` (2).\n\n## Failures"), once)
        XCTAssertEqual(RoundRecord.filed(once, task: "a", round: 5), .failed)
        XCTAssertEqual(try RoundRecord.closeState(once, task: "a", round: 5, sha: "1b1b1b1", pr: 9, day: "2026-11-02"), once)
    }

    func testDecisionAndNoChecksAreParsed() throws {
        let options = try RoundCommand.CloseOptions.parse(["r", "demo", "--commit", "--no-checks", "--decision", "propose"])
        XCTAssertEqual(options.decision, .propose)
        XCTAssertTrue(options.noChecks)
        XCTAssertNil(try RoundCommand.CloseOptions.parse(["r", "demo"]).decision)
        for args in [["r", "demo", "--decision", "maybe"], ["r", "demo", "--chore", "--decision", "done"], ["r", "demo", "--no-checks"]] {
            XCTAssertThrowsError(try RoundCommand.CloseOptions.parse(args), "\(args)")
        }
    }

    private static let unitState = """
    # STATE: x

    - Status: active
    - Round: 1 of 3 in this budget (second budget)
    - Rounds total: 4
    - Last floor: green (2026-11-01, round 4)
    - Updated: 2026-11-01

    ## Queue

    - `a` (1), round 5, PR #9.
      A continuation line.
    - `b` (2).

    ## Failures

    - attempt killed: 2026-10-30, the host slept

    ## Done

    - `z`, round 4, `0a0a0a0`, PR #9. See `rounds/004.md`.

    ## Next action

    Round 5.
    """

    // MARK: - Condition 7: the foreman line

    /// The window counts the foreman's turns between Started and Ended, its
    /// subagents' too, and a `cost-state` line inside it closes nothing.
    func testTheForemanLineCountsOnlyTheTurnsInsideTheRound() throws {
        let path = try foremanTranscript()
        let outcome = TranscriptEstimateCache.estimate(
            forTranscriptAt: path,
            from: Int64(crewStart.timeIntervalSince1970 * 1000), to: Int64(now.timeIntervalSince1970 * 1000)
        )
        guard case .estimate(let estimate) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(estimate.turns, 2, "the turn inside and its subagent's")
        XCTAssertEqual(estimate.inTokens, 101_000 + 1_000)
        XCTAssertEqual(estimate.outTokens, 2_000 + 500)
        XCTAssertEqual(RoundRecord.foremanLine(outcome), try expectedForemanLine())

        XCTAssertEqual(
            RoundCommand.foremanLine(session: nil, rows: [], from: crewStart, to: now),
            "- Foreman: none recorded (no foreman session)"
        )
        XCTAssertEqual(
            RoundCommand.foremanLine(session: UUID().uuidString, rows: [], from: crewStart, to: now),
            "- Foreman: none recorded (no transcript)"
        )
        let outside = TranscriptEstimateCache.estimate(forTranscriptAt: path, from: 0, to: 1)
        XCTAssertEqual(RoundRecord.foremanLine(outside), "- Foreman: none recorded (noTurns)")

        // A model with no rate keeps its tokens and names itself, so the
        // dollars are not read as whole.
        let unknown = scratch.appendingPathComponent("transcripts/unknown.jsonl").path
        try write(
            turn("req_u1", at: now.addingTimeInterval(-60), input: 1_000, output: 1_000, cacheRead: 0)
                .replacingOccurrences(of: "claude-fable-5-1", with: "claude-neutral-9"),
            to: unknown
        )
        let unpriced = TranscriptEstimateCache.estimate(
            forTranscriptAt: unknown,
            from: Int64(crewStart.timeIntervalSince1970 * 1000), to: Int64(now.timeIntervalSince1970 * 1000)
        )
        XCTAssertEqual(
            RoundRecord.foremanLine(unpriced),
            "- Foreman: ~$0.00 · 1k in (0% cached) · 1k out · unpriced claude-neutral-9"
        )
    }

    /// `KnowledgeSummary.costLine` and `GoalLedger` do not count the line.
    func testTheCostParsersDoNotCountTheForemanLine() {
        let record = """
        # Round 001: first-item

        - Goal: demo
        - Started: 2026-11-11T14:04+07:00  Ended: 2026-11-11T14:21+07:00
        - Sessions: 11111111-1111-4111-8111-111111111111 (claude-fable-5-1)   Archives: 11111111-1111-4111-8111-111111111111
        - Base: 1a2b3c4   Result: 5d6e7f8 on `goal/demo`, PR #7
        - Cost: $3.00 · 20k in (92% cached) · 1k out · 0h 05m
        - Foreman: ~$9.99 · 900k in (99% cached) · 9k out

        ## Prompt

        """
        XCTAssertNil(KnowledgeSummary.costLine("- Foreman: ~$9.99 · 900k in (99% cached) · 9k out"))
        XCTAssertEqual(KnowledgeSummary.costLines(record).map(\.costUSD), [3.0])
        XCTAssertEqual(KnowledgeSummary.roundRecord(number: 1, text: record).costUSD, 3.0)
        let ledger = GoalLedger.parse(record, number: 1)
        XCTAssertEqual(ledger.costLines.count, 1)
        XCTAssertEqual(ledger.costLines.first??.costUSD, 3.0)
    }

    // MARK: - STATE.md, a chore, the session name

    /// The counter grows by the rounds the total has not counted, once.
    func testCloseStateCountsTheRoundOnce() throws {
        let state = """
        # STATE: x

        - Status: active
        - Round: 1 of 3 in this budget (second budget)
        - Rounds total: 4
        - Last floor: green (2026-11-01, round 4)
        - Updated: 2026-11-01

        ## Queue

        - `a` (1), round 5, PR #9.
          A continuation line.
        - `b` (2).

        ## Done

        - `z`, round 4, `0a0a0a0`, PR #9. See `rounds/004.md`.

        ## Next action

        Round 5.
        """
        let once = try RoundRecord.closeState(state, task: "a", round: 5, sha: "1b1b1b1", pr: 9, day: "2026-11-02")
        XCTAssertTrue(once.contains("\n- Round: 2 of 3 in this budget (second budget)\n"), once)
        XCTAssertTrue(once.contains("\n- Rounds total: 5\n"), once)
        XCTAssertTrue(once.contains("\n- Updated: 2026-11-02\n"), once)
        XCTAssertTrue(once.contains("## Queue\n\n- `b` (2).\n\n## Done"), once)
        XCTAssertTrue(once.contains(
            "- `z`, round 4, `0a0a0a0`, PR #9. See `rounds/004.md`.\n- `a`, round 5, `1b1b1b1`, PR #9. See `rounds/005.md`.\n"
        ), once)
        XCTAssertEqual(try RoundRecord.closeState(once, task: "a", round: 5, sha: "1b1b1b1", pr: 9, day: "2026-11-02"), once)
        XCTAssertThrowsError(try RoundRecord.closeState(state, task: "q", round: 5, sha: "1", pr: 9, day: "2026-11-02"))
    }

    /// `--chore` writes the one chore file with its cost, and no record.
    func testAChoreWritesTheOneChoreFile() throws {
        let gh = FakeGH()
        var lines: [String] = []
        try RoundCommand.run(
            ["open", root, "demo", "--chore", "--port", String(port), "--json"], runner: runner(gh),
            out: { lines.append($0) }, progress: { _ in }
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let crew = try XCTUnwrap(object["session"] as? String)
        try join(crew, transcript: try crewTranscript("chore", billed: true))

        let closed = try close(["--chore"])
        let day = RoundRecord.day(Date())
        let file = worktree + "/docs/goals/chores/\(day)-demo.md"
        XCTAssertEqual(closed.first, "file     \(file)")
        XCTAssertEqual(
            try String(contentsOfFile: file, encoding: .utf8),
            "- \(day) · \(RoundRecord.marker) (claude-fable-5-1) · PR #7 · Cost: $3.00 · 20k in (92% cached) · 1k out · 0h 05m\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/rounds/001.md"))
    }

    /// `round open` names the crew session `<slug> round <R>`, as the
    /// foreman skill does.
    func testOpenNamesTheSessionSlugRoundR() throws {
        let crew = try openRound(task: "first-item")
        XCTAssertEqual(try liveRows().first { $0["id"] as? String == crew }?["name"] as? String, "demo round 1")
    }

    // MARK: - Fixtures

    /// A bill of $3.00: in 6 + 1500 + 18,000 = 19,506 (20k, 92% cached),
    /// out 600 (1k), 300,000 ms (5 minutes).
    private static let billLine = #"{"type":"cost-state","sessionId":"c","totalCostUSD":3.0,"totalAPIDuration":60000,"totalAPIDurationWithoutRetries":60000,"totalToolDuration":100,"totalLinesAdded":0,"totalLinesRemoved":0,"totalDuration":300000,"startTime":0,"modelUsage":{"claude-fable-5-1":{"inputTokens":6,"outputTokens":600,"thinkingTokens":0,"cacheReadInputTokens":18000,"cacheCreationInputTokens":1500,"webSearchRequests":0,"costUSD":3.0}},"hasUnknownModelCost":false}"#
        + "\n"

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func turn(_ request: String, at date: Date, input: Int, output: Int, cacheRead: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(iso(date))","requestId":"\#(request)","message":{"model":"claude-fable-5-1","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":0}}}"#
            + "\n"
    }

    /// A crew transcript that begins at `crewStart`, with or without its bill.
    private func crewTranscript(_ name: String, billed: Bool) throws -> String {
        let path = scratch.appendingPathComponent("transcripts/\(name).jsonl").path
        var text = #"{"type":"user","timestamp":"\#(iso(crewStart))","message":{"role":"user","content":"start"}}"# + "\n"
        text += turn("req_\(name)", at: crewStart.addingTimeInterval(30), input: 6, output: 600, cacheRead: 18_000)
        if billed { text += Self.billLine }
        try write(text, to: path)
        return path
    }

    /// The foreman's transcript: one turn before the round, a bill, one
    /// turn inside, one after; and a subagent turn inside.
    private func foremanTranscript() throws -> String {
        let path = scratch.appendingPathComponent("transcripts/foreman.jsonl").path
        var text = turn("req_f0", at: now.addingTimeInterval(-1200), input: 50_000, output: 50_000, cacheRead: 0)
        text += Self.billLine
        text += turn("req_f1", at: now.addingTimeInterval(-300), input: 1_000, output: 2_000, cacheRead: 100_000)
        text += turn("req_f2", at: now.addingTimeInterval(3600), input: 70_000, output: 70_000, cacheRead: 0)
        try write(text, to: path)
        let subagent = scratch.appendingPathComponent("transcripts/foreman/subagents/agent-1.jsonl").path
        try write(turn("req_s1", at: now.addingTimeInterval(-200), input: 1_000, output: 500, cacheRead: 0), to: subagent)
        return path
    }

    /// The window's two turns priced by `ModelPricing`: in 102k, 98%
    /// cached, out 2.5k (3k).
    private func expectedForemanLine() throws -> String {
        let rates = try XCTUnwrap(ModelPricing.rates(for: "claude-fable-5-1"))
        let dollars = rates.cost(input: 2_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 100_000, output: 2_500)
        return String(format: "- Foreman: ~$%.2f · 102k in (98%% cached) · 3k out", dollars)
    }

    // MARK: - Helpers

    private final class FakeGH: @unchecked Sendable {
        private let lock = NIOLock()
        private var open: [Int] = []
        private var checks = PullRequestStatus.RunResult(status: 0, output: Data("[{\"bucket\":\"pass\",\"name\":\"test\"}]\n".utf8))
        private(set) var checkCalls: [[String]] = []

        /// What the next `gh pr checks` answers; green by default.
        func answerChecks(status: Int32, output: String = "", error: String = "") {
            lock.withLock { checks = PullRequestStatus.RunResult(status: status, output: Data(output.utf8), error: error) }
        }

        func run(_ args: [String]) -> PullRequestStatus.RunResult {
            lock.withLock {
                if args.starts(with: ["pr", "checks"]) {
                    checkCalls.append(args)
                    return checks
                }
                if args.starts(with: ["pr", "list"]) {
                    let rows = open.map { "{\"number\":\($0)}" }.joined(separator: ",")
                    return PullRequestStatus.RunResult(status: 0, output: Data("[\(rows)]\n".utf8))
                }
                if args.starts(with: ["pr", "create"]) {
                    open.append(7)
                    return PullRequestStatus.RunResult(status: 0, output: Data("https://github.com/owner/demo/pull/7\n".utf8))
                }
                return PullRequestStatus.RunResult(status: 1, error: "fake gh: \(args) is not a call round close makes")
            }
        }
    }

    private var sharedGH = FakeGH()

    private func runner(_ gh: FakeGH) -> RoundCommand.Runner {
        { tool, args, directory in tool == "gh" ? gh.run(args) : RoundCommand.defaultRunner(tool, args, directory) }
    }

    /// `round open` for `task`; the crew session's id.
    private func openRound(task: String) throws -> String {
        var lines: [String] = []
        try RoundCommand.run(
            ["open", root, "demo", "--task", task, "--port", String(port), "--json"], runner: runner(sharedGH),
            out: { lines.append($0) }, progress: { _ in }
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        return try XCTUnwrap(object["session"] as? String)
    }

    private func close(_ flags: [String], progress: (String) -> Void = { _ in }) throws -> [String] {
        var lines: [String] = []
        try RoundCommand.run(
            ["close", root, "demo", "--port", String(port), "--bill-timeout", "10"] + flags, runner: runner(sharedGH),
            out: { lines.append($0) }, progress: progress
        )
        return lines
    }

    /// A foreman pane with a transcript join, for `--foreman-session`.
    private func spawnForeman() throws -> String {
        let call = MCPTools.Call(method: "POST", path: "/api/sessions", jsonBody: [
            "name": "foreman", "cwd": scratch.path, "labels": ["crew": "foreman"],
        ])
        guard case .success(_, _, let data) = MCPHTTPClient(port: port).send(call, timeout: 10),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { throw XCTSkip("the scratch daemon spawned no foreman pane") }
        try join(id, transcript: try foremanTranscript())
        return id
    }

    /// A `Notification` hook, the shape Claude Code sends, naming a transcript.
    private func join(_ session: String, transcript: String) throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification", "session_id": UUID().uuidString,
            "transcript_path": transcript, "message": "waiting",
        ])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/hooks")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(session, forHTTPHeaderField: "X-Kitterm-Session")
        let done = DispatchSemaphore(value: 0)
        let status = NIOLockedValueBox(0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status.withLockedValue { $0 = (response as? HTTPURLResponse)?.statusCode ?? 0 }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        XCTAssertEqual(status.withLockedValue { $0 }, 200, "POST /api/hooks for \(session)")
    }

    private func liveRows() throws -> [[String: Any]] {
        try RoundCommand.sessions(MCPHTTPClient(port: port)).get().filter(RoundCommand.isLive)
    }

    private func endSession(_ id: String) throws {
        let call = MCPTools.Call(method: "DELETE", path: "/api/sessions/\(id)")
        _ = MCPHTTPClient(port: port).send(call, timeout: 10)
        let deadline = Date().addingTimeInterval(10)
        while try liveRows().contains(where: { $0["id"] as? String == id }), Date() < deadline { usleep(50_000) }
    }

    private func writeGoalPackage(in checkout: String) throws {
        let folder = checkout + "/docs/goals/demo"
        try write("# Goal: a demo goal\n", to: folder + "/goal.md")
        try write("""
        # STATE: demo

        - Status: active
        - Round: 0 of 2 in this budget (first budget)
        - Rounds total: 0
        - Last floor: green (2026-11-11, round 0)
        - Updated: 2026-11-11

        ## Queue

        - `first-item` (1).
        - `second-item` (2).

        ## Failures

        None.

        ## Proposals waiting on the human

        None.

        ## Done

        None.

        ## Next action

        Round 1.

        """, to: folder + "/STATE.md")
    }

    private func configure(_ checkout: String) throws {
        let hooks = scratch.appendingPathComponent("no-hooks").path
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        for (key, value) in [
            ("user.name", "Round Test"), ("user.email", "round@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", hooks),
        ] {
            try git(["config", key, value], in: checkout)
        }
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String], in directory: String) throws -> String {
        let result = try XCTUnwrap(RoundCommand.defaultRunner("git", ["-C", directory] + args, directory))
        guard result.status == 0 else {
            throw NSError(domain: "git", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) exited \(result.status): \(result.error)",
            ])
        }
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
