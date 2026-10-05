#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers
import XCTest

@testable import KittermDaemon

/// `KnowledgeBase` and the open goal branches (`sessions-workflow` round 4):
/// a goal read from `origin/goal/<slug>` for an open pull request, the merge
/// with the base and the working tree, the branch name rule, the jail of
/// one goal folder, the bound, and where the `git` runs. The remote is a
/// scratch bare repository; no network and no `gh`.
final class KnowledgeBranchTests: XCTestCase {
    private var fixture: GitFixture!
    private var clock: TestClock!
    private var calls: GitCalls!
    private let knowledge = "docs/goals"

    override func setUpWithError() throws {
        fixture = try GitFixture()
        clock = TestClock()
        calls = GitCalls()
        // The base holds alpha, round 1.
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha"))
        try fixture.write("docs/goals/alpha/rounds/001.md", GitFixture.record(1))
        try fixture.push("alpha")
    }

    override func tearDown() {
        KnowledgeBase.queue.sync {}
        fixture.remove()
    }

    /// A base whose every `git` is the real one, recorded.
    private func makeBase(
        before: (@Sendable ([String]) -> PullRequestStatus.RunResult?)? = nil
    ) -> KnowledgeBase {
        let calls = self.calls!
        let clock = self.clock!
        let searchPath = PullRequestStatus.defaultSearchPath
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

    /// One read of the clone with `branches`, waited for.
    private func read(_ base: KnowledgeBase, _ branches: [KnowledgeBase.GoalBranch]) -> KnowledgeBase.Snapshot {
        base.refreshIfDue(root: fixture.clone, knowledge: knowledge, branches: branches)
        KnowledgeBase.queue.sync {}
        return base.snapshot(root: fixture.clone, knowledge: knowledge)
    }

    /// Commit on `branch` of the seed what `body` writes, push it, and go
    /// back to `main`.
    private func onBranch(_ branch: String, _ body: () throws -> Void) throws {
        if (try? fixture.git(["-C", fixture.seed, "checkout", "-q", branch])) == nil {
            try fixture.git(["-C", fixture.seed, "checkout", "-q", "-b", branch])
        }
        try body()
        try fixture.push(branch)
        try fixture.git(["-C", fixture.seed, "checkout", "-q", "main"])
    }

    /// The goal branch of beta: its folder at round 2, with one record.
    private func pushBeta() throws {
        try onBranch("goal/beta") {
            try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta", round: 2))
            try fixture.write("docs/goals/beta/goal.md", "# Goal: beta ships\n")
            try fixture.write("docs/goals/beta/rounds/002.md", GitFixture.record(2))
        }
    }

    private func merged(_ snapshot: KnowledgeBase.Snapshot) -> [KnowledgeBase.SourcedGoal] {
        snapshot.merged(disk: KnowledgeFile.summaries(root: fixture.clone, knowledge: knowledge)) ?? []
    }

    private func fetches() -> [[String]] { calls.calls.map(\.args).filter { $0.contains("fetch") } }

    private func refspec(_ name: String) -> String { "+refs/heads/\(name):refs/remotes/origin/\(name)" }

    private func pull(_ number: Int, _ head: String, _ state: String = "open") -> PullRequestStatus.Pull {
        PullRequestStatus.Pull(
            number: number, title: head, state: state, draft: false, headRefName: head, mergedAt: nil,
            url: "https://github.com/o/r/pull/\(number)", ci: nil, additions: 0, deletions: 0
        )
    }

    private let beta = KnowledgeBase.GoalBranch(slug: "beta", pull: 12)

    // MARK: - a goal on its branch

    func testAGoalOnlyOnAnOpenBranchShowsWithItsBranchState() throws {
        try fixture.makeClone()
        try pushBeta()
        let head = try fixture.git(["-C", fixture.clone, "rev-parse", "HEAD"])

        let snapshot = read(makeBase(), [beta])
        XCTAssertEqual(snapshot.source, "origin/main")
        XCTAssertEqual(snapshot.goals?.compactMap(\.slug), ["alpha"], "the base has no beta")
        XCTAssertEqual(snapshot.branches.count, 1)
        let goal = try XCTUnwrap(snapshot.branches.first)
        XCTAssertEqual(goal.slug, "beta")
        XCTAssertEqual(goal.pull, 12)
        XCTAssertEqual(goal.source, "origin/goal/beta")
        XCTAssertNil(goal.reason)
        XCTAssertEqual(goal.summary.round, 2)
        XCTAssertEqual(goal.summary.goal, "beta ships")
        XCTAssertEqual(goal.summary.lastRecord, "beta/rounds/002.md")
        XCTAssertEqual(goal.commit, try fixture.git(["-C", fixture.bare, "rev-parse", "goal/beta"]))

        let goals = merged(snapshot)
        XCTAssertEqual(goals.compactMap(\.summary.slug), ["alpha", "beta"])
        XCTAssertEqual(goals.map(\.source), ["origin/main", "origin/goal/beta"])
        XCTAssertEqual(goals.map(\.pull), [nil, 12])
        XCTAssertEqual(goals[1].json["source"] as? String, "origin/goal/beta")
        XCTAssertEqual(goals[1].json["pullRequest"] as? Int, 12)
        XCTAssertEqual(goals[0].json["source"] as? String, "origin/main")
        XCTAssertNil(goals[0].json["pullRequest"])

        // The checkout is as it was: no file, no branch, no moved HEAD.
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "status", "--porcelain"]), "")
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "branch", "--format=%(refname:short)"]), "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.clone + "/docs/goals/beta"))
    }

    func testTheBranchSummaryWinsOverTheBasesForTheSameSlug() throws {
        try fixture.makeClone()
        try onBranch("goal/alpha") {
            try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", round: 3))
        }
        let snapshot = read(makeBase(), [.init(slug: "alpha", pull: 9)])
        XCTAssertEqual(snapshot.goals?.first?.round, 1, "the base keeps its own summary")
        let goals = merged(snapshot)
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals[0].summary.round, 3)
        XCTAssertEqual(goals[0].source, "origin/goal/alpha")
        XCTAssertEqual(goals[0].pull, 9)
    }

    func testAPushToTheBranchShowsAfterTheNextMinute() throws {
        try fixture.makeClone()
        try pushBeta()
        let base = makeBase()
        XCTAssertEqual(read(base, [beta]).branches.first?.summary.round, 2)
        try onBranch("goal/beta") {
            try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta", status: "waiting", round: 3))
        }
        XCTAssertEqual(read(base, [beta]).branches.first?.summary.round, 2, "inside the minute")
        clock.advance(KnowledgeBase.refreshSeconds + 1)
        let later = read(base, [.init(slug: "beta", pull: 13)])
        XCTAssertEqual(later.branches.first?.summary.round, 3)
        XCTAssertEqual(later.branches.first?.summary.status, "waiting")
        XCTAssertEqual(later.branches.first?.pull, 13)
    }

    func testAnUnchangedBranchListingReadsNoObjectAgain() throws {
        try fixture.makeClone()
        try pushBeta()
        let base = makeBase()
        let first = read(base, [beta])
        let batches = calls.count("cat-file")
        clock.advance(KnowledgeBase.refreshSeconds + 1)
        let second = read(base, [.init(slug: "beta", pull: 14)])
        XCTAssertEqual(calls.count("cat-file"), batches)
        XCTAssertEqual(second.branches.first?.summary, first.branches.first?.summary)
        XCTAssertEqual(second.branches.first?.pull, 14, "the pull request number follows the list")
    }

    // MARK: - closed, merged, working tree

    func testOnlyAnOpenPullRequestNamesAGoalBranch() {
        let branches = KnowledgeBase.goalBranches(pulls: [
            pull(1, "goal/open"), pull(2, "goal/merged", "merged"), pull(3, "goal/closed", "closed"),
            pull(4, "chore/tidy"), pull(5, "feature"), pull(6, "goal/open"), pull(7, "refs/goal/x"),
        ])
        XCTAssertEqual(branches, [.init(slug: "open", pull: 1)], "one per slug, the first in gh's order")
    }

    func testAClosedOrMergedPullRequestsBranchIsNoLongerRead() throws {
        try fixture.makeClone()
        try onBranch("goal/alpha") {
            try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", round: 3))
        }
        let base = makeBase()
        let open = KnowledgeBase.goalBranches(pulls: [pull(9, "goal/alpha")])
        XCTAssertEqual(merged(read(base, open)).first?.summary.round, 3)

        // The pull request merges: the base has round 4, the list says merged.
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", status: "done", round: 4))
        try fixture.push("the merge")
        clock.advance(KnowledgeBase.refreshSeconds + 1)
        let before = fetches().count
        for state in ["merged", "closed"] {
            let snapshot = read(base, KnowledgeBase.goalBranches(pulls: [pull(9, "goal/alpha", state)]))
            XCTAssertEqual(snapshot.branches, [], state)
            let goals = merged(snapshot)
            XCTAssertEqual(goals.count, 1)
            XCTAssertEqual(goals[0].summary.round, 4, "the base answers again")
            XCTAssertEqual(goals[0].source, "origin/main")
            XCTAssertNil(goals[0].pull)
            clock.advance(KnowledgeBase.refreshSeconds + 1)
        }
        for fetch in fetches().dropFirst(before) {
            XCTAssertFalse(fetch.contains(refspec("goal/alpha")), "\(fetch)")
        }
        XCTAssertNoThrow(try base.file(root: fixture.clone, knowledge: knowledge, path: "alpha/STATE.md"))
        let state = try XCTUnwrap(try base.file(root: fixture.clone, knowledge: knowledge, path: "alpha/STATE.md"))
        XCTAssertTrue(String(decoding: state.data, as: UTF8.self).contains("- Status: done"))
    }

    func testAGoalOnlyTheWorkingTreeHoldsIsKeptWithItsSource() throws {
        try fixture.makeClone()
        try pushBeta()
        try fixture.write("docs/goals/local/STATE.md", GitFixture.state("local"), in: fixture.clone)
        // The working tree's alpha is old; the base's wins.
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", round: 2))
        try fixture.push("alpha round 2")

        let base = makeBase()
        let snapshot = read(base, [beta])
        let goals = merged(snapshot)
        XCTAssertEqual(goals.compactMap(\.summary.slug), ["alpha", "beta", "local"])
        XCTAssertEqual(goals.map(\.source), ["origin/main", "origin/goal/beta", KnowledgeBase.workingTree])
        XCTAssertEqual(goals[0].summary.round, 2)
        XCTAssertEqual(goals[2].json["source"] as? String, "working tree")
        XCTAssertNil(goals[2].json["pullRequest"])
        // The file route hands a working-tree-only goal to the disk reader,
        // and still answers the base's own folders from the base.
        XCTAssertNil(try base.file(root: fixture.clone, knowledge: knowledge, path: "local/STATE.md"))
        // A working-tree folder the summary does not list (no STATE.md) is not served.
        try fixture.write("docs/goals/notes/draft.md", "a draft\n", in: fixture.clone)
        XCTAssertFalse(goals.contains { $0.summary.slug == "notes" })
        XCTAssertThrowsError(try base.file(root: fixture.clone, knowledge: knowledge, path: "notes/draft.md")) {
            XCTAssertEqual($0 as? KnowledgeFile.Failure, .notFound)
        }
        XCTAssertThrowsError(try base.file(root: fixture.clone, knowledge: knowledge, path: "alpha/none.md"))
    }

    func testWithNoBaseTheBranchLaysOverTheWorkingTree() throws {
        try fixture.makeClone()
        try pushBeta()
        try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta", round: 1), in: fixture.clone)
        var snapshot = read(makeBase(), [beta])
        snapshot.goals = nil
        snapshot.source = nil
        let goals = merged(snapshot)
        XCTAssertEqual(goals.compactMap(\.summary.slug), ["alpha", "beta"])
        XCTAssertEqual(goals.map(\.source), [KnowledgeBase.workingTree, "origin/goal/beta"])
        XCTAssertEqual(goals[1].summary.round, 2)
        XCTAssertNil(KnowledgeBase.Snapshot().merged(disk: nil), "no source holds a knowledge directory")
        XCTAssertEqual(KnowledgeBase.Snapshot().merged(disk: [])?.count, 0)
    }

    // MARK: - forks, stale refs, two pull requests

    func testAForkPullRequestWithAGoalHeadIsSkipped() throws {
        var fork = pull(30, "goal/beta")
        fork.crossRepository = true
        // The fork is first in gh's order: it does not win the dedupe, so
        // origin's branch keeps origin's number.
        XCTAssertEqual(
            KnowledgeBase.goalBranches(pulls: [fork, pull(12, "goal/beta")]), [.init(slug: "beta", pull: 12)])
        XCTAssertEqual(KnowledgeBase.goalBranches(pulls: [fork]), [], "a fork alone names no branch of origin")
        // Forks take no slot of the bound.
        let forks = (0..<KnowledgeBase.maxGoalBranches).map { index -> PullRequestStatus.Pull in
            var one = pull(40 + index, "goal/f\(index)")
            one.crossRepository = true
            return one
        }
        XCTAssertEqual(
            KnowledgeBase.goalBranches(pulls: forks + [pull(12, "goal/beta")]), [.init(slug: "beta", pull: 12)])

        // The field comes from `gh` and stays out of the pulls route's answer.
        let json = """
            [{"number":30,"state":"OPEN","headRefName":"goal/beta","isCrossRepository":true},
             {"number":12,"state":"OPEN","headRefName":"goal/beta","isCrossRepository":false},
             {"number":11,"state":"OPEN","headRefName":"goal/old"}]
            """
        let parsed = try XCTUnwrap(PullRequestStatus.parse(Data(json.utf8)))
        XCTAssertEqual(parsed.map(\.crossRepository), [true, false, false])
        XCTAssertNil(parsed[0].json["isCrossRepository"])
        XCTAssertNil(parsed[0].json["crossRepository"])
        XCTAssertEqual(
            KnowledgeBase.goalBranches(pulls: parsed), [.init(slug: "beta", pull: 12), .init(slug: "old", pull: 11)])
        XCTAssertTrue(PullRequestStatus.listArguments(repository: "o/r").last?.hasSuffix(",isCrossRepository") == true)

        // With origin's branch on the remote too, the fork's number is on no goal.
        try fixture.makeClone()
        try pushBeta()
        let snapshot = read(makeBase(), KnowledgeBase.goalBranches(pulls: [fork, pull(12, "goal/beta")]))
        XCTAssertEqual(snapshot.branches.map(\.pull), [12])
    }

    func testTwoPullRequestsForOneSlugReadTheBranchOnceWithTheFirstNumber() throws {
        try fixture.makeClone()
        try pushBeta()
        let branches = KnowledgeBase.goalBranches(pulls: [
            pull(21, "goal/beta"), pull(12, "goal/beta"), pull(20, "goal/beta", "closed"),
        ])
        XCTAssertEqual(branches, [.init(slug: "beta", pull: 21)], "the first open one in gh's order")
        let snapshot = read(makeBase(), branches)
        XCTAssertEqual(snapshot.branches.map(\.pull), [21])
        XCTAssertEqual(fetches().first?.filter { $0 == refspec("goal/beta") }.count, 1)
        XCTAssertEqual(merged(snapshot).compactMap(\.summary.slug), ["alpha", "beta"])
    }

    func testABranchMissingOnOriginWithAStaleLocalRefIsNotRead() throws {
        // An earlier goal's branch: the clone holds origin/goal/alpha, the
        // remote deleted it at the merge.
        try onBranch("goal/alpha") {
            try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", status: "stopped", round: 7))
        }
        try fixture.makeClone()
        XCTAssertNotNil(try? fixture.git(["-C", fixture.clone, "rev-parse", "--verify", "refs/remotes/origin/goal/alpha"]))
        try fixture.git(["-C", fixture.bare, "branch", "-D", "goal/alpha"])
        try pushBeta()

        let base = makeBase()
        let snapshot = read(base, [.init(slug: "alpha", pull: 31), beta])
        XCTAssertEqual(snapshot.branches.map(\.slug), ["beta"], "the stale local ref is not read")
        XCTAssertNil(snapshot.reason, "the base fetched alone")
        let goals = merged(snapshot)
        XCTAssertEqual(goals.first?.summary.round, 1, "the base's alpha answers")
        XCTAssertEqual(goals.first?.source, "origin/main")
        XCTAssertNil(goals.first?.pull)
        XCTAssertEqual(fetches().count, 4, "one for all, then one per ref")
        let state = try XCTUnwrap(try base.file(root: fixture.clone, knowledge: knowledge, path: "alpha/STATE.md"))
        XCTAssertTrue(String(decoding: state.data, as: UTF8.self).contains("- Status: active"), "the file is the base's too")
    }

    func testWithTheRemoteGoneTheLocalBranchIsStillReadWithTheReason() throws {
        // Every fetch alone fails too: the whole fetch failed, so this is
        // no missing branch.
        try pushBeta()
        try fixture.makeClone()
        try fixture.git(["-C", fixture.clone, "remote", "set-url", "origin", fixture.directory.path + "/gone.git"])
        let snapshot = read(makeBase(), [beta])
        XCTAssertEqual(snapshot.branches.map(\.slug), ["beta"])
        XCTAssertEqual(snapshot.branches.first?.reason, "git fetch exited 128")
        XCTAssertEqual(snapshot.goals?.compactMap(\.slug), ["alpha"])
    }

    // MARK: - the time budget

    func testTheFetchesOfOneReadShareOneTimeBudget() throws {
        XCTAssertEqual(KnowledgeBase.fetchBudgetSeconds, 30)
        try pushBeta()
        try fixture.makeClone()
        // Each fetch takes 20 s of the clock. The one fetch fails on the
        // ghost branch; the base alone ends at 40 s; no further fetch starts.
        let clock = self.clock!
        let base = makeBase(before: { args in
            if args.contains("fetch") { clock.advance(20) }
            return nil
        })
        let snapshot = read(base, [.init(slug: "ghost", pull: 1), beta, .init(slug: "g2", pull: 2), .init(slug: "g3", pull: 3)])
        XCTAssertEqual(fetches().count, 2, "the whole fetch and the base alone")
        XCTAssertEqual(fetches().last, KnowledgeBase.fetchArguments(root: fixture.clone, base: "main"))
        XCTAssertNil(snapshot.reason, "the base fetched")
        XCTAssertEqual(snapshot.branches.map(\.slug), ["beta"], "the local ref, read with the reason")
        XCTAssertEqual(snapshot.branches.first?.reason, "git fetch not tried: the 30 s of the read are spent")
    }

    func testInsideTheBudgetEveryRefIsTriedAlone() throws {
        try pushBeta()
        try fixture.makeClone()
        let clock = self.clock!
        let base = makeBase(before: { args in
            if args.contains("fetch") { clock.advance(5) }
            return nil
        })
        let snapshot = read(base, [.init(slug: "ghost", pull: 1), beta])
        XCTAssertEqual(fetches().count, 4)
        XCTAssertEqual(snapshot.branches.map(\.slug), ["beta"])
        XCTAssertNil(snapshot.branches.first?.reason)
    }

    // MARK: - the branch name is data

    func testABranchNameLikeAnOptionNamesNoGoalBranch() {
        let heads = [
            "goal/--depth=1", "goal/a..b", "goal/", "goal/-x", "goal/x-", "goal/UPPER", "goal/a/b", "goal/a b",
            "--upload-pack=/tmp/x", "goal/--upload-pack=x", "goal/a.lock", "goal/@{-1}",
        ]
        XCTAssertEqual(KnowledgeBase.goalBranches(pulls: heads.enumerated().map { pull($0.offset + 1, $0.element) }), [])
    }

    func testARefusedBranchNameReachesNoFetch() throws {
        try fixture.makeClone()
        // The remote holds both names, so a fetch of either would succeed.
        try onBranch("goal/--depth=1") { try fixture.write("docs/goals/x/STATE.md", GitFixture.state("x")) }
        try pushBeta()
        let refused = ["--depth=1", "a..b", "-x", "--upload-pack=x", "a/b", ""].map {
            KnowledgeBase.GoalBranch(slug: $0, pull: 1)
        }
        let snapshot = read(makeBase(), refused + [beta])
        XCTAssertEqual(snapshot.branches.map(\.slug), ["beta"])
        XCTAssertEqual(fetches().count, 1)
        XCTAssertEqual(
            fetches().first, KnowledgeBase.fetchArguments(root: fixture.clone, branches: ["main", "goal/beta"]))
        for call in calls.calls {
            XCTAssertFalse(call.args.contains { $0.contains("depth") || $0.contains("upload-pack") }, "\(call.args)")
            XCTAssertFalse(call.args.contains { $0.contains("..") }, "\(call.args)")
        }
        XCTAssertEqual(try fixture.git(["-C", fixture.clone, "rev-parse", "--is-shallow-repository"]), "false")
        XCTAssertNil(try? fixture.git(["-C", fixture.clone, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/goal/--depth=1"]))
    }

    func testABranchNameGitWouldNotTakeIsRefusedWithNoFetch() throws {
        try fixture.makeClone()
        try pushBeta()
        // `git check-ref-format --branch` answers another name for beta.
        let base = makeBase(before: { args in
            guard args.contains("check-ref-format"), args.last == "goal/beta" else { return nil }
            return PullRequestStatus.RunResult(status: 0, output: Data("goal/other\n".utf8))
        })
        let snapshot = read(base, [beta])
        XCTAssertEqual(snapshot.branches, [])
        XCTAssertEqual(snapshot.goals?.compactMap(\.slug), ["alpha"], "the base is read as before")
        XCTAssertEqual(fetches(), [KnowledgeBase.fetchArguments(root: fixture.clone, base: "main")])
        XCTAssertTrue(calls.calls.contains { $0.args.suffix(3) == ["check-ref-format", "--branch", "goal/beta"] })
    }

    // MARK: - the fetch

    func testOneFetchNamesTheBaseAndEveryBranchAsAFullRefspec() throws {
        try fixture.makeClone()
        try pushBeta()
        try onBranch("goal/gamma") { try fixture.write("docs/goals/gamma/STATE.md", GitFixture.state("gamma")) }
        let snapshot = read(makeBase(), [beta, .init(slug: "gamma", pull: 15)])
        XCTAssertEqual(snapshot.branches.map(\.slug), ["beta", "gamma"])
        XCTAssertEqual(fetches().count, 1)
        let fetch = try XCTUnwrap(fetches().first)
        XCTAssertEqual(fetch, [
            "-C", fixture.clone, "-c", "gc.auto=0", "-c", "maintenance.auto=false",
            "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules",
            "--", "origin", refspec("main"), refspec("goal/beta"), refspec("goal/gamma"),
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.clone + "/.git/FETCH_HEAD"))
        XCTAssertEqual(KnowledgeBase.environment["GIT_TERMINAL_PROMPT"], "0")
    }

    func testABranchTheRemoteDoesNotHoldDoesNotStopTheBaseOrTheOthers() throws {
        try fixture.makeClone()
        try pushBeta()
        try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", round: 2))
        try fixture.push("alpha round 2")
        let snapshot = read(makeBase(), [.init(slug: "ghost", pull: 1), beta])
        XCTAssertEqual(snapshot.goals?.first?.round, 2, "the base is fetched alone after the whole fetch failed")
        XCTAssertNil(snapshot.reason)
        XCTAssertEqual(snapshot.branches.map(\.slug), ["beta"])
        XCTAssertNil(snapshot.branches.first?.reason)
        XCTAssertEqual(fetches().count, 4, "one for all, then one per ref")
        XCTAssertEqual(merged(snapshot).compactMap(\.summary.slug), ["alpha", "beta"])
    }

    func testAFailedFetchReadsTheLocalBranchAndSaysSo() throws {
        try fixture.makeClone()
        try pushBeta()
        let failing = FailSwitch()
        let base = makeBase(before: { args in
            guard args.contains("fetch"), failing.isOn else { return nil }
            return PullRequestStatus.RunResult(status: 128, error: "fatal: https://user:secret@example.test")
        })
        XCTAssertNil(read(base, [beta]).branches.first?.reason)
        failing.isOn = true
        clock.advance(KnowledgeBase.refreshSeconds + 1)
        let snapshot = read(base, [beta])
        XCTAssertEqual(snapshot.branches.first?.summary.round, 2)
        XCTAssertEqual(snapshot.branches.first?.reason, "git fetch exited 128")
        XCTAssertEqual(merged(snapshot).last?.json["sourceReason"] as? String, "git fetch exited 128")
        XCTAssertTrue(snapshot.reason?.hasPrefix("git fetch exited 128; last good fetch ") == true)
    }

    func testAFetchThatTimesOutIsNotTriedAgainPerRef() throws {
        try fixture.makeClone()
        try pushBeta()
        let base = makeBase(before: { args in
            args.contains("fetch") ? PullRequestStatus.RunResult(status: 143, timedOut: true) : nil
        })
        let snapshot = read(base, [beta])
        XCTAssertEqual(fetches().count, 1)
        XCTAssertEqual(snapshot.branches, [], "the clone never had the branch")
        XCTAssertEqual(snapshot.goals?.compactMap(\.slug), ["alpha"])
    }

    // MARK: - one goal folder, jailed

    func testABranchNeverServesWhatIsOutsideItsGoalFolder() throws {
        try fixture.makeClone()
        try onBranch("goal/beta") {
            try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta", round: 2))
            try fixture.write("docs/goals/beta/big.md", String(repeating: "x", count: KnowledgeFile.maxBytes + 1))
            try fixture.write("secret.md", "outside\n")
            try fixture.write("docs/goals/alpha/STATE.md", GitFixture.state("alpha", status: "done", round: 9))
            try fixture.write("docs/goals/alpha/branch-only.md", "from the branch\n")
            try fixture.write("docs/goals/other/STATE.md", GitFixture.state("other"))
            try fixture.write("docs/goals/facts.md", "branch facts\n")
            try FileManager.default.createSymbolicLink(
                atPath: fixture.seed + "/docs/goals/beta/link.md", withDestinationPath: "../../../secret.md")
        }
        let base = makeBase()
        let snapshot = read(base, [beta])
        let goal = try XCTUnwrap(snapshot.branches.first)
        XCTAssertFalse(goal.tree.entries.isEmpty)
        for path in goal.tree.entries.keys {
            XCTAssertTrue(path == "beta" || path.hasPrefix("beta/"), path)
        }
        XCTAssertEqual(merged(snapshot).compactMap(\.summary.slug), ["alpha", "beta"], "no `other` from the branch")
        XCTAssertEqual(merged(snapshot).first?.summary.round, 1, "alpha is the base's, not the branch's")
        // Every listing of the branch names its one folder.
        let commit = goal.commit
        let listings = calls.calls.map(\.args).filter { $0.contains("ls-tree") && $0.contains(commit) }
        XCTAssertEqual(listings.map(\.last), ["docs/goals/beta"])

        func file(_ path: String) throws -> String? {
            try base.file(root: fixture.clone, knowledge: knowledge, path: path)
                .map { String(decoding: $0.data, as: UTF8.self) }
        }
        func failure(_ path: String) -> KnowledgeFile.Failure? {
            do {
                _ = try file(path)
                return nil
            } catch { return error as? KnowledgeFile.Failure }
        }
        XCTAssertTrue(try XCTUnwrap(try file("beta/STATE.md")).contains("- Round: 2 of 3"))
        XCTAssertEqual(failure("beta/link.md"), .refused)
        XCTAssertEqual(failure("beta/big.md"), .tooLarge)
        XCTAssertEqual(failure("beta/none.md"), .notFound)
        XCTAssertEqual(failure("beta"), .notFound)
        XCTAssertEqual(failure("beta/../../secret.md"), .badPath)
        XCTAssertEqual(failure("beta/../alpha/branch-only.md"), .badPath)
        XCTAssertTrue(try XCTUnwrap(try file("alpha/STATE.md")).contains("- Status: active"), "the base's alpha")
        XCTAssertEqual(failure("alpha/branch-only.md"), .notFound)
        XCTAssertEqual(failure("facts.md"), .notFound, "the base has no facts.md")
        XCTAssertEqual(failure("other/STATE.md"), .notFound, "no base, no working tree and no branch serves it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.clone + "/docs/goals/other"))
        for call in calls.calls where call.args.contains("cat-file") {
            XCTAssertFalse(call.args.contains { $0.contains("secret") })
        }
    }

    func testAGoalFolderThatIsASymlinkOnTheBranchIsNotRead() throws {
        try fixture.makeClone()
        try onBranch("goal/beta") {
            try FileManager.default.createSymbolicLink(
                atPath: fixture.seed + "/docs/goals/beta", withDestinationPath: "alpha")
        }
        try onBranch("goal/gamma") {
            try fixture.write("docs/goals/gamma/goal.md", "# Goal: no state\n")
        }
        let snapshot = read(makeBase(), [beta, .init(slug: "gamma", pull: 2)])
        XCTAssertEqual(snapshot.branches, [], "a symlink, and a folder with no STATE.md")
        XCTAssertEqual(merged(snapshot).compactMap(\.summary.slug), ["alpha"])
    }

    func testAFileOfABranchGoalComesFromTheBranchCommit() throws {
        try fixture.makeClone()
        try pushBeta()
        try fixture.write("docs/goals/beta/rounds/002.md", "the working tree's draft\n", in: fixture.clone)
        try fixture.write("docs/goals/beta/STATE.md", GitFixture.state("beta"), in: fixture.clone)
        let base = makeBase()
        _ = read(base, [beta])
        let record = try XCTUnwrap(try base.file(root: fixture.clone, knowledge: knowledge, path: "beta/rounds/002.md"))
        XCTAssertEqual(String(decoding: record.data, as: UTF8.self), GitFixture.record(2))
        XCTAssertEqual(record.contentType, KnowledgeFile.contentType)
        // The pull request closes: the base has no beta, so the working tree answers.
        clock.advance(KnowledgeBase.refreshSeconds + 1)
        _ = read(base, [])
        XCTAssertNil(try base.file(root: fixture.clone, knowledge: knowledge, path: "beta/rounds/002.md"))
    }

    // MARK: - the bound

    func testAtMostEightBranchesPerProject() throws {
        XCTAssertEqual(KnowledgeBase.maxGoalBranches, 8)
        let pulls = (0..<12).map { pull(100 - $0, "goal/g\($0)") }
        let branches = KnowledgeBase.goalBranches(pulls: pulls)
        XCTAssertEqual(branches.map(\.slug), (0..<8).map { "g\($0)" }, "the first eight in gh's order")

        // A caller that hands over more still fetches eight.
        try fixture.makeClone()
        let many = (0..<12).map { KnowledgeBase.GoalBranch(slug: "g\($0)", pull: $0) }
        _ = read(makeBase(before: { args in
            args.contains("fetch") ? PullRequestStatus.RunResult(status: 143, timedOut: true) : nil
        }), many)
        XCTAssertEqual(fetches().count, 1)
        let refspecs = fetches()[0].filter { $0.hasPrefix("+refs/heads/") }
        XCTAssertEqual(refspecs, [refspec("main")] + (0..<8).map { refspec("goal/g\($0)") })
    }

    func testOneReadAMinuteWithBranchesToo() throws {
        try fixture.makeClone()
        try pushBeta()
        let base = makeBase()
        XCTAssertEqual(read(base, []).branches, [])
        XCTAssertFalse(base.refreshIfDue(root: fixture.clone, knowledge: knowledge, branches: [beta]),
                       "a new branch list does not start a second read inside the minute")
        XCTAssertEqual(fetches().count, 1)
        clock.advance(KnowledgeBase.refreshSeconds)
        XCTAssertTrue(base.refreshIfDue(root: fixture.clone, knowledge: knowledge, branches: [beta]))
        KnowledgeBase.queue.sync {}
        XCTAssertEqual(fetches().count, 2)
        XCTAssertEqual(base.snapshot(root: fixture.clone, knowledge: knowledge).branches.map(\.slug), ["beta"])
    }

    // MARK: - where it runs

    func testEveryGitOfABranchReadRunsOnTheBaseQueue() throws {
        try fixture.makeClone()
        try pushBeta()
        let base = makeBase()
        let snapshot = read(base, [beta, .init(slug: "ghost", pull: 2)])
        XCTAssertEqual(snapshot.branches.count, 1)
        XCTAssertGreaterThan(calls.calls.count, 8)
        XCTAssertTrue(calls.calls.allSatisfy(\.onQueue))
        // The snapshot and the schedule are lock takes: no `git` on the caller.
        let before = calls.calls.count
        _ = base.snapshot(root: fixture.clone, knowledge: knowledge)
        XCTAssertFalse(base.refreshIfDue(root: fixture.clone, knowledge: knowledge, branches: [beta]))
        XCTAssertEqual(calls.calls.count, before)
    }
}

/// A switch a `git` closure reads from the base queue.
final class FailSwitch: @unchecked Sendable {
    private let lock = NIOLock()
    private var on = false
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}
