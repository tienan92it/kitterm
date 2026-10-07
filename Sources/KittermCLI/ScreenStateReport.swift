import Foundation
import KittermScreen

/// Turns the `GET …/output` response and the session row's
/// `foregroundProgram` into the `screen_state` tool result: `ScreenState`'s
/// answer, as JSON a foreman reads. Renders the same bytes at the same size
/// as `ScreenReport` (ADR 0001: the bridge renders, the daemon never does),
/// then hands the lines and the cursor to the pure rules.
enum ScreenStateReport {
    static func text(
        data: Data,
        headers: [String: String],
        options: MCPTools.ScreenOptions,
        foregroundProgram: String?
    ) throws -> String {
        guard let cols = options.cols ?? ScreenReport.header("x-kitterm-cols", in: headers).flatMap({ Int($0) }),
              let rows = options.rows ?? ScreenReport.header("x-kitterm-rows", in: headers).flatMap({ Int($0) })
        else {
            throw ScreenReport.Failure.missingSize
        }
        let start = ScreenReport.header("x-kitterm-start", in: headers).flatMap { UInt64($0) } ?? 0
        let screen = ScreenRenderer.render(data, cols: cols, rows: rows, streamStart: start)
        // Styles on, always: the prompt-empty rule reads the `{dim}…{/dim}`
        // ghost suggestion, which plain text would show as ordinary typed text.
        let lines = screen.lines(styles: true)
        let cursor = ScreenState.Cursor(row: screen.cursorRow, col: screen.cursorCol, visible: screen.cursorVisible)
        let result = ScreenState.evaluate(lines: lines, cursor: cursor, foregroundProgram: foregroundProgram)

        var payload: [String: Any] = [
            "ok": true,
            "state": result.state.rawValue,
            "rule": result.rule,
            "line": result.line.map { ["index": $0.index, "text": $0.text] as [String: Any] } ?? NSNull(),
        ]
        if let version = claudeCodeVersion(in: lines) {
            payload["claudeCodeVersion"] = version
        }
        let json = try JSONSerialization.data(
            withJSONObject: payload, options: [.withoutEscapingSlashes, .sortedKeys]
        )
        return String(decoding: json, as: UTF8.self)
    }

    private static let versionPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "Claude Code v([0-9]+\\.[0-9]+\\.[0-9]+)")
    }()

    /// Claude Code's startup banner names its own version; absent once the
    /// banner scrolls out of the rendered tail, which is most of the time —
    /// 7 of the 11 `screen-state` fixtures carry no banner at all.
    private static func claudeCodeVersion(in lines: [String]) -> String? {
        for line in lines {
            let whole = NSRange(line.startIndex..., in: line)
            guard let match = versionPattern.firstMatch(in: line, range: whole),
                  let range = Range(match.range(at: 1), in: line)
            else { continue }
            return String(line[range])
        }
        return nil
    }
}
