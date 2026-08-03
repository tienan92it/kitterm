import Foundation
import KittermProtocol

/// Files dropped into a session from the browser, saved where the shell — and
/// so a coding agent running in it — can read them by path.
///
/// Coding agents take context as file paths, not uploads, so dropping a
/// screenshot onto a pane means: save it, then type where it landed. That also
/// makes the phone case work without anything extra — a photo shared from a
/// phone lands on the machine the agent is running on.
///
/// Everything is written under one kitterm-owned directory. The caller never
/// chooses a path, only a name, and that name is rewritten before use — so this
/// is a write into a known directory rather than a way to write anywhere.
enum SessionDrops {
    /// Where a session's dropped files live.
    static func directory(for sessionID: UUID) -> URL {
        DaemonPaths.dropsDirectory.appendingPathComponent(
            sessionID.uuidString, isDirectory: true
        )
    }

    /// A filename safe to join onto the drop directory, or nil if nothing
    /// usable survives.
    ///
    /// Only the last path component is considered, so `../../etc/passwd`
    /// reduces to `passwd`, and the result is restricted to a conservative
    /// charset — a shell is going to see this path, and a name carrying quotes
    /// or spaces makes the inserted path awkward at best.
    static func sanitize(filename raw: String) -> String? {
        let base = (raw as NSString).lastPathComponent
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var cleaned = String(base.map { allowed.contains($0) ? $0 : "-" })
        // Leading dots hide the file and `..` is meaningless here.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > KittermConstants.maxDropNameLength {
            // Keep the extension: it is how an agent decides how to read it.
            let ext = (cleaned as NSString).pathExtension
            let stem = (cleaned as NSString).deletingPathExtension
            let room = KittermConstants.maxDropNameLength - (ext.isEmpty ? 0 : ext.count + 1)
            cleaned = String(stem.prefix(max(1, room))) + (ext.isEmpty ? "" : ".\(ext)")
        }
        return cleaned
    }

    enum StoreError: Error {
        case badName
        case toolarge
        case tooMany
        case writeFailed(String)
    }

    /// Save `data` under the session's drop directory and return where it
    /// landed. Names already in use gain a numeric suffix rather than
    /// overwriting: dropping two screenshots should give two files.
    ///
    /// Blocking file I/O — callers hand this to a queue, never the event loop.
    static func store(data: Data, filename: String, sessionID: UUID) throws -> URL {
        guard data.count <= KittermConstants.maxDropBytes else { throw StoreError.toolarge }
        guard let name = sanitize(filename: filename) else { throw StoreError.badName }

        let directory = directory(for: sessionID)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StoreError.writeFailed("\(error)")
        }

        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard existing.count < KittermConstants.maxDropsPerSession else { throw StoreError.tooMany }

        var candidate = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var suffix = 1
            repeat {
                let next = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                candidate = directory.appendingPathComponent(next)
                suffix += 1
            } while FileManager.default.fileExists(atPath: candidate.path)
                && suffix < KittermConstants.maxDropsPerSession
        }

        do {
            try data.write(to: candidate, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: candidate.path
            )
        } catch {
            throw StoreError.writeFailed("\(error)")
        }
        return candidate
    }

    /// Drop a session's files when it is reaped, the same as retained output —
    /// these came from the user's own device, so the original still exists.
    static func discard(sessionID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: sessionID))
    }
}
