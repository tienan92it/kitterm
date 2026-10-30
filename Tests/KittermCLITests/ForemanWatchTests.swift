import Foundation
import KittermDaemon
import XCTest

@testable import KittermCLI

/// `kitterm foreman watch` — round 1 of `foreman-event-driven`
/// (`docs/goals/foreman-event-driven/corpus/00-request.md`). A scripted
/// feed stands in for the daemon: each test hands `watch` a fixed sequence
/// of `GET /api/events` answers and a fake clock, with no daemon and no
/// network call, so the long-poll loop is exercised in-process.
final class ForemanWatchTests: XCTestCase {
    /// One answer `watch`'s injected `poll` closure hands back, in the
    /// order the test scripts them.
    private final class ScriptedFeed {
        struct Page {
            var epoch: String
            var events: [[String: Any]]
            var next: Int
            var pruned: Bool = false
        }

        private var pages: [Page]
        private(set) var calls: [(since: Int, epoch: String?, timeout: Int)] = []
        private var clock: Date

        init(start: Date = Date(timeIntervalSince1970: 0), pages: [Page]) {
            self.pages = pages
            self.clock = start
        }

        /// `watch`'s `poll` parameter: records the call, advances the fake
        /// clock by the poll's own timeout (as if that long poll had taken
        /// exactly that long), and hands back the next scripted page.
        func poll(since: Int, epoch: String?, timeout: Int) -> ForemanCommand.WatchPoll {
            calls.append((since, epoch, timeout))
            clock = clock.addingTimeInterval(TimeInterval(timeout))
            guard !pages.isEmpty else { return .unavailable("scripted feed ran out of pages") }
            let page = pages.removeFirst()
            return .answer(epoch: page.epoch, events: page.events, next: page.next, pruned: page.pruned)
        }

        /// `watch`'s `now` parameter: the fake clock `poll` advances.
        func now() -> Date { clock }
    }

    private let sessionA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let sessionB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    private func event(seq: Int, type: String, session: String?, data: [String: String] = [:]) -> [String: Any] {
        var fields: [String: Any] = ["seq": seq, "type": type, "at": 0]
        if let session { fields["session"] = session }
        if !data.isEmpty { fields["data"] = data }
        return fields
    }

    private func run(_ args: [String], feed: ScriptedFeed) throws -> [String] {
        var lines: [String] = []
        try ForemanCommand.watch(args, poll: feed.poll, now: feed.now) { lines.append($0) }
        return lines
    }

    // MARK: - A match exits with the triggering event

    func testANoteForAWatchedSessionExitsAndPrintsIt() throws {
        let feed = ScriptedFeed(pages: [
            .init(
                epoch: "epoch-1",
                events: [
                    event(seq: 10, type: "note", session: sessionB, data: ["message": "not watched"]),
                    event(seq: 11, type: "note", session: sessionA, data: ["message": "plan ready"]),
                ],
                next: 12
            ),
        ])
        let lines = try run(["--session", sessionA, "--since", "10", "--epoch", "epoch-1", "--json"], feed: feed)
        XCTAssertEqual(feed.calls.count, 1)
        XCTAssertEqual(lines.count, 1)
        let parsed = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(lines[0].utf8))) as? [String: Any]
        )
        XCTAssertEqual(parsed["type"] as? String, "event")
        XCTAssertEqual(parsed["epoch"] as? String, "epoch-1")
        // The matched event's own seq + 1, not the batch's `next` (12): a
        // later event in the same page must not be skipped by the cursor.
        XCTAssertEqual(parsed["next"] as? Int, 12)
        let matched = try XCTUnwrap(parsed["event"] as? [String: Any])
        XCTAssertEqual(matched["seq"] as? Int, 11)
        XCTAssertEqual(matched["type"] as? String, "note")
        XCTAssertEqual(matched["session"] as? String, sessionA)
    }

    func testAnAgentStatusOfAnyKindMatches() throws {
        let feed = ScriptedFeed(pages: [
            .init(epoch: "e", events: [event(seq: 1, type: "agent.status", session: sessionA, data: ["status": "needs-input"])], next: 2),
        ])
        let lines = try run(["--session", sessionA, "--since", "0", "--epoch", "e"], feed: feed)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("agent.status"))
    }

    func testACommandFailedForAWatchedSessionMatches() throws {
        let feed = ScriptedFeed(pages: [
            .init(epoch: "e", events: [event(seq: 1, type: "command.failed", session: sessionA, data: ["exit": "1"])], next: 2),
        ])
        let lines = try run(["--session", sessionA, "--since", "0", "--epoch", "e"], feed: feed)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("command.failed"))
    }

    // MARK: - A non-matching event advances the cursor silently

    func testAnEventForAnUnwatchedSessionIsSkippedAndTheCursorAdvances() throws {
        let feed = ScriptedFeed(pages: [
            .init(epoch: "e", events: [event(seq: 1, type: "note", session: sessionB, data: ["message": "not mine"])], next: 2),
            .init(epoch: "e", events: [event(seq: 2, type: "note", session: sessionA, data: ["message": "mine"])], next: 3),
        ])
        let lines = try run(["--session", sessionA, "--since", "0", "--epoch", "e"], feed: feed)
        XCTAssertEqual(feed.calls.count, 2)
        // The second poll started at 2, the first page's own `next` — the
        // skipped event at seq 1 did not strand the cursor.
        XCTAssertEqual(feed.calls[1].since, 2)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("seq=2"))
    }

    // MARK: - A heartbeat with no match

    func testAHeartbeatWithNoMatchPrintsTheHeartbeatMarker() throws {
        let feed = ScriptedFeed(pages: [
            .init(epoch: "e", events: [event(seq: 1, type: "note", session: sessionB)], next: 5),
        ])
        let lines = try run(
            ["--session", sessionA, "--since", "0", "--epoch", "e", "--heartbeat", "10"],
            feed: feed
        )
        XCTAssertEqual(feed.calls.count, 1)
        // The one poll was clamped to the heartbeat, not the default ceiling.
        XCTAssertEqual(feed.calls[0].timeout, 10)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("heartbeat"))
        XCTAssertTrue(lines[0].contains("next=5"))
        XCTAssertTrue(lines[0].contains("epoch=e"))
    }

    // MARK: - An epoch change, or a pruned cursor, re-reads

    func testAnEpochChangePrintsTheEpochChangeMarker() throws {
        let feed = ScriptedFeed(pages: [
            .init(epoch: "epoch-2", events: [], next: 20),
        ])
        let lines = try run(["--session", sessionA, "--since", "10", "--epoch", "epoch-1"], feed: feed)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("epoch-change"))
        XCTAssertTrue(lines[0].contains("epoch=epoch-2"))
        XCTAssertTrue(lines[0].contains("next=20"))
    }

    func testAPrunedCursorPrintsTheEpochChangeMarkerEvenWithTheSameEpoch() throws {
        let feed = ScriptedFeed(pages: [
            .init(epoch: "epoch-1", events: [], next: 1, pruned: true),
        ])
        let lines = try run(["--session", sessionA, "--since", "999", "--epoch", "epoch-1"], feed: feed)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("epoch-change"))
    }

    // MARK: - The cursor round-trips

    func testTheCursorRoundTripsInAndOut() throws {
        let feed = ScriptedFeed(pages: [
            .init(epoch: "abc", events: [event(seq: 42, type: "note", session: sessionB)], next: 50),
            .init(epoch: "abc", events: [event(seq: 50, type: "note", session: sessionA)], next: 60),
        ])
        let lines = try run(["--session", sessionA, "--since", "42", "--epoch", "abc"], feed: feed)
        XCTAssertEqual(feed.calls[0].since, 42)
        XCTAssertEqual(feed.calls[0].epoch, "abc")
        XCTAssertEqual(feed.calls[1].since, 50)
        XCTAssertEqual(feed.calls[1].epoch, "abc")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("next=51"))
        XCTAssertTrue(lines[0].contains("epoch=abc"))
    }

    /// With no `--since`, `watch` bootstraps at the current head with one
    /// no-wait poll, so a note posted before the command started is never
    /// replayed as if it just arrived.
    func testWithNoSinceItBootstrapsAtTheCurrentHeadAndIgnoresOlderEvents() throws {
        let feed = ScriptedFeed(pages: [
            .init(epoch: "e", events: [event(seq: 1, type: "note", session: sessionA, data: ["message": "old"])], next: 7),
            .init(epoch: "e", events: [event(seq: 7, type: "note", session: sessionA, data: ["message": "new"])], next: 8),
        ])
        let lines = try run(["--session", sessionA], feed: feed)
        XCTAssertEqual(feed.calls.count, 2)
        XCTAssertEqual(feed.calls[0].since, 0)
        XCTAssertNil(feed.calls[0].epoch)
        XCTAssertEqual(feed.calls[0].timeout, 0)
        // The bootstrap landed on 7; the real poll starts there, not at 0.
        XCTAssertEqual(feed.calls[1].since, 7)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("message=new"))
        XCTAssertFalse(lines[0].contains("message=old"))
    }

    // MARK: - Usage

    func testNoSessionIsAUsageError() {
        XCTAssertThrowsError(try ForemanCommand.watch([], poll: { _, _, _ in .unavailable("never called") }, out: { _ in })) { error in
            guard case CLIError.usage = error else {
                return XCTFail("expected a usage error, got \(error)")
            }
        }
    }

    func testAnUnknownFlagIsAUsageError() {
        XCTAssertThrowsError(
            try ForemanCommand.watch(
                ["--session", sessionA, "--bogus"],
                poll: { _, _, _ in .unavailable("never called") },
                out: { _ in }
            )
        )
    }

    // MARK: - No daemon answer is a non-zero failure, not a quiet report

    func testNoDaemonAnswerThrowsRatherThanReturning() {
        XCTAssertThrowsError(
            try ForemanCommand.watch(
                ["--session", sessionA],
                poll: { _, _, _ in .unavailable("no port file") },
                out: { _ in }
            )
        ) { error in
            guard case CLIError.serviceFailed = error else {
                return XCTFail("expected serviceFailed, got \(error)")
            }
        }
    }

    // MARK: - Regression: the subcommand exists and dispatches

    /// On `e389733` (the base before this round) `"watch"` was not a known
    /// subcommand, so `ForemanCommand.run` fell to the default case and
    /// threw `CLIError.usage` naming the two-command-less usage text before
    /// ever parsing `--session`. After this round the same call reaches
    /// `watch`'s own argument parser and usage check instead — reachable
    /// only once `run` knows the subcommand.
    // MARK: - `--help` is caught before the subcommand ever runs

    /// `watch`'s own flags must be in `HelpRequest.valuedFlagNames`, so
    /// `--session --help` names a (nonsensical) session id rather than
    /// being read as a help request — the same rule that already covers
    /// `--name`, `--scope`, and the other valued flags (`HelpRequest.swift`,
    /// `docs/goals/facts.md`, the 2026-10-30 `--help` incident).
    func testWatchsFlagsAreValuedSoAHelpTokenAfterOneIsItsValue() {
        XCTAssertNil(HelpRequest.decide(["foreman", "watch", "--session", "--help"]))
        XCTAssertNil(HelpRequest.decide(["foreman", "watch", "--since", "-h"]))
        XCTAssertNil(HelpRequest.decide(["foreman", "watch", "--epoch", "-h"]))
        XCTAssertNil(HelpRequest.decide(["foreman", "watch", "--heartbeat", "-h"]))
        XCTAssertNil(HelpRequest.decide(["foreman", "watch", "--timeout", "-h"]))
        // Once every valued flag has its own value, --help still counts.
        XCTAssertEqual(
            HelpRequest.decide(["foreman", "watch", "--session", "x", "--help"]),
            .command("foreman")
        )
    }

    func testTheWatchSubcommandDispatchesRatherThanFallingToUnknownCommand() {
        // No `--session`: `watch`'s own usage check must fire. Before this
        // round there was no such check to fire — "watch" was unknown and
        // `run` threw the bare top-level usage error instead.
        var threw: Error?
        XCTAssertThrowsError(try ForemanCommand.run(["watch"]) { _ in }) { threw = $0 }
        guard case .some(CLIError.usage(let message)) = threw else {
            return XCTFail("expected a usage error, got \(String(describing: threw))")
        }
        XCTAssertTrue(message.contains("--session"), "the subcommand's own usage check must have run: \(message)")
    }
}
