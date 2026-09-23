import Foundation
import XCTest

@testable import KittermCLI

/// `kitterm goal cost` over a fixture `docs/goals/` tree, the one
/// `docs/goals/cost-per-round/corpus/01-what-did-that-goal-cost.md`
/// describes: one goal, `example`, three rounds, the third predating the
/// bill. The archives live in a scratch `KITTERM_STATE_DIR`; the checkout is
/// a scratch git repository so the files column has commits to diff.
final class GoalCostTests: XCTestCase {
    private var work: URL!
    private var project: String!
    private var stateDir: URL!

    /// The bill fixture from capability 2: $2.6361237500000003, two models.
    private static let billTranscript = CLIFixture.repositoryRoot
        .appendingPathComponent("Tests/Fixtures/transcripts/bill.jsonl").path

    private static let sessions = (
        one: "A1A1A1A1-0000-4000-8000-000000000001",
        two: "A2A2A2A2-0000-4000-8000-000000000002",
        three: "A3A3A3A3-0000-4000-8000-000000000003"
    )

    override func setUpWithError() throws {
        work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-goal-cost-\(UUID().uuidString)")
        stateDir = work.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        project = work.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Fixture

    @discardableResult
    private func git(_ arguments: String..., environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", project] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.test",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.test",
        ]) { $1 }.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        waitForExit(of: process, output: String(decoding: data, as: UTF8.self))
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One commit adding `count` files; returns its short sha. `date` pins
    /// the author and committer date (`@<epoch> +0000`), and with it the sha.
    private func commit(_ name: String, files count: Int, at date: String? = nil) throws -> String {
        for index in 0..<count {
            try Data("\(name) \(index)\n".utf8).write(to: URL(fileURLWithPath: "\(project!)/\(name)-\(index).txt"))
        }
        try git("add", ".")
        let dates = date.map { ["GIT_AUTHOR_DATE": $0, "GIT_COMMITTER_DATE": $0] } ?? [:]
        try git("commit", "-q", "-m", name, environment: dates)
        return try git("rev-parse", "--short", "HEAD")
    }

    private func writeArchive(_ id: String, run: String, transcript: String) throws {
        let dir = stateDir.appendingPathComponent("archive/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "version": 1, "id": id, "cwd": project!, "shell": "/bin/sh", "archivedAt": 1789468723037,
            "commands": [], "marks": [], "output": ["base": 0, "pruned": false, "bytes": 0],
            "agentSessionId": run, "agentTranscript": transcript,
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("archive.json"))
    }

    private func writeRecord(_ goal: String, _ number: Int, _ text: String) throws {
        let folder = "\(project!)/docs/goals/\(goal)/rounds"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: folder + "/" + String(format: "%03d.md", number)))
    }

    private func writeState(_ goal: String) throws {
        let folder = "\(project!)/docs/goals/\(goal)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("# STATE: \(goal)\n\n- Status: active\n".utf8).write(to: URL(fileURLWithPath: folder + "/STATE.md"))
    }

    /// The corpus fixture. Rounds 1 and 2 carry a `Cost:` line and an archive
    /// that names a transcript; round 3 has neither.
    private func writeCorpusFixture() throws -> (shas: [String], zeroed: String) {
        try git("init", "-q")
        let c0 = try commit("init", files: 1)
        let c1 = try commit("send-on-transition", files: 12)
        let c2 = try commit("the-toggle", files: 3)
        let c3 = try commit("subscriptions", files: 7)

        // Round 2's transcript: $0.41 and a zeroed `modelUsage`, 412 ms.
        let zeroed = stateDir.appendingPathComponent("zeroed-billed.jsonl").path
        try Data("""
        {"type":"user","message":{"role":"user","content":"hi"},"sessionId":"dc95adb5-e73f-4760-b2e8-252cbc18563b"}
        {"type":"cost-state","sessionId":"dc95adb5-e73f-4760-b2e8-252cbc18563b","totalCostUSD":0.41,"totalAPIDuration":0,"totalAPIDurationWithoutRetries":0,"totalToolDuration":0,"totalLinesAdded":0,"totalLinesRemoved":0,"totalDuration":412,"startTime":1788758287970,"modelUsage":{},"hasUnknownModelCost":false}

        """.utf8).write(to: URL(fileURLWithPath: zeroed))

        try writeArchive(Self.sessions.one, run: "e89e7ec8-9e61-4900-800f-aa72ed555d63", transcript: Self.billTranscript)
        try writeArchive(Self.sessions.two, run: "dc95adb5-e73f-4760-b2e8-252cbc18563b", transcript: zeroed)

        try writeState("example")
        try writeRecord("example", 1, """
        # Round 001: send-on-transition

        - Goal: example
        - Started: 2026-09-12T10:00+07:00  Ended: 2026-09-12T10:06+07:00
        - Sessions: \(Self.sessions.one)   Archives: the same
        - Base: \(c0) (main)   Result: \(c1) on goals/send-on-transition, merged as PR #12
        - Cost: $2.64 · 1101k in (93% cached) · 18k out · 0h 6m

        ## Prompt

        Capability 3 from `plan.md`.

        ## Floor

        before: green (`swift test` 600)

        after: green. **628 tests, 0 failures**, 28 new. Bench p95 2.5 ms.

        ## Effects

        - visible: a test.

        ## Gap

        class: none

        ## Decision

        done. Capability 3 is complete on `goals/send-on-transition` at `\(c1)`.

        ## Reflection

        Nothing.

        """)
        try writeRecord("example", 2, """
        # Round 002: the-toggle

        - Goal: example
        - Started: 2026-09-12T11:00+07:00  Ended: 2026-09-12T11:00+07:00
        - Sessions: \(Self.sessions.two)   Archives: the same
        - Base: \(c1) (goals/send-on-transition)   Result: \(c2)
        - Cost: $0.41 · 0k in (0% cached) · 0k out · 0h 0m

        ## Floor

        before: green

        after: red (`swift test`). 628 tests, 2 failures, 0 new.

        ## Gap

        class: domain

        ## Decision

        failed. The toggle does not hold across a reload.

        """)
        try writeRecord("example", 3, """
        # Round 003: subscriptions

        - Goal: example
        - Started: 2026-09-11T09:00+07:00  Ended: 2026-09-11T09:30+07:00
        - Sessions: \(Self.sessions.three)   Archives: the same
        - Base: \(c2) (main)   Result: \(c3) on goals/subscriptions (#9)

        ## Floor

        before: green

        after: green. **620 tests, 0 failures**, 20 new.

        ## Decision

        done. Capability 2 is complete at `\(c3)`.

        """)
        return ([c0, c1, c2, c3], zeroed)
    }

    @discardableResult
    private func run(_ args: [String]) throws -> [String] {
        var lines: [String] = []
        try GoalCommand.run(args) { lines.append($0) }
        return lines
    }

    private func json(_ lines: [String]) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines.joined(separator: "\n").utf8)) as? [String: Any])
    }

    // MARK: - The proof from plan.md row 4

    /// The table of the corpus request: its values, its order, its footer,
    /// and the widths of its `001` and `total` rows byte for byte. The
    /// corpus's other rows and its header are aligned by hand and disagree
    /// with each other by one column (`+28` ends one column before `+20`,
    /// `12` one before `7`, the header's `$` one before the values' edge);
    /// this table right-aligns every number under its header and the name
    /// column widens for a long slug. The transcript wins over the `Cost:`
    /// line where the archive names one: round 1's line says `1101k in` and
    /// the table prints the transcript's `1.10M`.
    func testTheTableOfTheCorpusFixture() throws {
        try writeCorpusFixture()
        let lines = try run(["cost", project, "example"])
        XCTAssertEqual(lines, [
            "example                         $      in  cached      out  wall tests  files   decision      PR",
            "  001 send-on-transition     2.64   1.10M     93%    17.7k  5m48   +28     12   done         #12",
            "  002 the-toggle             0.41       0       —        0  0m00    +0      3   failed         —",
            "  003 subscriptions             —       —       —        —     —   +20      7   done          #9",
            "  total                      3.05   1.10M     93%    17.7k  5m48   +48     22",
            "  1 round predates the bill and is not counted.",
        ])
        // Every line is the same shape: no tabs, no trailing space.
        for line in lines {
            XCTAssertFalse(line.contains("\t"), line)
            XCTAssertFalse(line.hasSuffix(" "), line.debugDescription)
        }
        XCTAssertEqual(try run(["cost", project]), lines, "the whole package is the one goal")
    }

    /// `--json`: one object per round with the transcript's field names,
    /// unrounded, and `null` where a round has no number.
    func testTheJSONOfTheCorpusFixture() throws {
        let (shas, _) = try writeCorpusFixture()
        let lines = try run(["cost", project, "example", "--json"])
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("2.6361237500000003"), "unrounded on the wire: \(text)")

        let goals = try XCTUnwrap(try json(lines)["goals"] as? [[String: Any]])
        XCTAssertEqual(goals.count, 1)
        let goal = goals[0]
        XCTAssertEqual(goal["goal"] as? String, "example")
        let rounds = try XCTUnwrap(goal["rounds"] as? [[String: Any]])
        XCTAssertEqual(rounds.count, 3)

        let one = rounds[0]
        XCTAssertEqual(one["goal"] as? String, "example")
        XCTAssertEqual(one["round"] as? Int, 1)
        XCTAssertEqual(one["slug"] as? String, "send-on-transition")
        XCTAssertEqual(one["sessions"] as? [String], [Self.sessions.one])
        XCTAssertEqual(one["source"] as? String, "transcript")
        XCTAssertEqual(one["totalCostUSD"] as? Double, 2.6361237500000003)
        XCTAssertEqual(one["totalDuration"] as? Int, 347686)
        XCTAssertEqual(one["totalAPIDuration"] as? Int, 244888)
        XCTAssertEqual(one["inputTokens"] as? Int, 450 + 3390)
        XCTAssertEqual(one["outputTokens"] as? Int, 17680 + 27)
        XCTAssertEqual(one["thinkingTokens"] as? Int, 9245)
        XCTAssertEqual(one["cacheReadInputTokens"] as? Int, 1_022_235)
        XCTAssertEqual(one["cacheCreationInputTokens"] as? Int, 74427)
        XCTAssertEqual(one["in"] as? Int, 1_100_502)
        XCTAssertEqual(one["cacheReadShare"] as? Double, 1_022_235.0 / 1_100_502.0)
        XCTAssertEqual(one["testsAdded"] as? Int, 28)
        XCTAssertEqual(one["filesChanged"] as? Int, 12, String(describing: one["filesChangedReason"]))
        XCTAssertTrue(one["filesChangedReason"] is NSNull)
        XCTAssertEqual(one["decision"] as? String, "done")
        XCTAssertEqual(one["pr"] as? Int, 12)
        XCTAssertEqual(one["base"] as? String, shas[0])
        XCTAssertEqual(one["result"] as? String, shas[1])

        let two = rounds[1]
        XCTAssertEqual(two["round"] as? Int, 2)
        XCTAssertEqual(two["source"] as? String, "transcript")
        XCTAssertEqual(two["totalCostUSD"] as? Double, 0.41)
        XCTAssertEqual(two["totalDuration"] as? Int, 412)
        XCTAssertEqual(two["inputTokens"] as? Int, 0)
        XCTAssertEqual(two["outputTokens"] as? Int, 0)
        XCTAssertEqual(two["cacheReadInputTokens"] as? Int, 0)
        XCTAssertEqual(two["in"] as? Int, 0)
        XCTAssertTrue(two["cacheReadShare"] is NSNull, "no share of nothing: \(String(describing: two["cacheReadShare"]))")
        XCTAssertEqual(two["testsAdded"] as? Int, 0)
        XCTAssertEqual(two["filesChanged"] as? Int, 3, String(describing: two["filesChangedReason"]))
        XCTAssertEqual(two["decision"] as? String, "failed")
        XCTAssertTrue(two["pr"] is NSNull)

        let three = rounds[2]
        XCTAssertEqual(three["round"] as? Int, 3)
        XCTAssertEqual(three["slug"] as? String, "subscriptions")
        XCTAssertTrue(three["source"] is NSNull)
        for field in ["totalCostUSD", "totalDuration", "totalAPIDuration", "inputTokens", "outputTokens",
                      "thinkingTokens", "cacheReadInputTokens", "cacheCreationInputTokens", "in", "cacheReadShare"] {
            XCTAssertTrue(three[field] is NSNull, "\(field) is null on a round with no bill, not absent")
        }
        XCTAssertEqual(three["testsAdded"] as? Int, 20)
        XCTAssertEqual(three["filesChanged"] as? Int, 7, String(describing: three["filesChangedReason"]))
        XCTAssertEqual(three["decision"] as? String, "done")
        XCTAssertEqual(three["pr"] as? Int, 9)

        let totals = try XCTUnwrap(goal["totals"] as? [String: Any])
        XCTAssertEqual(totals["roundsBilled"] as? Int, 2)
        XCTAssertEqual(totals["roundsWithoutBill"] as? Int, 1)
        XCTAssertEqual(totals["totalCostUSD"] as? Double, 2.6361237500000003 + 0.41)
        XCTAssertEqual(totals["totalDuration"] as? Int, 347686 + 412)
        XCTAssertEqual(totals["in"] as? Int, 1_100_502)
        XCTAssertEqual(totals["outputTokens"] as? Int, 17707)
        XCTAssertEqual(totals["cacheReadShare"] as? Double, 1_022_235.0 / 1_100_502.0)
        XCTAssertEqual(totals["testsAdded"] as? Int, 48)
        XCTAssertEqual(totals["filesChanged"] as? Int, 22)
    }

    // MARK: - The line path

    /// A round whose archive names no transcript reads its `Cost:` line: the
    /// line's rounding, scaled back to units, with the per-kind tokens null.
    /// A `none recorded` line is no bill, and its own footer counts it. A
    /// sha that does not resolve prints a dash for files.
    func testTheCostLineWhenTheArchiveNamesNoTranscript() throws {
        try git("init", "-q")
        let c0 = try commit("init", files: 1)
        let c1 = try commit("work", files: 4)
        try writeState("lines")
        try writeRecord("lines", 1, """
        # Round 001: the-bill-in-the-record

        - Sessions: \(Self.sessions.three)   Archives: the same
        - Base: \(c0) (main)   Result: \(c1) plus the foreman's commit
        - Cost: $4.74 · 3331k in (97% cached) · 36k out · 0h 10m

        ## Floor

        after: green. **714 tests, 0 failures**; the count is unchanged because the rules are entries.

        ## Decision

        propose (`plan.md`: archive first).

        """)
        try writeRecord("lines", 2, """
        # Round 002: no-bill

        - Sessions: \(Self.sessions.two)   Archives: the same
        - Base: 0000000 (main)   Result: \(c1)
        - Cost: none recorded (noCostStateLine)

        ## Decision

        done.

        """)
        let lines = try run(["cost", project, "lines"])
        // The whole output is the message, so a dash where a count belongs
        // prints its own footer line with what git said.
        XCTAssertEqual(Array(lines.prefix(5)), [
            "lines                               $      in  cached      out  wall tests  files   decision      PR",
            "  001 the-bill-in-the-record     4.74   3.33M     97%    36.0k 10m00     —      4   propose        —",
            "  002 no-bill                       —       —       —        —     —     —      —   done           —",
            "  total                          4.74   3.33M     97%    36.0k 10m00     —      4",
            "  1 round recorded no bill and is not counted.",
        ], lines.joined(separator: "\n"))
        // Round 2's dash is explained by git itself; the wording after
        // `fatal:` is git's own and differs between versions.
        XCTAssertEqual(lines.count, 6, lines.joined(separator: "\n"))
        XCTAssertTrue(lines[5].hasPrefix("  002 files not counted: git diff --name-only 0000000..\(c1) exited 128: fatal: "), lines[5])

        let rounds = try XCTUnwrap((try json(try run(["cost", project, "lines", "--json"]))["goals"] as? [[String: Any]])?.first?["rounds"] as? [[String: Any]])
        let one = rounds[0]
        XCTAssertEqual(one["source"] as? String, "line")
        XCTAssertEqual(one["totalCostUSD"] as? Double, 4.74)
        XCTAssertEqual(one["totalDuration"] as? Int, 600_000)
        XCTAssertEqual(one["in"] as? Int, 3_331_000)
        XCTAssertEqual(one["cacheReadShare"] as? Double, 0.97)
        XCTAssertEqual(one["outputTokens"] as? Int, 36000)
        for field in ["inputTokens", "thinkingTokens", "cacheReadInputTokens", "cacheCreationInputTokens", "totalAPIDuration"] {
            XCTAssertTrue(one[field] is NSNull, "\(field): a line does not know it")
        }
        XCTAssertTrue(one["testsAdded"] is NSNull)
        XCTAssertEqual(one["decision"] as? String, "propose")
        XCTAssertTrue(one["filesChangedReason"] is NSNull, "a count has no reason")
        XCTAssertTrue(rounds[1]["source"] is NSNull)
        XCTAssertTrue(rounds[1]["filesChanged"] is NSNull)
        XCTAssertEqual(
            (rounds[1]["filesChangedReason"] as? String)?.hasPrefix("git diff --name-only 0000000..\(c1) exited 128: fatal: "), true,
            String(describing: rounds[1]["filesChangedReason"])
        )
    }

    // MARK: - A sha with no digit

    /// A short sha of only `a` to `f` is one in a thousand, and `dcaacec`
    /// is the fixture's first commit at this date. The parser used to ask
    /// for a digit, read the line as naming no sha, and the table printed a
    /// dash for a round git could have counted: two of thirty runner runs
    /// and one of fifty here (`green-ci-again` round 2). The digit is still
    /// preferred when the line holds both, so a word like `deadbeef` beside
    /// a sha never wins.
    func testAShortShaWithNoDigitIsStillASha() throws {
        let letters = GoalLedger.parse("- Base: dcaacec (main)   Result: abcdefa on goals/x\n", number: 1)
        XCTAssertEqual(letters.base, "dcaacec")
        XCTAssertEqual(letters.result, "abcdefa")
        let both = GoalLedger.parse("- Base: deadbeef 1234567 (main)   Result: 89abcde effaced\n", number: 2)
        XCTAssertEqual(both.base, "1234567", "the sha with a digit over the hex word")
        XCTAssertEqual(both.result, "89abcde")

        try git("init", "-q")
        let c0 = try commit("init", files: 1, at: "@1700000531 +0000")
        XCTAssertEqual(c0, "dcaacec", "the pinned date's sha, abbreviated to 7 in a one-commit repository")
        let c1 = try commit("work", files: 4)
        try writeState("letters")
        try writeRecord("letters", 1, """
        # Round 001: letters

        - Base: \(c0) (main)   Result: \(c1)

        ## Decision

        done.

        """)
        let lines = try run(["cost", project, "letters"])
        XCTAssertEqual(lines, [
            "letters                         $      in  cached      out  wall tests  files   decision      PR",
            "  001 letters                   —       —       —        —     —     —      4   done           —",
            "  total                         —       —       —        —     —     —      4",
            "  1 round predates the bill and is not counted.",
        ], lines.joined(separator: "\n"))
    }

    // MARK: - The files column's failure path

    /// `filesChanged` never swallows what git said: an unresolved sha is
    /// git's own `fatal:` line with its status, a directory that is no
    /// checkout likewise, and a record that names no sha says which line.
    /// Two of thirty CI runs printed a dash here that nothing could explain
    /// (`green-ci-again` round 2).
    func testFilesChangedSaysWhyItHasNoCount() throws {
        XCTAssertEqual(GoalLedger.filesChanged(root: project, base: nil, result: "1234567"), .noSha(line: "Base:"))
        XCTAssertEqual(GoalLedger.filesChanged(root: project, base: "1234567", result: nil), .noSha(line: "Result:"))
        XCTAssertEqual(GoalLedger.filesChanged(root: project, base: nil, result: nil), .noSha(line: "Base: and Result:"))
        XCTAssertEqual(GoalLedger.FilesChanged.noSha(line: "Base:").reason, "the Base: line names no sha")

        let notACheckout = GoalLedger.filesChanged(root: project, base: "1234567", result: "89abcde")
        guard case .failed(let range, let status, let stderr) = notACheckout else {
            return XCTFail("\(notACheckout)")
        }
        XCTAssertEqual(range, "1234567..89abcde")
        // 129 with a `warning:` on git 2.39, which prints its usage after it.
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(stderr.lowercased().contains("not a git repository"), stderr)
        XCTAssertEqual(notACheckout.reason, "git diff --name-only 1234567..89abcde exited \(status): " + stderr.split(separator: "\n")[0])

        try git("init", "-q")
        let c0 = try commit("init", files: 1)
        let c1 = try commit("work", files: 2)
        XCTAssertEqual(GoalLedger.filesChanged(root: project, base: c0, result: c1), .count(2))
        XCTAssertNil(GoalLedger.FilesChanged.count(2).reason)
        let unresolved = GoalLedger.filesChanged(root: project, base: "0000000", result: c1)
        guard case .failed(_, 128, let said) = unresolved else { return XCTFail("\(unresolved)") }
        XCTAssertTrue(said.hasPrefix("fatal: "), said)
        XCTAssertTrue(said.contains("0000000..\(c1)"), said)
        XCTAssertEqual(GoalLedger.FilesChanged.notRun(error: "x").reason, "git did not start: x")
    }

    // MARK: - The parser

    func testParseReadsTheRealRecordShapes() {
        let record = GoalLedger.parse("""
        # Round 004: four-loop-rules

        - Goal: foreman-harness
        - Sessions: C7F63274-DAFB-4935-8E35-40FDC00E42BA, and CC225BFF   Archives: 0E38D020-5E5C-4BBB-9049-80393A6AB24B
        - Base: a056b3d (main), rebased onto d2ad574   Result: 2c0370e + the foreman's commit on goals/four-loop-rules-work

        ## Floor

        before: green (`swift test` 640, 3 new last round)

        ## Decision

        done. Capability 4 is complete.
        """, number: 4)
        XCTAssertEqual(record.slug, "four-loop-rules")
        XCTAssertEqual(record.sessions.map(\.uuidString), ["C7F63274-DAFB-4935-8E35-40FDC00E42BA"])
        XCTAssertEqual(record.archives.map(\.uuidString), ["0E38D020-5E5C-4BBB-9049-80393A6AB24B"])
        XCTAssertEqual(record.base, "a056b3d", "the first sha on the Base line")
        XCTAssertEqual(record.result, "2c0370e")
        XCTAssertNil(record.pr)
        XCTAssertEqual(record.testsAdded, 3)
        XCTAssertEqual(record.decision, "done")
        XCTAssertFalse(record.hasCostLine)

        let tip = GoalLedger.parse("- Base: 7090b34 (x)   Result: 280cae5 to 857e7f0, fifteen commits on the same branch (#7)\n", number: 5)
        XCTAssertEqual(tip.result, "857e7f0", "the last sha on the Result line is the tip")
        XCTAssertEqual(tip.pr, 7)
        XCTAssertEqual(tip.slug, "005", "no heading: the file's number")
    }

    func testFormatting() {
        XCTAssertEqual(GoalLedger.tokens(0), "0")
        XCTAssertEqual(GoalLedger.tokens(999), "999")
        XCTAssertEqual(GoalLedger.tokens(17707), "17.7k")
        XCTAssertEqual(GoalLedger.tokens(1_100_502), "1.10M")
        XCTAssertEqual(GoalLedger.tokens(6_066_000), "6.07M")
        XCTAssertEqual(GoalLedger.wall(347686), "5m48")
        XCTAssertEqual(GoalLedger.wall(0), "0m00")
        // Under an hour reads as minutes and seconds; at or over one it rolls
        // to hours and minutes. This case used to read "547m40", which is both
        // unreadable and wider than the column it sits in.
        XCTAssertEqual(GoalLedger.wall(3_599_000), "59m59")
        XCTAssertEqual(GoalLedger.wall(3_600_000), "1h00")
        XCTAssertEqual(GoalLedger.wall(32_860_487), "9h08")
        XCTAssertEqual(GoalLedger.wall(60_780_000), "16h53")
        XCTAssertEqual(GoalLedger.cached(read: 1_022_235, of: 1_100_502), "93%")
        XCTAssertEqual(GoalLedger.cached(read: 0, of: 0), "—")
    }

    func testCostUsageRefusals() throws {
        XCTAssertThrowsError(try run(["cost"]))
        XCTAssertThrowsError(try run(["cost", project, "a", "b"]))
        XCTAssertThrowsError(try run(["cost", project, "--bogus"]))
        XCTAssertThrowsError(try run(["cost", work.path + "/no/such/dir"]))
        try writeState("one")
        XCTAssertThrowsError(try run(["cost", project, "other"]), "a goal with no folder is an error")
        XCTAssertEqual(try run(["cost", project, "one"]).first, "one                             $      in  cached      out  wall tests  files   decision      PR")
        XCTAssertEqual(try run(["cost", project, "--json", "one"]).joined().contains("\"rounds\" : [\n\n  ]"), false)
    }

    /// This repository's own package prints without error. Round 3 of
    /// `cost-per-round` carries the first real `Cost:` line; the archives
    /// under the scratch state directory name no transcript, so the ledger
    /// reads that line, and rounds 1 and 2 predate the bill.
    func testThisRepository() throws {
        let root = CLIFixture.repositoryRoot
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/goals/cost-per-round/rounds/003.md").path) else {
            throw XCTSkip("docs/goals/cost-per-round is not beside the test source")
        }
        let lines = try run(["cost", root.path, "cost-per-round"])
        XCTAssertEqual(lines.first?.hasPrefix("cost-per-round "), true, lines.joined(separator: "\n"))
        // A smoke test over the live package, which changes with every round:
        // the row exists and carries the bill the record names, and nothing
        // about column widths or the footer count, since a wider value in a
        // later round or a back-filled line moves both. The fixture tests
        // above pin the exact table.
        let third = try XCTUnwrap(lines.first { $0.hasPrefix("  003 the-bill-in-the-record") }, lines.joined(separator: "\n"))
        XCTAssertTrue(third.contains("4.74"), third)
        XCTAssertTrue(third.contains("97%"), third)
        XCTAssertTrue(lines.contains { $0.hasPrefix("  total ") }, lines.joined(separator: "\n"))

        let all = try run(["cost", root.path])
        XCTAssertGreaterThan(all.count, lines.count, "every goal of the package")
        XCTAssertTrue(all.contains(""), "a blank line between goals")
        _ = try json(try run(["cost", root.path, "--json"]))
    }
}
