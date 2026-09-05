import Foundation
import XCTest

@testable import KittermScreen

/// Real Claude Code pane logs (`--retain-logs`, `~/.kitterm/logs/<id>.log`)
/// captured from a session spawned at 100 × 30 on 2026-09-04 with Claude Code
/// v2.1.260. `read_screen` exists because the raw bytes of these panes were
/// unreadable to a foreman; the renders below are what it now sees.
final class ClaudePaneFixtureTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "pty", subdirectory: "Fixtures"),
            "fixture \(name).pty missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    /// Byte offset just past the first `needle` at or after `from`.
    private func end(of needle: String, in data: Data, from: Int = 0) -> Int? {
        let bytes = Array(data)
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        var i = from
        while i + pattern.count <= bytes.count {
            if bytes[i..<(i + pattern.count)].elementsEqual(pattern) { return i + pattern.count }
            i += 1
        }
        return nil
    }

    private func assertClean(_ lines: [String], rows: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(lines.count, rows, file: file, line: line)
        for text in lines {
            XCTAssertFalse(text.contains("\u{1b}"), "escape leaked into: \(text)", file: file, line: line)
            XCTAssertFalse(text.contains("\r"), file: file, line: line)
        }
    }

    // MARK: - the folder-trust dialog

    /// The first screen a fresh pane shows: a dialog with two options and a
    /// `❯` on the selected one. A foreman reading raw bytes saw `ESC[2G`
    /// between every word; a foreman reading this sees the choice.
    func testTrustDialogRendersAsAMenu() throws {
        let data = try fixture("claude-trust-dialog-100x30")
        let screen = ScreenRenderer.render(data, cols: 100, rows: 30)
        let lines = screen.lines(styles: true)
        assertClean(lines, rows: 30)

        XCTAssertEqual(lines[0], "antran@GenOS-Pro fixture-cwd % claude")
        XCTAssertEqual(lines[3], " Accessing workspace:")
        XCTAssertTrue(lines[8].hasPrefix(" Quick safety check: Is this a project you created or one you trust?"))
        // Ink writes each word at an absolute column (`ESC[<n>G`); the
        // columns must land the words on one readable line.
        XCTAssertEqual(lines[12], " Claude Code'll be able to read, edit, and execute files here.")
        XCTAssertEqual(lines[16], " ❯ No, exit")
        XCTAssertEqual(lines[17], "   Yes, I trust this folder")
        XCTAssertEqual(lines[19], " Enter to confirm · Esc to cancel")
        XCTAssertFalse(screen.cursorVisible)
    }

    /// Ink wrapped the long path for a 100-column pane (at column 99, its
    /// own rule) and drew each half at an absolute column. Rendering at the
    /// pane's real size keeps the halves where it put them.
    func testTrustDialogKeepsInksWrapOfTheLongPath() throws {
        let lines = ScreenRenderer.render(try fixture("claude-trust-dialog-100x30"), cols: 100, rows: 30)
            .lines(styles: false)
        XCTAssertTrue(lines[5].hasSuffix("/scratchpad/fixture-cwd".prefix(6)), lines[5])
        XCTAssertEqual(lines[5].count, 99)
        XCTAssertEqual(lines[6], " chpad/fixture-cwd")
    }

    /// The tail route hands the bridge a cut; the dialog must survive one.
    func testTrustDialogRendersFromACutTail() throws {
        let data = try fixture("claude-trust-dialog-100x30")
        let full = ScreenRenderer.render(data, cols: 100, rows: 30).lines(styles: true)
        let tail = data.suffix(1500)
        let cut = ScreenRenderer.render(
            tail, cols: 100, rows: 30, streamStart: UInt64(data.count - tail.count)
        ).lines(styles: true)
        XCTAssertEqual(cut, full)
    }

    // MARK: - the idle prompt

    /// The incident: an empty prompt shows a dim ghost suggestion. Plain
    /// text reads it as typed input (what the foreman saw); the styled
    /// render marks it dim.
    func testGhostSuggestionIsMarkedDim() throws {
        let data = try fixture("claude-idle-prompt-100x30")
        // The frame that draws the suggestion ends at the next `ESC[?25h`
        // (cursor shown) after it; render the log up to there.
        let ghostAt = try XCTUnwrap(end(of: "Try \"refactor <filepath>\"", in: data))
        let frameEnd = try XCTUnwrap(end(of: "\u{1b}[?25h", in: data, from: ghostAt))
        let screen = ScreenRenderer.render(data.prefix(frameEnd), cols: 100, rows: 30)

        let styled = screen.lines(styles: true)
        assertClean(styled, rows: 30)
        let promptRow = try XCTUnwrap(styled.firstIndex { $0.hasPrefix("❯ ") })
        XCTAssertEqual(styled[promptRow], "❯ {dim}Try \"refactor <filepath>\"{/dim}")

        let plain = screen.lines(styles: false)
        XCTAssertEqual(plain[promptRow], "❯ Try \"refactor <filepath>\"")
        // The cursor sits right after the prompt marker: nothing is typed.
        XCTAssertEqual(screen.cursorRow, promptRow)
        XCTAssertEqual(screen.cursorCol, 2)
    }

    /// The settled screen: banner at the top, an empty prompt between two
    /// rules, the status line under it, cursor on the prompt.
    func testIdlePromptRendersWithCursorOnThePrompt() throws {
        let data = try fixture("claude-idle-prompt-100x30")
        let screen = ScreenRenderer.render(data, cols: 100, rows: 30)
        let lines = screen.lines(styles: true)
        assertClean(lines, rows: 30)

        XCTAssertTrue(lines[1].contains("Claude Code v2.1.260"), lines[1])
        XCTAssertEqual(lines[24], String(repeating: "─", count: 100))
        XCTAssertEqual(lines[25], "❯")
        XCTAssertEqual(lines[26], String(repeating: "─", count: 100))
        XCTAssertTrue(lines[28].contains("auto mode on (shift+tab to cycle)"), lines[28])
        XCTAssertEqual(screen.cursorRow, 25)
        XCTAssertEqual(screen.cursorCol, 2)
        XCTAssertTrue(screen.cursorVisible)
    }

    /// The same frame from a cut tail: the anchor rule places the prompt
    /// area where the pane put it.
    func testIdlePromptRendersFromACutTail() throws {
        let data = try fixture("claude-idle-prompt-100x30")
        let tail = data.suffix(1500)
        let screen = ScreenRenderer.render(
            tail, cols: 100, rows: 30, streamStart: UInt64(data.count - tail.count)
        )
        let lines = screen.lines(styles: true)
        XCTAssertEqual(lines[25], "❯")
        XCTAssertEqual(screen.cursorRow, 25)
        XCTAssertEqual(screen.cursorCol, 2)
    }

    /// Rendering narrower than the pane wraps the 100-column rules, and every
    /// relative move after them lands a row off: the prompt is no longer
    /// where the cursor says. That is why the route reports the pane's real
    /// size instead of the bridge assuming one.
    func testNarrowerSizeMisplacesThePrompt() throws {
        let data = try fixture("claude-idle-prompt-100x30")
        let screen = ScreenRenderer.render(data, cols: 60, rows: 30)
        let lines = screen.lines(styles: false)
        XCTAssertNotEqual(lines.count > 25 ? lines[25] : "", "❯")
        XCTAssertFalse(lines[screen.cursorRow].hasPrefix("❯"), lines[screen.cursorRow])
    }
}
