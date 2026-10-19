import Foundation

/// One JSON line per `PUT /api/files/content` attempt that passed the grade
/// check, appended to `~/.kitterm/edits.log` (`DaemonPaths.editsLogFile`,
/// `KITTERM_STATE_DIR` moves it): the audit trail of the one route that
/// writes outside `~/.kitterm/` (ADR 0005). A line carries the time, the
/// token kind (`loopback`, `ephemeral`, `token:<name>`), the resolved path,
/// the body's size, the hash of the bytes replaced and of the bytes sent,
/// and the status code answered. Never the content: a line is as long for
/// a 403 as for a 200.
///
/// The file is `0600`, rotated to `edits.log.1` past `maxBytes` with one old
/// file kept, the discipline of `screen-state.log`. Every append runs on
/// `FileEdit.queue`, after the answer is decided, so a failed write never
/// fails the save and nothing here touches the event loop.
enum EditLog {
    static let maxBytes = 1 * 1024 * 1024

    struct Entry: Sendable {
        let at: Date
        let token: String
        let path: String
        let bytes: Int
        /// `sha256:<hex>` of the bytes replaced; nil before the file was read.
        let oldHash: String?
        /// `sha256:<hex>` of the body.
        let newHash: String
        let status: Int
    }

    /// `{at, bytes, newHash, oldHash, path, status, token}`, keys sorted.
    static func line(_ entry: Entry) throws -> String {
        var payload: [String: Any] = [
            "at": isoFormatter().string(from: entry.at),
            "token": entry.token,
            "path": entry.path,
            "bytes": entry.bytes,
            "newHash": entry.newHash,
            "status": entry.status,
        ]
        if let old = entry.oldHash { payload["oldHash"] = old }
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.withoutEscapingSlashes, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Append one line; every error is swallowed, because the answer has
    /// already been decided and the audit must never fail the save.
    static func append(_ entry: Entry, to fileURL: URL = DaemonPaths.editsLogFile) {
        try? appendOrThrow(entry, to: fileURL)
    }

    static func appendOrThrow(_ entry: Entry, to fileURL: URL) throws {
        let text = try line(entry)
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

    private static func rotateIfOversize(_ fileURL: URL) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size >= maxBytes
        else { return }
        let rotated = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".1")
        try? FileManager.default.removeItem(at: rotated)
        try FileManager.default.moveItem(at: fileURL, to: rotated)
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
