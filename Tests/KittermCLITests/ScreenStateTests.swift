import Foundation
import XCTest

@testable import KittermCLI

/// `ScreenState`'s rules against the real fixtures of `screen-fixtures`
/// (round 1) plus the synthetic cases a fixture cannot carry: no marker at
/// all, a dialog over what would otherwise read as an empty prompt, and a
/// `{dim}` placeholder at the cursor on a screen built for the test.
final class ScreenStateTests: XCTestCase {
    private var fixturesURL: URL {
        CLIFixture.repositoryRoot
            .appendingPathComponent("Tests")
            .appendingPathComponent("KittermCLITests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("screen-state")
    }

    private struct Fixture {
        let name: String
        let lines: [String]
        let cursor: ScreenState.Cursor
        let state: String
    }

    /// `read_screen` carries no `foregroundProgram` — it is the session
    /// row's field, not the screen's — so each fixture names its own,
    /// matching how it was recorded. Only `agent-exited-1` was captured
    /// after `claude` exited (its `method` says `get_session` confirmed the
    /// field absent); every other fixture was captured with `claude` still
    /// running the pane.
    private func foregroundProgram(for name: String) -> String? {
        name == "agent-exited-1" ? nil : "claude"
    }

    private func fixtures() throws -> [Fixture] {
        let files = try CLIFixture.files(under: fixturesURL)
        var result: [Fixture] = []
        for (path, data) in files where path.hasSuffix(".json") {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let name = String(path.dropLast(".json".count))
            let lines = try XCTUnwrap(object["lines"] as? [String], name)
            let cursorObject = try XCTUnwrap(object["cursor"] as? [String: Any], name)
            let cursor = ScreenState.Cursor(
                row: try XCTUnwrap(cursorObject["row"] as? Int, name),
                col: try XCTUnwrap(cursorObject["col"] as? Int, name),
                visible: try XCTUnwrap(cursorObject["visible"] as? Bool, name)
            )
            let state = try XCTUnwrap(object["state"] as? String, name)
            result.append(Fixture(name: name, lines: lines, cursor: cursor, state: state))
        }
        return result.sorted { $0.name < $1.name }
    }

    /// The proof row of `plan.md` capability 2: every fixture from
    /// capability 1 gives the rules its own recorded state.
    func testEveryFixtureGivesItsRecordedState() throws {
        for fixture in try fixtures() {
            let result = ScreenState.evaluate(
                lines: fixture.lines,
                cursor: fixture.cursor,
                foregroundProgram: foregroundProgram(for: fixture.name)
            )
            XCTAssertEqual(result.state.rawValue, fixture.state, fixture.name)
            if fixture.state != "unknown" {
                XCTAssertNotNil(result.line, fixture.name)
            } else {
                XCTAssertNil(result.line, fixture.name)
            }
        }
    }

    func testASyntheticScreenWithNoMarkerGivesUnknown() {
        let lines = [
            "Just some ordinary output.",
            "Nothing here looks like a prompt or a dialog.",
        ]
        let cursor = ScreenState.Cursor(row: 1, col: 0, visible: true)
        let result = ScreenState.evaluate(lines: lines, cursor: cursor, foregroundProgram: "claude")
        XCTAssertEqual(result.state, .unknown)
        XCTAssertNil(result.line)
    }

    /// A trust dialog can sit over a screen whose cursor row is a bare "❯",
    /// which on its own reads as `prompt-empty`. The dialog must win: issue
    /// #171's order checks dialogs before the prompt states.
    func testADialogAboveAPromptGivesTheDialog() {
        let lines = [
            " Quick safety check: Is this a project you created or one you trust?",
            " ❯ No, exit",
            "   Yes, I trust this folder",
            "❯",
        ]
        let cursor = ScreenState.Cursor(row: 3, col: 1, visible: true)
        let result = ScreenState.evaluate(lines: lines, cursor: cursor, foregroundProgram: "claude")
        XCTAssertEqual(result.state, .trustDialog)
        XCTAssertEqual(result.line?.index, 2)
    }

    /// A `{dim}…{/dim}` run filling the whole remainder of the cursor's "❯"
    /// row is Claude Code's ghost suggestion, not typed text.
    func testAPlaceholderAtTheCursorGivesPromptEmpty() {
        let lines = ["❯ {dim}Try \"refactor <filepath>\"{/dim}"]
        let cursor = ScreenState.Cursor(row: 0, col: 2, visible: true)
        let result = ScreenState.evaluate(lines: lines, cursor: cursor, foregroundProgram: "claude")
        XCTAssertEqual(result.state, .promptEmpty)
        XCTAssertEqual(result.rule, "prompt-empty: \"❯\" at the cursor, empty or a dim placeholder")
        XCTAssertEqual(result.line, ScreenState.Line(index: 0, text: lines[0]))
    }

    /// A bare "❯" with nothing typed and no placeholder is empty too.
    func testABarePromptWithNoPlaceholderIsAlsoEmpty() {
        let lines = ["❯"]
        let cursor = ScreenState.Cursor(row: 0, col: 1, visible: true)
        let result = ScreenState.evaluate(lines: lines, cursor: cursor, foregroundProgram: "claude")
        XCTAssertEqual(result.state, .promptEmpty)
    }

    func testAgentExitedNeedsNoScreenMarkerOnlyTheAbsenceOfClaude() {
        let lines = ["user@host project %"]
        let cursor = ScreenState.Cursor(row: 0, col: 19, visible: true)
        let result = ScreenState.evaluate(lines: lines, cursor: cursor, foregroundProgram: nil)
        XCTAssertEqual(result.state, .agentExited)
        XCTAssertEqual(result.line, ScreenState.Line(index: 0, text: lines[0]))

        let vim = ScreenState.evaluate(lines: lines, cursor: cursor, foregroundProgram: "vim")
        XCTAssertEqual(vim.state, .agentExited)

        let stillClaude = ScreenState.evaluate(lines: lines, cursor: cursor, foregroundProgram: "claude")
        XCTAssertEqual(stillClaude.state, .unknown)
    }

    /// Many shells (Starship, Powerlevel10k, pure) draw their own prompt
    /// with "❯", sometimes a bare one on its own line exactly like Claude
    /// Code's empty box — "pure" does. Once `claude` has exited, that line
    /// must not read as `prompt-empty`: `agent-exited` is checked first, so
    /// a foreman never types into a bare shell believing it is a pane.
    func testAShellPromptThatDrawsABareAngleQuoteIsAgentExitedNotPromptEmpty() {
        let lines = ["~/project", "❯"]
        let cursor = ScreenState.Cursor(row: 1, col: 1, visible: true)
        let result = ScreenState.evaluate(lines: lines, cursor: cursor, foregroundProgram: nil)
        XCTAssertEqual(result.state, .agentExited)
        XCTAssertEqual(result.rule, "agent-exited: no claude in foregroundProgram")
        XCTAssertEqual(result.line, ScreenState.Line(index: 1, text: "❯"))
    }
}
