import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// The pure merge that turns marks + a hook report + a pending approval into
/// the crew vocabulary. The load-bearing rule: after the two hard facts
/// (exited, needs-approval), the *newer* evidence source wins.
final class AgentStatusTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Marks with controlled timestamps: an optional finished command at t0,
    /// then optionally a running command (preExec only) at `runningAt`.
    private func marks(running: Bool, runningAt: Date? = nil, lastExit: Int32?) -> [SessionMark] {
        var marks: [SessionMark] = []
        if let lastExit {
            marks.append(SessionMark(offset: 0, kind: .preExec, exit: nil, command: "old", at: t0))
            marks.append(SessionMark(offset: 1, kind: .commandEnd, exit: lastExit, command: nil, at: t0))
        }
        if running {
            marks.append(SessionMark(offset: 2, kind: .preExec, exit: nil, command: "now", at: runningAt ?? t0))
        }
        return marks
    }

    private func merge(
        running: Bool = false,
        runningAt: Date? = nil,
        lastExit: Int32? = nil,
        report: AgentReport? = nil,
        reportAt: Date? = nil,
        pendingApproval: Bool = false,
        exited: Bool = false
    ) -> MergedSessionState {
        let derived = DerivedSessionState.derive(
            from: marks(running: running, runningAt: runningAt, lastExit: lastExit)
        )
        let agent = report.map { AgentStatus(report: $0, message: nil, at: reportAt ?? t0.addingTimeInterval(60)) }
        return MergedSessionState.merge(
            derived: derived, agent: agent, pendingApproval: pendingApproval, exited: exited
        )
    }

    // MARK: - hard facts first

    func testExitedWinsOverEverything() {
        XCTAssertEqual(
            merge(running: true, report: .needsInput, pendingApproval: true, exited: true),
            .exited
        )
    }

    func testPendingApprovalOutranksAnInputNotification() {
        XCTAssertEqual(merge(report: .needsInput, pendingApproval: true), .needsApproval)
    }

    // MARK: - the primary case: a shell running `claude`

    /// `claude` emits one preExec at start and no commandEnd for hours, so the
    /// marks say "running" the whole session. Every hook report is newer, so
    /// the agent's own turns must show through.
    func testHookReportsShowThroughALongRunningCommand() {
        let started = t0
        let later = t0.addingTimeInterval(300)
        XCTAssertEqual(merge(running: true, runningAt: started, report: .completed, reportAt: later), .completed)
        XCTAssertEqual(merge(running: true, runningAt: started, report: .needsInput, reportAt: later), .needsInput)
        XCTAssertEqual(merge(running: true, runningAt: started, report: .working, reportAt: later), .working)
    }

    /// The human answered and the agent ran its next tool: `PreToolUse`
    /// records `working`, which is what clears the stale `needs-input`.
    func testWorkingReportClearsNeedsInput() {
        // Only the latest report is stored, so this is simply "latest wins".
        XCTAssertEqual(merge(running: true, report: .working), .working)
    }

    // MARK: - newer marks outrank an older report

    /// A command finished *after* the agent said `completed` — a human typed in
    /// the pane, or the wrapper exited non-zero. The newer exit code wins.
    func testNewerFailedExitOutranksOlderCompleted() {
        let reported = t0.addingTimeInterval(-60)  // report older than the marks at t0
        XCTAssertEqual(merge(lastExit: 2, report: .completed, reportAt: reported), .failed)
    }

    func testNewerCommandStartOutranksOlderCompleted() {
        let reported = t0.addingTimeInterval(-60)
        XCTAssertEqual(merge(running: true, runningAt: t0, report: .completed, reportAt: reported), .working)
    }

    // MARK: - no hooks: marks alone, exactly as before

    func testNoReportCollapsesToMarkOnlyState() {
        XCTAssertEqual(merge(running: true), .working)
        XCTAssertEqual(merge(lastExit: 0), .idle)
        XCTAssertEqual(merge(lastExit: 2), .failed)
        XCTAssertEqual(merge(), .unknown, "no marks, no report → unknown")
    }

    /// A report with no marks at all (a fresh shell) is trusted outright.
    func testReportWithNoMarksIsTrusted() {
        XCTAssertEqual(merge(report: .completed), .completed)
    }
}
