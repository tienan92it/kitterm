import Foundation
import XCTest

@testable import KittermCLI

/// The `screen_state` tool result: the same output-route bytes and headers
/// `ScreenReportTests` feeds `ScreenReport`, now run through `ScreenState`'s
/// rules too. No HTTP server — these bytes and headers are what the daemon's
/// `GET …/output` route would answer, so this is the fake daemon route
/// `ScreenReportTests` tests through.
final class ScreenStateReportTests: XCTestCase {
    private let headers = [
        "X-Kitterm-Cols": "40", "X-Kitterm-Rows": "5",
        "X-Kitterm-Start": "0", "X-Kitterm-Head": "30",
    ]

    private func report(
        _ text: String,
        headers: [String: String]? = nil,
        options: MCPTools.ScreenOptions = .init(styles: true),
        foregroundProgram: String? = "claude"
    ) throws -> [String: Any] {
        let json = try ScreenStateReport.text(
            data: Data(text.utf8),
            headers: headers ?? self.headers,
            options: options,
            foregroundProgram: foregroundProgram
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testAnEmptyPromptWithAGhostSuggestionAnswersPromptEmpty() throws {
        // No trailing `\r\n`: the cursor stays on the prompt's own row, the
        // shape `ScreenState` needs — `ScreenReportTests`'s own fixture moves
        // it to the next (blank, trimmed) row, which this rule must not read.
        let result = try report("❯ \u{1b}[2mTry \"refactor\"\u{1b}[22m")
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["state"] as? String, "prompt-empty")
        XCTAssertEqual(result["rule"] as? String, "prompt-empty: \"❯\" at the cursor, empty or a dim placeholder")
        let line = try XCTUnwrap(result["line"] as? [String: Any])
        XCTAssertEqual(line["index"] as? Int, 0)
        XCTAssertEqual(line["text"] as? String, "❯ {dim}Try \"refactor\"{/dim}")
        XCTAssertNil(result["claudeCodeVersion"])
    }

    func testTypedTextAtTheCursorAnswersPromptHasText() throws {
        let result = try report("❯ hello there")
        XCTAssertEqual(result["state"] as? String, "prompt-has-text")
    }

    /// `foregroundProgram` is the bridge's own second request, not part of
    /// the rendered bytes — its absence, with no screen marker, answers
    /// `agent-exited`.
    func testNoForegroundProgramAndNoMarkerAnswersAgentExited() throws {
        let result = try report("user@host project %", foregroundProgram: nil)
        XCTAssertEqual(result["state"] as? String, "agent-exited")
        XCTAssertEqual(result["rule"] as? String, "agent-exited: no claude in foregroundProgram")
    }

    /// The Claude Code startup banner, when it is still in the rendered
    /// tail, names its own version in the answer.
    func testTheStartupBannerNamesTheClaudeCodeVersion() throws {
        let result = try report(" ▐▛███▛█   Claude Code v2.1.292\r\n❯ ", options: .init(styles: true))
        XCTAssertEqual(result["claudeCodeVersion"] as? String, "2.1.292")
    }

    func testAnOldDaemonWithoutSizeHeadersIsAnError() {
        XCTAssertThrowsError(
            try ScreenStateReport.text(data: Data(), headers: [:], options: .init(styles: true), foregroundProgram: nil)
        ) { error in
            XCTAssertEqual(error as? ScreenReport.Failure, .missingSize)
        }
    }
}
