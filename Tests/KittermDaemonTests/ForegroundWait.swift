import Foundation
import XCTest

@testable import KittermDaemon

/// Waiting on a session's foreground, without the proxy.
///
/// `PtySession.foregroundIsShell` is true in three cases, not one: the shell
/// reads the terminal, nothing has claimed the tty yet, or the spawn helper
/// holds it in the moment before it execs the shell. So `foregroundIsShell`
/// is already true when the shell does not exist, and `!foregroundIsShell`
/// names any program, not the one the test typed. Neither is a gate for a
/// test that then depends on a stronger property.
///
/// Wait for what the next lines actually need: the program by name, with
/// `waitForForeground`; the terminal in raw mode, with `inputIsCanonical ==
/// false`; the spawned shell itself, with its own pid under a name that is
/// not `SpawnHelperPath.name` (see `InputEnterKeyTests.spawn`). Measured on
/// 2026-09-10 with a spawn-helper shim that slept 3 s: `foregroundIsShell`
/// held for those 3 s, before the shell existed.
extension XCTestCase {
    /// Until `program` holds the terminal, by the name it was started under.
    func waitForForeground(
        _ program: String, in session: PtySession, seconds: Double = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = SuspendingClock.now + .seconds(seconds)
        while SuspendingClock.now < deadline {
            if session.foregroundProgram == program { return }
            try await Task.sleep(for: .milliseconds(50), clock: .suspending)
        }
        XCTFail(
            "timed out waiting for \(program) to take the terminal; "
                + "foregroundProgram is \(session.foregroundProgram ?? "nil")",
            file: file, line: line
        )
    }
}
