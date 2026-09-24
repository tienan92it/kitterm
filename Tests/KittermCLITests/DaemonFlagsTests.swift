import XCTest

@testable import KittermCLI

/// `--lan` without `--trusted-host` is refused with one sentence, before
/// anything binds (`docs/goals/proxy-is-a-boundary`). The sentence is the
/// interface: `AGENTS.md`, `docs/architecture.md` and the proxy tests quote it.
final class DaemonFlagsTests: XCTestCase {
    private let sentence =
        "--lan must be given with --trusted-host <your public name>: "
        + "without it a proxy on loopback inherits full access with no token"

    func testLanAloneIsRefusedWithTheSentence() {
        XCTAssertThrowsError(try DaemonFlags.parse(["--lan"]).validatedTrustedHosts()) { error in
            XCTAssertEqual(error.localizedDescription, sentence)
        }
        // The daemon's configuration is built through the same check, so
        // `serve` refuses with the same words as `start`.
        XCTAssertThrowsError(try DaemonFlags.parse(["--lan"]).daemonConfig(port: 3418)) { error in
            XCTAssertEqual(error.localizedDescription, sentence)
        }
        // A running daemon's argv, as `upgrade` reads it.
        XCTAssertThrowsError(
            try DaemonFlags.parse(["kitterm", "serve", "--port", "3418", "--lan"]).validatedTrustedHosts()
        )
    }

    func testLanWithATrustedHostAndTheDefaultAreAccepted() throws {
        XCTAssertEqual(
            try DaemonFlags.parse(["--lan", "--trusted-host", "mac.tailnet.ts.net"]).validatedTrustedHosts(),
            ["mac.tailnet.ts.net"]
        )
        XCTAssertEqual(try DaemonFlags.parse(["--lan", "--trusted-host=a", "--trusted-host", "b"]).validatedTrustedHosts(), ["a", "b"])
        XCTAssertEqual(try DaemonFlags.parse([]).validatedTrustedHosts(), [])
        XCTAssertEqual(try DaemonFlags.parse(["--trusted-host", "a"]).validatedTrustedHosts(), ["a"])
        XCTAssertFalse(try DaemonFlags.parse([]).daemonConfig(port: 3418).allowLAN)
    }
}

/// `kitterm upgrade` reads the running daemon's argv through `ps` and parses
/// it as flags; the test process is the one live pid at hand.
final class ProcessArgumentsTests: XCTestCase {
    func testTheLiveProcessArgvIsReadAsWords() throws {
        let words = try XCTUnwrap(KittermMain.processArguments(pid: getpid()))
        XCTAssertFalse(words.isEmpty)
        XCTAssertFalse(words[0].contains(" "))
        XCTAssertEqual(DaemonFlags.parse(words).lan, false)
        XCTAssertNil(KittermMain.processArguments(pid: 2_147_483_000), "no such process")
    }
}
