import Foundation
import KittermProtocol
import NIOCore
import XCTest

@testable import KittermDaemon

/// Naming a command when the shell will not name it.
///
/// Only kitterm's own snippet and VS Code emit the command line (OSC 633;E).
/// A shell carrying someone else's OSC 133 — iTerm2, Powerlevel10k — marks
/// every command but never says what it was, and those integrations are common
/// enough that a caller cannot depend on the snippet being installed. When the
/// command arrived through the input route the daemon already knows the text.
final class SubmittedCommandNameTests: XCTestCase {
    private var session: PtySession!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: SubmittedCommandNameTests.self)
            .bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        session = try PtySession.spawn(cwd: NSTemporaryDirectory())
    }

    override func tearDownWithError() throws {
        session?.terminate()
        session = nil
    }

    private func feed(_ text: String) {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        session.handleRead(&buffer)
    }

    private func submit(_ text: String) {
        session.noteSubmittedCommand(Data(text.utf8))
    }

    /// A shell that marks the command without naming it.
    private func runUnnamedCommand(exit code: Int = 0) {
        feed("\u{1b}]133;C\u{07}output\u{1b}]133;D;\(code)\u{07}")
    }

    func testAnUnnamedCommandTakesTheSubmittedText() throws {
        submit("make test\n")
        runUnnamedCommand()
        let command = try XCTUnwrap(session.commandsSnapshot().first)
        XCTAssertEqual(command.command, "make test")
        XCTAssertEqual(command.exit, 0)
    }

    /// When the shell does report the command line, that wins — it is what the
    /// shell actually ran, and it may differ from what was submitted.
    func testAReportedCommandLineIsNotOverwritten() throws {
        submit("what the caller sent\n")
        feed("\u{1b}]633;E;what the shell ran\u{07}\u{1b}]133;C\u{07}\u{1b}]133;D;0\u{07}")
        XCTAssertEqual(session.commandsSnapshot().first?.command, "what the shell ran")
    }

    /// The text names one command, not every command after it.
    func testTheTextIsUsedOnceOnly() throws {
        submit("first\n")
        runUnnamedCommand()
        runUnnamedCommand()
        let commands = session.commandsSnapshot()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].command, "first")
        XCTAssertNil(commands[1].command, "a later command must not inherit the name")
    }

    /// A keystroke answering a prompt is not a command; only whole submissions
    /// are, which is what the trailing newline distinguishes.
    func testPartialInputIsNotACommand() throws {
        submit("y")
        runUnnamedCommand()
        XCTAssertNil(session.commandsSnapshot().first?.command)
    }

    func testBlankSubmissionsAreIgnored() throws {
        submit("   \n")
        runUnnamedCommand()
        XCTAssertNil(session.commandsSnapshot().first?.command)
    }

    /// Nothing is remembered until something is submitted.
    func testWithoutSubmittedTextTheCommandStaysAnonymous() throws {
        runUnnamedCommand(exit: 3)
        let command = try XCTUnwrap(session.commandsSnapshot().first)
        XCTAssertNil(command.command)
        XCTAssertEqual(command.exit, 3, "the rest of the record is unaffected")
    }
}
