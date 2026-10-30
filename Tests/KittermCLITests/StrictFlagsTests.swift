import XCTest

@testable import KittermCLI

/// `DaemonFlags.validate` is what `start`, `restart`, and `service install`
/// call before any side effect, so a typo or a stray `--help` (already
/// caught earlier by `HelpRequest`, but any other unknown flag too) fails
/// loudly instead of being dropped by `DaemonFlags.parse` and relaunching
/// the daemon with the wrong configuration (the 2026-10-30 incident,
/// `docs/goals/facts.md`). This never fails on c2d6adc through a process,
/// only through this pure function, because it did not exist there.
final class StrictFlagsTests: XCTestCase {
    func testEveryFlagTheCurrentPlistUsesIsAccepted() throws {
        // The plist's own ProgramArguments, `serve` included: a bare
        // positional is tolerated, only unrecognized options are refused.
        XCTAssertNoThrow(
            try DaemonFlags.validate([
                "serve", "--port", "3418", "--agent-control", "--retain-logs",
                "--trusted-host", "genos-pro.tail66794d.ts.net",
            ])
        )
        XCTAssertNoThrow(
            try DaemonFlags.validate([
                "--lan", "--record", "--rotate-token",
                "--tls-cert", "/tmp/cert.pem", "--tls-key", "/tmp/key.pem", "--tls-port", "3419",
                "--session-linger", "300",
            ])
        )
        XCTAssertNoThrow(try DaemonFlags.validate(["--trusted-host=a.example", "--port=3418"]))
        XCTAssertNoThrow(try DaemonFlags.validate([]))
    }

    func testAnUnknownOptionIsRejectedWithTheUsageLine() {
        for typo in ["--agentcontrol", "--lna", "--retainlogs", "-x"] {
            XCTAssertThrowsError(try DaemonFlags.validate([typo])) { error in
                guard case CLIError.unknownOption(let detail) = error else {
                    return XCTFail("expected .unknownOption, got \(error)")
                }
                XCTAssertTrue(detail.hasPrefix("kitterm: unknown option \(typo)\n"))
                XCTAssertTrue(detail.contains("usage:"))
            }
        }
    }

    func testAnUnknownOptionAfterKnownOnesIsStillCaught() {
        XCTAssertThrowsError(try DaemonFlags.validate(["--lan", "--trusted-host", "a.example", "--agentcontrol"]))
    }
}

/// `kitterm upgrade` must not fall through to the installer
/// (`curl … | sh`) on a flag it does not recognize.
final class UpgradeFlagsTests: XCTestCase {
    func testOnlyRestartAndLiveAreAccepted() {
        XCTAssertNoThrow(try UpgradeFlags.validate([]))
        XCTAssertNoThrow(try UpgradeFlags.validate(["--restart"]))
        XCTAssertNoThrow(try UpgradeFlags.validate(["--live"]))
    }

    func testAnyOtherFlagIsRejected() {
        for bad in ["--help", "-h", "--force", "--restar"] {
            XCTAssertThrowsError(try UpgradeFlags.validate([bad])) { error in
                guard case CLIError.unknownOption(let detail) = error else {
                    return XCTFail("expected .unknownOption, got \(error)")
                }
                XCTAssertTrue(detail.hasPrefix("kitterm: unknown option \(bad)\n"))
            }
        }
    }
}
