import Foundation
import KittermDaemon

/// One JSON line per `screen_state` answer, appended to
/// `~/.kitterm/screen-state.log` (`DaemonPaths.screenStateLogFile`,
/// `KITTERM_STATE_DIR` moves it), so `kitterm screen-state stats` can count
/// states with no daemon and no network call (`goal.md` condition 3). The
/// line carries only what the tool's own answer already carries — the
/// state word, the rule name, the session id, and the time — never the
/// screen text or the matched line's text, either of which can hold a
/// user's own typed input.
enum ScreenStateLog {
    /// Past this size the current file becomes `screen-state.log.1` (one
    /// old file kept) before the next line lands.
    static let maxBytes = 1 * 1024 * 1024

    /// The shape of one line: `{at, session, state, rule, source}`.
    static func line(at: Date, session: String, state: String, rule: String) throws -> String {
        let payload: [String: Any] = [
            "at": isoFormatter().string(from: at),
            "session": session,
            "state": state,
            "rule": rule,
            "source": "rules",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.withoutEscapingSlashes, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Append one line. Called after `screen_state` has already answered
    /// (`MCPBridge.handleScreenState`), off the request path: every error
    /// here is swallowed, because a failed write must never fail the tool
    /// call that already went out.
    static func append(
        session: String,
        state: String,
        rule: String,
        at: Date = Date(),
        to fileURL: URL = DaemonPaths.screenStateLogFile
    ) {
        try? appendOrThrow(session: session, state: state, rule: rule, at: at, to: fileURL)
    }

    /// The throwing half, so a test can see what a real failure looks like
    /// instead of only its silence.
    static func appendOrThrow(
        session: String, state: String, rule: String, at: Date, to fileURL: URL
    ) throws {
        let text = try line(at: at, session: session, state: state, rule: rule)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try rotateIfOversize(fileURL)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(
                atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((text + "\n").utf8))
    }

    /// Rename the current file to `<name>.1` before a write that would push
    /// it past `maxBytes`, dropping whatever `.1` already held: one old
    /// file is the bound, not two.
    private static func rotateIfOversize(_ fileURL: URL) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size >= maxBytes
        else { return }
        let rotated = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".1")
        try? FileManager.default.removeItem(at: rotated)
        try FileManager.default.moveItem(at: fileURL, to: rotated)
    }

    /// A fresh formatter per call: `ISO8601DateFormatter` is not `Sendable`,
    /// so nothing here shares one across calls.
    static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// Parses a line's `at` field back into a `Date`.
    static func parseDate(_ text: String) -> Date? {
        isoFormatter().date(from: text)
    }
}
