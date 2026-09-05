import Foundation
import KittermScreen

/// Turns the `GET …/output` response into the `read_screen` tool result:
/// the bytes rendered at the pane's size, as JSON the foreman reads.
enum ScreenReport {
    enum Failure: Error, Equatable {
        case missingSize
    }

    /// `headers` are the response headers, keyed case-insensitively by the
    /// caller. Renders at the pane's `X-Kitterm-Cols` × `X-Kitterm-Rows`
    /// unless the options override one or both.
    static func text(
        data: Data,
        headers: [String: String],
        options: MCPTools.ScreenOptions
    ) throws -> String {
        guard let cols = options.cols ?? header("x-kitterm-cols", in: headers).flatMap({ Int($0) }),
              let rows = options.rows ?? header("x-kitterm-rows", in: headers).flatMap({ Int($0) })
        else {
            throw Failure.missingSize
        }
        let start = header("x-kitterm-start", in: headers).flatMap { UInt64($0) } ?? 0
        let screen = ScreenRenderer.render(data, cols: cols, rows: rows, streamStart: start)
        var payload: [String: Any] = [
            "ok": true,
            "cols": screen.cols,
            "rows": screen.rows,
            "cursor": [
                "row": screen.cursorRow,
                "col": screen.cursorCol,
                "visible": screen.cursorVisible,
            ],
            "lines": screen.lines(styles: options.styles),
            "renderedBytes": data.count,
        ]
        if options.styles {
            payload["legend"] = "{dim}…{/dim} marks dim text (a placeholder or hint, not typed input); {inv}…{/inv} marks inverse video (a selected row)"
        }
        let json = try JSONSerialization.data(
            withJSONObject: payload, options: [.withoutEscapingSlashes, .sortedKeys]
        )
        return String(decoding: json, as: UTF8.self)
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }
}
