import Foundation
import XCTest

@testable import KittermDaemon

/// `KITTERM_STATE_DIR` exists so a second daemon can run without stepping on the
/// first. Overriding `HOME` does not achieve that — the home directory comes
/// from the passwd entry — so a throwaway daemon would rewrite the pid and port
/// of the one you are working in, and `kitterm stop` would then target the
/// wrong process.
final class DaemonPathsTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = ProcessInfo.processInfo.environment["KITTERM_STATE_DIR"]
    }

    override func tearDown() {
        if let saved {
            setenv("KITTERM_STATE_DIR", saved, 1)
        } else {
            unsetenv("KITTERM_STATE_DIR")
        }
        super.tearDown()
    }

    func testDefaultsToTheHomeDirectory() {
        unsetenv("KITTERM_STATE_DIR")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(DaemonPaths.stateDirectory.path, home + "/.kitterm")
    }

    /// The whole set moves together: a daemon that wrote its pid to the override
    /// but its port to the home directory would be worse than no override.
    func testOverrideMovesEveryStateFile() {
        let dir = NSTemporaryDirectory() + "kitterm-state-test"
        setenv("KITTERM_STATE_DIR", dir, 1)

        XCTAssertEqual(DaemonPaths.stateDirectory.path, dir)
        for file in [
            DaemonPaths.pidFile,
            DaemonPaths.portFile,
            DaemonPaths.logFile,
            DaemonPaths.tokenFile,
            DaemonPaths.webRootFile,
        ] {
            XCTAssertEqual(
                file.deletingLastPathComponent().path, dir,
                "\(file.lastPathComponent) escaped the override"
            )
        }
    }

    /// An empty value is a caller who meant to unset it, not a request to write
    /// state into the current directory.
    func testEmptyOverrideIsIgnored() {
        setenv("KITTERM_STATE_DIR", "", 1)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(DaemonPaths.stateDirectory.path, home + "/.kitterm")
    }
}
