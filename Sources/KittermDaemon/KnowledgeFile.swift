#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Read-only access to a project's knowledge directory (`<root>/<knowledge>`,
/// `docs/goals` by default) behind `GET /api/projects/<id>/knowledge/<path>`
/// and the summary route beside it.
///
/// The jail: the path from the URL is relative, holds no `..`, no empty and
/// no `.` segment; every component under the root is checked with `lstat`
/// and a symlink anywhere in the chain is refused, the knowledge directory
/// included; the final `realpath` must still sit under the knowledge
/// directory. The root itself is a `realpath` already
/// (`ProjectStore.canonicalRoot`). Files are capped at `maxBytes`. Every
/// function here touches the disk, so the routes call them off the loop.
enum KnowledgeFile {
    static let maxBytes = 256 * 1024
    static let maxPathLength = 1024
    /// One serial queue for every knowledge read, so a burst of dashboard
    /// polls costs one thread and the loop never waits on the disk.
    static let queue = DispatchQueue(label: "kitterm.knowledge")

    enum Failure: Error, Equatable {
        /// A malformed path: absolute, `..`, an empty or `.` segment.
        case badPath
        /// Nothing servable at the path: missing, a directory, or unreadable.
        case notFound
        /// A symlink in the chain, or a path that resolves outside.
        case refused
        /// The file is over `maxBytes`.
        case tooLarge
    }

    struct Payload: Sendable {
        let data: Data
        let contentType: String
    }

    /// The relative path a URL suffix names, or nil when it is malformed.
    /// `raw` is the percent-encoded remainder after `/knowledge/`.
    static func relativePath(_ raw: String) -> String? {
        guard raw.count <= maxPathLength, let decoded = raw.removingPercentEncoding,
              isValidRelative(decoded)
        else { return nil }
        return decoded
    }

    /// Not empty, not absolute, no NUL, and every segment a plain name.
    static func isValidRelative(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= maxPathLength, !path.hasPrefix("/"), !path.contains("\0")
        else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The bytes and the content type of `path` under the knowledge
    /// directory. `knowledge` is relative to `root`.
    static func read(root: String, knowledge: String, path: String) throws -> Payload {
        let directory = try jailedDirectory(root: root, knowledge: knowledge)
        let full = try jailedPath(directory: directory, root: root, knowledge: knowledge, path: path)
        var info = stat()
        guard stat(full, &info) == 0 else { throw Failure.notFound }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.notFound }
        guard info.st_size <= maxBytes else { throw Failure.tooLarge }
        guard let handle = FileHandle(forReadingAtPath: full) else { throw Failure.notFound }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return Payload(data: data, contentType: contentType(for: path))
    }

    /// `text/markdown` for `.md`, `text/plain` for everything else. Never the
    /// file's own type: this is the daemon's origin, and a `text/html` answer
    /// would run with the auth cookie (see `FilePreview`).
    static func contentType(for path: String) -> String {
        path.lowercased().hasSuffix(".md") ? "text/markdown; charset=utf-8" : "text/plain; charset=utf-8"
    }

    /// The summary of the package under the knowledge directory, or nil
    /// when the directory is missing or refused. Every file goes through the
    /// jailed read, so a symlinked `STATE.md` leaves its fields absent.
    static func summary(root: String, knowledge: String) -> KnowledgeSummary? {
        guard let directory = try? jailedDirectory(root: root, knowledge: knowledge) else { return nil }
        let text = { (path: String) -> String? in
            guard let payload = try? read(root: root, knowledge: knowledge, path: path) else { return nil }
            return String(data: payload.data, encoding: .utf8)
        }
        let roundNames = (try? FileManager.default.contentsOfDirectory(atPath: directory + "/rounds")) ?? []
        let latest = roundNames.compactMap(KnowledgeSummary.roundNumber).max()
        return KnowledgeSummary.parse(
            state: text("STATE.md"),
            goal: text("goal.md"),
            roundNames: roundNames,
            latestRound: latest.map { text("rounds/" + KnowledgeSummary.roundFileName($0)) } ?? nil
        )
    }

    // MARK: - the jail

    /// `<root>/<knowledge>` when every component under the root is a real
    /// directory. A missing directory is `notFound`; a symlink is `refused`.
    static func jailedDirectory(root: String, knowledge: String) throws -> String {
        guard ProjectStore.isValidKnowledge(knowledge) else { throw Failure.badPath }
        var current = root
        for segment in knowledge.split(separator: "/") {
            current += "/" + segment
            try refuseSymlink(current)
        }
        var info = stat()
        guard stat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.notFound }
        return current
    }

    /// `<directory>/<path>` when no component of `path` is a symlink and the
    /// resolved path stays under `directory`.
    private static func jailedPath(directory: String, root: String, knowledge: String, path: String) throws -> String {
        guard isValidRelative(path) else { throw Failure.badPath }
        var current = directory
        for segment in path.split(separator: "/") {
            current += "/" + segment
            try refuseSymlink(current)
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(current, &buffer) != nil else { throw Failure.notFound }
        let resolved = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard resolved.hasPrefix(directory + "/") else { throw Failure.refused }
        return current
    }

    /// `refused` for a symlink at `path`; `notFound` when nothing is there.
    private static func refuseSymlink(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Failure.notFound }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw Failure.refused }
    }
}
