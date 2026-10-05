#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers
import XCTest

@testable import KittermDaemon

/// A scratch bare repository (`origin`), a checkout that writes to it
/// (`seed`) and a clone that never pulls (`clone`, the project root). No
/// network and no real remote: `origin` is a path.
final class GitFixture {
    let directory: URL
    var bare: String { directory.appendingPathComponent("origin.git").path }
    var seed: String { directory.appendingPathComponent("seed").path }
    var clone: String { directory.appendingPathComponent("clone").path }

    init(branch: String = "main") throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-knowledge-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        directory = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.path), isDirectory: true)
        try git(["init", "-q", "--bare", "-b", branch, bare])
        try git(["init", "-q", "-b", branch, seed])
        try git(["-C", seed, "remote", "add", "origin", bare])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// One `git` with no global and no system configuration, through the
    /// daemon's own runner, so it has a deadline.
    @discardableResult
    func git(_ args: [String]) throws -> String {
        let searchPath = PullRequestStatus.defaultSearchPath
        let options = ["-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false"]
        guard let executable = PullRequestStatus.locate("git", in: searchPath),
              let result = PullRequestStatus.run(
                  executable: executable, args: options + args, searchPath: searchPath, timeout: 30,
                  environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
              )
        else {
            throw NSError(domain: "git", code: -1, userInfo: [NSLocalizedDescriptionKey: "git did not start"])
        }
        guard result.status == 0, !result.timedOut else {
            throw NSError(domain: "git", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(result.error)",
            ])
        }
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Write `text` at `path` under `root`, parents made.
    func write(_ path: String, _ text: String, in root: String? = nil) throws {
        let url = URL(fileURLWithPath: root ?? seed).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Commit everything in `seed` and push it to the bare repository.
    func push(_ message: String = "change") throws {
        try git(["-C", seed, "add", "-A"])
        try git(["-C", seed, "commit", "-q", "--allow-empty", "-m", message])
        try git(["-C", seed, "push", "-q", "origin", "HEAD"])
    }

    /// Clone the bare repository into `clone`.
    func makeClone() throws {
        try git(["clone", "-q", bare, clone])
    }

    static func state(_ slug: String, status: String = "active", round: Int = 1, queue: String = "1. `first-task`, PR #7.") -> String {
        """
        # STATE: \(slug)

        - Status: \(status)
        - Round: \(round) of 3 in this budget (first budget)
        - Rounds total: \(round)
        - Last floor: green (2026-10-05, round \(round))
        - Updated: 2026-10-05

        ## Queue

        \(queue)

        ## Failures

        None.

        ## Proposals waiting on the human

        ## Done

        ## Next action

        Round \(round + 1) of \(slug).

        """
    }

    static func record(_ number: Int, cost: String = "$1.50 · 100k in (90% cached) · 2k out · 0h 05m") -> String {
        """
        # Round 00\(number): first-task

        - Goal: alpha
        - Started: 2026-10-05T10:00+07:00  Ended: 2026-10-05T10:05+07:00
        - Base: abc1234   Result: def5678 on `goal/alpha`, PR #7
        - Cost: \(cost)

        ## Decision

        done

        """
    }
}

/// Every `git` a `KnowledgeBase` ran: its arguments, its stdin, and
/// whether it ran on the base queue.
final class GitCalls: @unchecked Sendable {
    struct Call {
        var args: [String]
        var input: String?
        var onQueue: Bool
    }
    private let lock = NIOLock()
    private var kept: [Call] = []
    func record(_ call: Call) { lock.withLock { kept.append(call) } }
    var calls: [Call] { lock.withLock { kept } }
    func count(_ verb: String) -> Int { calls.filter { $0.args.contains(verb) }.count }
}

/// `KnowledgeBase`: the summaries of `origin/<base>` after a fetch, through
/// git objects, with the working tree, the index and `HEAD` untouched; each
/// fallback and its reason; what the tree reader refuses; the one-minute
/// bound.
final class KnowledgeBaseTests: XCTestCase {
    private var fixture: GitFixture!
    private var clock: TestClock!
    private var calls: GitCalls!
    private let knowledge = "docs/goals"

    override func setUpWithError() throws {
        fixture = try GitFixture()
        clock = TestClock()
        calls = GitCalls()
    }

    override func tearDown() {
        KnowledgeBase.queue.sync {}
        fixture.remove()
    }

    /// A base whose every `git` is the real one, recorded.
    private func makeBase(
        searchPath: String = PullRequestStatus.defaultSearchPath,
        before: (@Sendable ([String]) -> PullRequestStatus.RunResult?)? = nil
    ) -> KnowledgeBase {
        let calls = self.calls!
        let clock = self.clock!
        return KnowledgeBase(searchPath: searchPath, git: { executable, args, input, maxOutput in
            calls.record(.init(
                args: args, input: input.map { String(decoding: $0, as: UTF8.self) }, onQueue: KnowledgeBase.isOnQueue
            ))
            if let result = before?(args) { return result }
            return KnowledgeBase.run(
                executable: executable, args: args, input: input, maxOutput: maxOutput, searchPath: searchPath
            )
        }, clock: { clock.now })
    }

    /// One read of `root`, waited for.
    private func read(_ base: KnowledgeBase, root: String? = nil) -> KnowledgeBase.Snapshot {
        let root = root ?? fixture.clone
        base.refreshIfDue(root: root, knowledge: knowledge)
        KnowledgeBase.queue.sync {}
        return base.snapshot(root: root, knowledge: knowledge)
    }

    private func seedAlpha() throws {
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha"))
        try fixture.write("docs/goals/alpha/goal.md", "# Goal: alpha ships\n")
        try fixture.write("docs/goals/alpha/rounds/001.md", GitFixture.record(1))
        try fixture.push("alpha")
    }

    // MARK: - the merged base

    func testACommitPushedToTheBareRepositoryShowsWithNoChangeToTheClone() throws {
        try seedAlpha()
        try fixture.makeClone()
        let head = try fixture.git(["-C", fixture.clone, "rev-parse", "HEAD"])
        let index = try Data(contentsOf: URL(fileURLWithPath: fixture.clone + "/.git/index"))

        // The merge on the remote: alpha is done, beta is new.
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", status: "done", round: 2))
        try fixture.write("docs/goals/alpha/rounds/002.md", GitFixture.record(2))
        try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta"))
        try fixture.push("the merge")
        let merged = try fixture.git(["-C", fixture.seed, "rev-parse", "HEAD"])

        let snapshot = read(makeBase())
        XCTAssertEqual(snapshot.source, "origin/main")
        XCTAssertNil(snapshot.reason)
        XCTAssertEqual(snapshot.commit, merged)
        let goals = try XCTUnwrap(snapshot.goals)
        XCTAssertEqual(goals.map(\.slug), ["beta", "alpha"], "active first")
        let alpha = try XCTUnwrap(goals.last)
        XCTAssertEqual(alpha.status, "done")
        XCTAssertEqual(alpha.round, 2)
        XCTAssertEqual(alpha.goal, "alpha ships")
        XCTAssertEqual(alpha.lastRound, 2)
        XCTAssertEqual(alpha.lastRecord, "alpha/rounds/002.md")
        XCTAssertEqual(alpha.costUSD ?? 0, 3.0, accuracy: 0.001, "both records' Cost lines")

        // The clone: the same HEAD, the same index, a clean and old working tree.
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "symbolic-ref", "HEAD"]), "refs/heads/main")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.clone + "/.git/index")), index)
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "status", "--porcelain"]), "")
        let onDisk = try String(contentsOfFile: fixture.clone + "/docs/goals/alpha/STATE.md", encoding: .utf8)
        XCTAssertTrue(onDisk.contains("- Status: active"), "nobody pulled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.clone + "/docs/goals/beta"))
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "rev-parse", "main"]), head, "the local branch stays")
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "rev-parse", "origin/main"]), merged, "the tracking ref moved")
    }

    func testTheTreeReaderBuildsWhatTheDiskReaderBuilds() throws {
        try seedAlpha()
        try fixture.write("docs/goals/alpha/rounds/2.md", GitFixture.record(2, cost: "$0.25 · 10k in (50% cached) · 1k out · 0h 01m"))
        try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta", status: "waiting", queue: "None."))
        try fixture.write("docs/goals/gamma/STATE.md", GitFixture.state("gamma", status: "done"))
        try fixture.write("docs/goals/not a slug/STATE.md", GitFixture.state("x"))
        try fixture.write("docs/goals/no-state/goal.md", "# Goal: none\n")
        try fixture.write("docs/goals/LOOP.md", "# LOOP\n")
        try fixture.push()
        try fixture.makeClone()
        let snapshot = read(makeBase())
        let disk = try XCTUnwrap(KnowledgeFile.summaries(root: fixture.seed, knowledge: knowledge))
        XCTAssertEqual(disk.map(\.slug), ["alpha", "beta", "gamma"])
        XCTAssertEqual(snapshot.goals, disk)
    }

    func testTheBaseIsWhatOriginHEADNames() throws {
        fixture.remove()
        fixture = try GitFixture(branch: "trunk")
        try seedAlpha()
        try fixture.makeClone()
        XCTAssertEqual(read(makeBase()).source, "origin/trunk")
        XCTAssertTrue(calls.calls.contains { $0.args.suffix(2) == ["origin", "trunk"] && $0.args.contains("fetch") })
    }

    func testTheBaseIsMasterWithNoOriginHEADAndNoMain() throws {
        fixture.remove()
        fixture = try GitFixture(branch: "master")
        try seedAlpha()
        try fixture.makeClone()
        try fixture.git(["-C", fixture.clone, "remote", "set-head", "origin", "-d"])
        XCTAssertEqual(read(makeBase()).source, "origin/master")
    }

    func testTheFetchIsTheOneCommand() throws {
        try seedAlpha()
        try fixture.makeClone()
        _ = read(makeBase())
        let fetch = try XCTUnwrap(calls.calls.first { $0.args.contains("fetch") })
        XCTAssertEqual(fetch.args, ["-C", fixture.clone, "-c", "gc.auto=0", "fetch", "--quiet", "--no-tags", "origin", "main"])
        for call in calls.calls {
            for verb in ["checkout", "pull", "merge", "reset", "switch", "restore", "read-tree", "update-ref", "worktree"] {
                XCTAssertFalse(call.args.contains(verb), "\(call.args)")
            }
        }
    }

    func testAnUnchangedListingReadsNoObjectAgain() throws {
        try seedAlpha()
        try fixture.makeClone()
        let base = makeBase()
        let first = read(base)
        XCTAssertEqual(calls.count("cat-file"), 1, "one batch for the whole package")
        clock.advance(61)
        XCTAssertEqual(read(base).goals, first.goals)
        XCTAssertEqual(calls.count("fetch"), 2)
        XCTAssertEqual(calls.count("cat-file"), 1)

        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", status: "waiting"))
        try fixture.push()
        clock.advance(61)
        XCTAssertEqual(read(base).goals?.first?.status, "waiting")
        XCTAssertEqual(calls.count("cat-file"), 2)
    }

    // MARK: - the fallbacks

    func testBeforeTheFirstReadTheReasonSaysSo() {
        let snapshot = makeBase().snapshot(root: fixture.clone, knowledge: knowledge)
        XCTAssertNil(snapshot.goals)
        XCTAssertNil(snapshot.source)
        XCTAssertEqual(snapshot.reason, "not read yet")
    }

    func testNoRemote() throws {
        try fixture.git(["init", "-q", "-b", "main", fixture.clone])
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha"), in: fixture.clone)
        let snapshot = read(makeBase())
        XCTAssertNil(snapshot.goals)
        XCTAssertEqual(snapshot.reason, "no origin remote")
        XCTAssertEqual(calls.count("fetch"), 0)
    }

    func testARootThatIsNoCheckout() throws {
        let plain = fixture.directory.appendingPathComponent("plain").path
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha"), in: plain)
        let snapshot = read(makeBase(), root: plain)
        XCTAssertNil(snapshot.goals)
        XCTAssertEqual(snapshot.reason, "no origin remote")
    }

    func testAFailedFetchDropsTheSummariesAndNamesTheExitCode() throws {
        try seedAlpha()
        try fixture.makeClone()
        let base = makeBase()
        XCTAssertNotNil(read(base).goals)

        try fixture.git(["-C", fixture.clone, "remote", "set-url", "origin", fixture.directory.path + "/gone.git"])
        clock.advance(61)
        let snapshot = read(base)
        XCTAssertNil(snapshot.goals, "the routes read the working tree")
        XCTAssertNil(snapshot.source)
        XCTAssertEqual(snapshot.reason, "git fetch exited 128")
        XCTAssertNil(try base.file(root: fixture.clone, knowledge: knowledge, path: "alpha/STATE.md"))

        // The remote is back: the next read answers the base again.
        try fixture.git(["-C", fixture.clone, "remote", "set-url", "origin", fixture.bare])
        clock.advance(61)
        XCTAssertEqual(read(base).source, "origin/main")
    }

    func testAFetchThatTimesOut() throws {
        try seedAlpha()
        try fixture.makeClone()
        let base = makeBase(before: { args in
            args.contains("fetch") ? PullRequestStatus.RunResult(status: 143, timedOut: true) : nil
        })
        let snapshot = read(base)
        XCTAssertNil(snapshot.goals)
        XCTAssertEqual(snapshot.reason, "git fetch timed out after 20 s")
    }

    func testAHungGitIsEndedAtTheTimeout() throws {
        let started = Date()
        let result = try XCTUnwrap(KnowledgeBase.run(
            executable: "/bin/sleep", args: ["3"], input: nil, maxOutput: 0, searchPath: "/usr/bin:/bin", timeout: 0.3
        ))
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testAMissingBase() throws {
        try seedAlpha()
        try fixture.makeClone()
        // A clone that tracks another branch alone: the fetch of `main`
        // succeeds and writes no `origin/main`.
        try fixture.git(["-C", fixture.clone, "config", "remote.origin.fetch", "+refs/heads/other:refs/remotes/origin/other"])
        try fixture.git(["-C", fixture.clone, "remote", "set-head", "origin", "-d"])
        try fixture.git(["-C", fixture.clone, "update-ref", "-d", "refs/remotes/origin/main"])
        let snapshot = read(makeBase())
        XCTAssertNil(snapshot.goals)
        XCTAssertEqual(snapshot.reason, "origin/main is missing")
    }

    func testNoKnowledgeDirectoryOnTheBase() throws {
        try fixture.write("README.md", "hello\n")
        try fixture.write("docs/other.md", "other\n")
        try fixture.push()
        try fixture.makeClone()
        try fixture.write("docs/goals/local/STATE.md", GitFixture.state("local"), in: fixture.clone)
        let snapshot = read(makeBase())
        XCTAssertNil(snapshot.goals)
        XCTAssertEqual(snapshot.reason, "no docs/goals directory on origin/main")
    }

    func testAKnowledgePathThatIsAFileOrASymlinkOnTheBase() throws {
        try fixture.write("real/alpha/STATE.md", GitFixture.state("alpha"))
        try FileManager.default.createDirectory(atPath: fixture.seed + "/docs", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.seed + "/docs/goals", withDestinationPath: "../real")
        try fixture.push()
        try fixture.makeClone()
        let snapshot = read(makeBase())
        XCTAssertNil(snapshot.goals, "a symlinked knowledge directory is refused")
        XCTAssertEqual(snapshot.reason, "no docs/goals directory on origin/main")
    }

    func testGitAbsentFromThePath() throws {
        try seedAlpha()
        try fixture.makeClone()
        let snapshot = read(makeBase(searchPath: fixture.directory.path))
        XCTAssertNil(snapshot.goals)
        XCTAssertEqual(snapshot.reason, "git is not on PATH")
        XCTAssertTrue(calls.calls.isEmpty)
    }

    // MARK: - what the tree reader refuses

    func testASymlinkAndASubmoduleInTheTreeAreSkipped() throws {
        try fixture.write("docs/goals/good-goal/STATE.md", GitFixture.state("good-goal"))
        try fixture.write("docs/goals/good-goal/rounds/001.md", GitFixture.record(1))
        try fixture.write("docs/goals/other-goal/STATE.md", GitFixture.state("other-goal"))
        try fixture.write("docs/goals/linked-state/goal.md", "# Goal: linked\n")
        let goals = fixture.seed + "/docs/goals"
        let files = FileManager.default
        // A symlinked goal folder, `STATE.md`, `goal.md`, record and `rounds/`.
        try files.createSymbolicLink(atPath: goals + "/link-goal", withDestinationPath: "good-goal")
        try files.createSymbolicLink(atPath: goals + "/linked-state/STATE.md", withDestinationPath: "../good-goal/STATE.md")
        try files.createSymbolicLink(atPath: goals + "/good-goal/goal.md", withDestinationPath: "../linked-state/goal.md")
        try files.createSymbolicLink(atPath: goals + "/good-goal/rounds/002.md", withDestinationPath: "001.md")
        try files.createSymbolicLink(atPath: goals + "/other-goal/rounds", withDestinationPath: "../good-goal/rounds")
        try fixture.push("links")
        // A submodule: a gitlink entry of mode 160000 where a goal folder would be.
        let commit = try fixture.git(["-C", fixture.seed, "rev-parse", "HEAD"])
        try fixture.git(["-C", fixture.seed, "update-index", "--add", "--cacheinfo", "160000,\(commit),docs/goals/sub-goal"])
        try fixture.git(["-C", fixture.seed, "commit", "-q", "-m", "a submodule"])
        try fixture.git(["-C", fixture.seed, "push", "-q", "origin", "HEAD"])
        let listing = try fixture.git(["-C", fixture.seed, "ls-tree", "-r", "-t", "HEAD", "--", "docs/goals"])
        XCTAssertTrue(listing.contains("160000 commit"), listing)
        XCTAssertTrue(listing.contains("120000 blob"), listing)
        try fixture.makeClone()

        let base = makeBase()
        let goalsRead = try XCTUnwrap(read(base).goals)
        XCTAssertEqual(goalsRead.map(\.slug), ["good-goal", "other-goal"])
        let good = try XCTUnwrap(goalsRead.first)
        XCTAssertNil(good.goal, "a symlinked goal.md is not read")
        XCTAssertEqual(good.lastRecord, "good-goal/rounds/002.md", "the name is listed, as on disk")
        XCTAssertEqual(good.costUSD ?? 0, 1.5, accuracy: 0.001, "the symlinked record counts no cost")
        XCTAssertNil(goalsRead.last?.lastRound, "a symlinked rounds/ reads as no records")

        // No symlink's blob was asked of git.
        let links = try fixture.git(["-C", fixture.seed, "ls-tree", "-r", "HEAD", "--", "docs/goals"])
            .split(separator: "\n").filter { $0.hasPrefix("120000") }.map { String($0.split(separator: "\t")[0].split(separator: " ")[2]) }
        XCTAssertEqual(links.count, 5)
        let asked = calls.calls.compactMap(\.input).joined()
        for oid in links { XCTAssertFalse(asked.contains(oid), "symlink blob \(oid) was read") }

        // The file route's reader refuses the same entries.
        func failure(_ path: String) -> KnowledgeFile.Failure? {
            do {
                _ = try base.file(root: fixture.clone, knowledge: knowledge, path: path)
                return nil
            } catch { return error as? KnowledgeFile.Failure }
        }
        XCTAssertEqual(failure("linked-state/STATE.md"), .refused)
        XCTAssertEqual(failure("link-goal"), .refused)
        XCTAssertEqual(failure("link-goal/STATE.md"), .refused)
        XCTAssertEqual(failure("other-goal/rounds/001.md"), .refused)
        XCTAssertEqual(failure("sub-goal"), .notFound)
        XCTAssertEqual(failure("sub-goal/STATE.md"), .notFound)
        XCTAssertEqual(failure("good-goal"), .notFound, "a directory")
        XCTAssertEqual(failure("good-goal/missing.md"), .notFound)
        XCTAssertEqual(failure("../README.md"), .badPath)
        XCTAssertEqual(failure("/etc/passwd"), .badPath)
    }

    func testNoPathOutsideTheKnowledgeDirectoryIsRead() throws {
        try seedAlpha()
        try fixture.write("secret.md", "the secret outside\n")
        try fixture.write("docs/secret.md", "the secret beside\n")
        try fixture.write("docs/goalsmore/alpha/STATE.md", GitFixture.state("outside"))
        try fixture.write("docs/goals/plan.md", "a file of the package that no summary reads\n")
        try fixture.push()
        try fixture.makeClone()
        let base = makeBase()
        XCTAssertEqual(read(base).goals?.map(\.slug), ["alpha"])
        _ = try base.file(root: fixture.clone, knowledge: knowledge, path: "plan.md")

        let inside = Set(try fixture.git(["-C", fixture.seed, "ls-tree", "-r", "HEAD", "--", "docs/goals/"])
            .split(separator: "\n").map { String($0.split(separator: "\t")[0].split(separator: " ")[2]) })
        var asked: [String] = []
        for call in calls.calls {
            if call.args.contains("ls-tree") {
                XCTAssertEqual(call.args.suffix(2), ["--", "docs/goals"], "the listing names the knowledge directory alone")
            }
            if call.args.contains("cat-file") {
                asked += (call.input ?? "").split(separator: "\n").map(String.init)
                if call.args.last != "--batch" { asked.append(call.args.last ?? "") }
            }
            XCTAssertFalse(call.args.contains("show"), "\(call.args)")
            XCTAssertFalse(call.args.contains("archive"), "\(call.args)")
        }
        XCTAssertFalse(asked.isEmpty)
        for oid in asked { XCTAssertTrue(inside.contains(oid), "\(oid) is not under docs/goals") }
        // The summaries read STATE.md, goal.md and the record; the file read `plan.md`.
        XCTAssertEqual(Set(asked).count, 4)
    }

    func testTheListingDropsWhatIsOutsideTheKnowledgeDirectory() {
        let oid = String(repeating: "a", count: 40)
        func line(_ mode: String, _ type: String, _ size: String, _ path: String) -> String {
            "\(mode) \(type) \(oid) \(size)\t\(path)\0"
        }
        let listing = line("040000", "tree", "      -", "docs")
            + line("040000", "tree", "      -", "docs/goals")
            + line("100644", "blob", "     12", "docs/goals/LOOP.md")
            + line("040000", "tree", "      -", "docs/goals/alpha")
            + line("100644", "blob", "    120", "docs/goals/alpha/STATE.md")
            + line("100644", "blob", "      9", "docs/goalsmore/STATE.md")
            + line("100644", "blob", "      9", "secret.md")
            + "garbage with no tab\0"
        let tree = KnowledgeBase.tree(listing: Data(listing.utf8), knowledge: "docs/goals")
        XCTAssertEqual(tree?.entries.keys.sorted(), ["LOOP.md", "alpha", "alpha/STATE.md"])
        XCTAssertEqual(tree?.children[""]?.sorted(), ["LOOP.md", "alpha"])
        XCTAssertEqual(tree?.entries["alpha/STATE.md"]?.size, 120)
        XCTAssertNil(KnowledgeBase.tree(listing: Data(line("100644", "blob", "3", "docs/goals").utf8), knowledge: "docs/goals"))
        XCTAssertNil(KnowledgeBase.tree(listing: Data(line("120000", "blob", "3", "docs/goals").utf8), knowledge: "docs/goals"))
        XCTAssertNil(KnowledgeBase.tree(listing: Data(), knowledge: "docs/goals"))
    }

    func testTheSameCapsAsOnDisk() throws {
        for index in 0..<(KnowledgeFile.maxGoalFolders + 1) {
            let slug = String(format: "goal-%03d", index)
            try fixture.write("docs/goals/\(slug)/STATE.md", GitFixture.state(slug))
        }
        // Over 256 KiB: a goal with no fields, and a record that counts no cost.
        let padding = String(repeating: "x", count: KnowledgeFile.maxBytes)
        try fixture.write("docs/goals/goal-000/STATE.md", GitFixture.state("goal-000") + padding)
        try fixture.write("docs/goals/goal-001/rounds/001.md", GitFixture.record(1))
        try fixture.write("docs/goals/goal-001/rounds/002.md", GitFixture.record(2) + padding)
        try fixture.push()
        try fixture.makeClone()
        let base = makeBase()
        let goals = try XCTUnwrap(read(base).goals)
        XCTAssertEqual(goals.count, KnowledgeFile.maxGoalFolders)
        XCTAssertFalse(goals.contains { $0.slug == "goal-064" }, "the 65th folder in name order is skipped")
        let big = try XCTUnwrap(goals.first { $0.slug == "goal-000" })
        XCTAssertNil(big.status)
        let one = try XCTUnwrap(goals.first { $0.slug == "goal-001" })
        XCTAssertEqual(one.costUSD ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(one.lastRecord, "goal-001/rounds/002.md")
        XCTAssertEqual(goals, KnowledgeFile.summaries(root: fixture.seed, knowledge: knowledge))
        XCTAssertThrowsError(try base.file(root: fixture.clone, knowledge: knowledge, path: "goal-000/STATE.md")) {
            XCTAssertEqual($0 as? KnowledgeFile.Failure, .tooLarge)
        }
    }

    // MARK: - one file

    func testAFileComesFromTheCommitOfTheSummaries() throws {
        try seedAlpha()
        try fixture.makeClone()
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", status: "done"))
        try fixture.write("docs/goals/facts.md", "a fact of the merge\n")
        try fixture.push()
        let base = makeBase()
        XCTAssertNil(try base.file(root: fixture.clone, knowledge: knowledge, path: "alpha/STATE.md"), "no read yet")
        _ = read(base)
        let state = try XCTUnwrap(try base.file(root: fixture.clone, knowledge: knowledge, path: "alpha/STATE.md"))
        XCTAssertTrue(String(decoding: state.data, as: UTF8.self).contains("- Status: done"))
        XCTAssertEqual(state.contentType, "text/plain; charset=utf-8")
        let facts = try XCTUnwrap(try base.file(root: fixture.clone, knowledge: knowledge, path: "facts.md"))
        XCTAssertEqual(String(decoding: facts.data, as: UTF8.self), "a fact of the merge\n")
        // A file the working tree alone holds is not on the base.
        try fixture.write("docs/goals/draft.md", "local\n", in: fixture.clone)
        XCTAssertThrowsError(try base.file(root: fixture.clone, knowledge: knowledge, path: "draft.md")) {
            XCTAssertEqual($0 as? KnowledgeFile.Failure, .notFound)
        }
    }

    func testTheBatchParse() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let c = String(repeating: "c", count: 40), d = String(repeating: "d", count: 40)
        let batch = "\(a) blob 6\nline\n\n\n\(b) missing\n\(c) tree 3\nxyz\n\(d) blob 0\n\n\(a) blob 9\ncut"
        let blobs = KnowledgeBase.blobs(batch: Data(batch.utf8))
        XCTAssertEqual(blobs[a], Data("line\n\n".utf8), "the size decides the end, not a newline")
        XCTAssertNil(blobs[b])
        XCTAssertNil(blobs[c], "a tree is not a blob")
        XCTAssertEqual(blobs[d], Data())
        XCTAssertEqual(blobs.count, 2, "the cut object is dropped")
    }

    func testTheRunnerHandsOverStdinWhole() throws {
        let input = Data((0..<300_000).map { UInt8(truncatingIfNeeded: 32 + $0 % 90) })
        let result = try XCTUnwrap(PullRequestStatus.run(
            executable: "/bin/cat", args: [], searchPath: "/usr/bin:/bin", timeout: 10, input: input
        ))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, input)
        let capped = try XCTUnwrap(PullRequestStatus.run(
            executable: "/bin/cat", args: [], searchPath: "/usr/bin:/bin", timeout: 10, input: input, maxOutput: 1000
        ))
        XCTAssertEqual(capped.output.count, 1000)
        let named = try XCTUnwrap(PullRequestStatus.run(
            executable: "/bin/sh", args: ["-c", "printf %s \"$GIT_TERMINAL_PROMPT$KITTERM_TEST_EXTRA\""],
            searchPath: "/usr/bin:/bin", timeout: 10, environment: ["GIT_TERMINAL_PROMPT": "0", "KITTERM_TEST_EXTRA": "x"]
        ))
        XCTAssertEqual(String(decoding: named.output, as: UTF8.self), "0x")
    }

    // MARK: - the bound

    func testOneReadAMinutePerRoot() throws {
        try seedAlpha()
        try fixture.makeClone()
        let base = makeBase()
        XCTAssertTrue(base.refreshIfDue(root: fixture.clone, knowledge: knowledge))
        KnowledgeBase.queue.sync {}
        XCTAssertFalse(base.refreshIfDue(root: fixture.clone, knowledge: knowledge))
        clock.advance(59)
        XCTAssertFalse(base.refreshIfDue(root: fixture.clone, knowledge: knowledge))
        KnowledgeBase.queue.sync {}
        XCTAssertEqual(calls.count("fetch"), 1)
        clock.advance(1)
        XCTAssertTrue(base.refreshIfDue(root: fixture.clone, knowledge: knowledge))
        KnowledgeBase.queue.sync {}
        XCTAssertEqual(calls.count("fetch"), 2)
    }

    func testAFailedReadIsBoundedToo() throws {
        try fixture.git(["init", "-q", "-b", "main", fixture.clone])
        let base = makeBase()
        XCTAssertEqual(read(base).reason, "no origin remote")
        let after = calls.calls.count
        XCTAssertFalse(base.refreshIfDue(root: fixture.clone, knowledge: knowledge))
        KnowledgeBase.queue.sync {}
        XCTAssertEqual(calls.calls.count, after)
    }

    func testTheMinuteCountsFromTheEndOfAFetch() throws {
        try seedAlpha()
        try fixture.makeClone()
        let clock = self.clock!
        // A fetch that takes 30 s of the clock.
        let base = makeBase(before: { args in
            if args.contains("fetch") { clock.advance(30) }
            return nil
        })
        XCTAssertNotNil(read(base).goals)
        clock.advance(31)
        XCTAssertFalse(base.refreshIfDue(root: fixture.clone, knowledge: knowledge), "61 s after the start, 31 s after the end")
        clock.advance(29)
        XCTAssertTrue(base.refreshIfDue(root: fixture.clone, knowledge: knowledge))
    }

    func testNoSecondReadWhileOneRuns() throws {
        try seedAlpha()
        try fixture.makeClone()
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let base = makeBase(before: { args in
            if args.contains("fetch") {
                entered.signal()
                gate.wait()
            }
            return nil
        })
        XCTAssertTrue(base.refreshIfDue(root: fixture.clone, knowledge: knowledge))
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        clock.advance(600)
        XCTAssertFalse(base.refreshIfDue(root: fixture.clone, knowledge: knowledge))
        XCTAssertEqual(base.snapshot(root: fixture.clone, knowledge: knowledge).reason, "not read yet",
                       "the snapshot answers under the lock while the fetch runs")
        gate.signal()
        KnowledgeBase.queue.sync {}
        XCTAssertEqual(calls.count("fetch"), 1)
    }

    func testEveryGitOfAReadRunsOnTheBaseQueue() throws {
        try seedAlpha()
        try fixture.makeClone()
        XCTAssertNotNil(read(makeBase()).goals)
        XCTAssertGreaterThanOrEqual(calls.calls.count, 5)
        XCTAssertTrue(calls.calls.allSatisfy(\.onQueue))
        XCTAssertFalse(KnowledgeBase.isOnQueue)
    }
}
