import XCTest

@testable import KittermCLI

/// `HelpRequest.decide` is what stops `kitterm service install --help` from
/// reaching `DaemonFlags.parse`, which keeps the flags it knows and quietly
/// drops the rest — the incident of 2026-10-30 (`docs/goals/facts.md`): the
/// command rewrote the LaunchAgent plist without `--agent-control` or
/// `--retain-logs` and every pane's program died. This never fails on
/// c2d6adc through a process, only through this pure function, because the
/// function itself did not exist there.
final class HelpRequestTests: XCTestCase {
    func testTopLevelHelpTokensAreGeneral() {
        XCTAssertEqual(HelpRequest.decide(["--help"]), .general)
        XCTAssertEqual(HelpRequest.decide(["-h"]), .general)
        XCTAssertEqual(HelpRequest.decide(["help"]), .general)
        XCTAssertNil(HelpRequest.decide([]))
    }

    func testEverySubcommandIsCaughtBeforeItRuns() {
        XCTAssertEqual(HelpRequest.decide(["service", "install", "--help"]), .command("service"))
        XCTAssertEqual(HelpRequest.decide(["upgrade", "-h"]), .command("upgrade"))
        XCTAssertEqual(HelpRequest.decide(["restart", "--help"]), .command("restart"))
        XCTAssertEqual(HelpRequest.decide(["start", "--help"]), .command("start"))
        XCTAssertEqual(HelpRequest.decide(["project", "--help"]), .command("project"))
    }

    /// A value that merely contains the text is not the flag: the exact
    /// token must be `--help` or `-h`.
    func testAValueContainingTheWordIsNotAHelpRequest() {
        XCTAssertNil(HelpRequest.decide(["start", "--trusted-host", "--help-desk.example"]))
        XCTAssertNil(HelpRequest.decide(["project", "add", "/tmp/x", "--name", "help-desk"]))
    }

    /// The bare word `help` means help only as the first argument — later it
    /// is an ordinary positional, so a goal or a project can be named it.
    func testBareHelpWordCountsOnlyAsTheFirstArgument() {
        XCTAssertEqual(HelpRequest.decide(["help"]), .general)
        XCTAssertEqual(HelpRequest.decide(["help", "service"]), .general)
        XCTAssertNil(HelpRequest.decide(["goal", "new", "/tmp/x", "help"]))
        XCTAssertNil(HelpRequest.decide(["project", "add", "help"]))
    }

    /// `--help`/`-h` right after a flag that takes a value is that value,
    /// not a help request — `--name -h` names something `-h`.
    func testHelpFlagConsumedAsAValuedFlagsValueIsNotAHelpRequest() {
        XCTAssertNil(HelpRequest.decide(["project", "add", "/tmp/x", "--name", "-h"]))
        XCTAssertNil(HelpRequest.decide(["start", "--trusted-host", "--help"]))
        XCTAssertNil(HelpRequest.decide(["skills", "install", "--dir", "-h"]))
        // Once the valued flag has its own value, a later --help still counts.
        XCTAssertEqual(
            HelpRequest.decide(["start", "--trusted-host", "example.com", "--help"]),
            .command("start")
        )
    }
}
