import Foundation
import XCTest

/// The wait every test puts on a subprocess. `Process.waitUntilExit()`
/// occasionally never returns, and a test that hangs holds the whole suite
/// until CI cancels it; a cancelled run cannot be rerun. `waitForExit(of:)`
/// polls `isRunning` under a deadline instead, and when the deadline passes
/// it fails the calling test at the call site, names the test and the pid,
/// and carries what the process last printed.
///
/// This file is shared: `Tests/KittermCLITests/ProcessWaitTestSupport.swift`
/// is a symlink to it, because the two test targets share no module and
/// `Package.swift` is out of a round's reach.
enum ProcessWait {
    /// The default deadline. Measured 2026-09-16 over three runs of the
    /// seven process-spawning test files (47 tests, 41 to 43 s a run): no
    /// exit wait took longer than 12.7 ms, one poll grain, and a `serve`
    /// with two shells reaped on `SIGTERM` was no slower than a `git add`.
    /// The daemon's own stop path is bounded by `serverStopGraceMs / 10`.
    /// 30 s is over two thousand times that, so a swapping machine or a
    /// loaded CI runner stays green, and a real stall costs half a minute
    /// instead of the job's timeout. The slow machine is the weight here:
    /// a false red costs a whole rerun, a loose deadline costs 30 s once.
    static let deadline: TimeInterval = 30

    /// How many bytes of the process's output the failure carries.
    static let outputTailBytes = 2048

    /// The tail of `<KITTERM_STATE_DIR>/server.log` for a process that ran
    /// with that variable, which is where `kitterm serve` sends its own
    /// stdout and stderr. Nil when the process has no state directory or
    /// the log does not exist.
    static func lastOutput(of process: Process) -> String? {
        guard let stateDir = process.environment?["KITTERM_STATE_DIR"] else { return nil }
        let log = URL(fileURLWithPath: stateDir).appendingPathComponent("server.log")
        guard let data = try? Data(contentsOf: log) else { return nil }
        return String(decoding: data.suffix(outputTailBytes), as: UTF8.self)
    }

    /// The command line, for the failure message.
    static func describe(_ process: Process) -> String {
        ([process.executableURL?.lastPathComponent ?? "?"] + (process.arguments ?? [])).joined(separator: " ")
    }
}

extension XCTestCase {
    /// Waits until `process` has exited, or until `timeout` seconds pass.
    /// On the deadline it fails this test at the caller's line with the
    /// test's name, the command, the pid and the process's last output,
    /// then sends `SIGKILL` so the stalled process does not outlive the
    /// test. Returns true when the process exited in time; the caller may
    /// then read `terminationStatus`.
    ///
    /// `output` overrides the text the failure carries; without it the
    /// helper reads `ProcessWait.lastOutput(of:)`.
    @discardableResult
    func waitForExit(
        of process: Process,
        within timeout: TimeInterval = ProcessWait.deadline,
        output: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                let pid = process.processIdentifier
                let last = output ?? ProcessWait.lastOutput(of: process) ?? "(no output recorded)"
                XCTFail(
                    "\(name): `\(ProcessWait.describe(process))` (pid \(pid)) did not exit within \(timeout) s; "
                        + "last output:\n\(last)",
                    file: file, line: line
                )
                kill(pid, SIGKILL)
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
