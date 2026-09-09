#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Read-only access to a project's knowledge directory (`<root>/<knowledge>`,
/// `docs/goals` by default) behind `GET /api/projects/<id>/knowledge/<path>`
/// and the summary route beside it, which lists the goal folders under it.
///
/// The jail: the path from the URL is relative, holds no `..`, no empty and
/// no `.` segment. A file read walks one descriptor from the root, opens
/// every component with `O_NOFOLLOW`, and reads through the descriptor it
/// `fstat`ed, so the check and the read see one inode and a symlink anywhere
/// in the chain is refused, the root and the knowledge directory included.
/// The summary's listing of `rounds/` goes through `lstat` the same way.
/// Files are capped at `maxBytes`. Every function here touches the disk, so
/// the routes call them off the loop.
///
/// Accepted: a hard link under the knowledge directory to a file elsewhere
/// on the volume is served. The linker needs write access to the project
/// tree, and that writer can copy the file into the directory outright.
enum KnowledgeFile {
    static let maxBytes = 256 * 1024
    static let maxPathLength = 1024
    /// Goal folders read per listing, in name order; the rest are skipped.
    /// A checkout with thousands of child folders would otherwise hold the
    /// knowledge queue for every other project and answer a body the fleet
    /// view cannot show. `LOOP.md` keeps a goal's folder forever, so the
    /// bound is the number of goals a project can have at once.
    static let maxGoalFolders = 64
    /// One serial queue for every knowledge read, so a burst of dashboard
    /// polls costs one thread and the loop never waits on the disk.
    /// Accepted: a stalled mount under one project's root holds every other
    /// project's summary behind it; the fleet view bounds each summary
    /// request by its poll interval, so the stall costs one card at a time
    /// and never the fleet.
    static let queue = DispatchQueue(label: "kitterm.knowledge")

    enum Failure: Error, Equatable {
        /// A malformed path: absolute, `..`, an empty or `.` segment.
        case badPath
        /// Nothing servable at the path: missing, a directory, or unreadable.
        case notFound
        /// A symlink in the chain, the root and the knowledge directory included.
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
    /// directory. `knowledge` is relative to `root`. One descriptor walk:
    /// each component is opened with `O_NOFOLLOW` relative to the one
    /// before, the file with `O_NONBLOCK` too, so a FIFO answers at once and
    /// its type refuses it; the size and the type come from `fstat` on the
    /// descriptor the bytes are read from.
    static func read(root: String, knowledge: String, path: String) throws -> Payload {
        guard ProjectStore.isValidKnowledge(knowledge), isValidRelative(path) else { throw Failure.badPath }
        let segments = (knowledge.split(separator: "/") + path.split(separator: "/")).map(String.init)
        var current = try openComponent(at: AT_FDCWD, root, directory: true)
        defer { close(current) }
        for segment in segments.dropLast() {
            let next = try openComponent(at: current, segment, directory: true)
            close(current)
            current = next
        }
        let file = try openComponent(at: current, segments[segments.count - 1], directory: false)
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw Failure.notFound }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.notFound }
        guard info.st_size <= maxBytes else { throw Failure.tooLarge }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return Payload(data: data, contentType: contentType)
    }

    /// Every file is `text/plain`, `.md` included: a link from the fleet
    /// view must show a page, and Chrome for Android and Firefox download
    /// `text/markdown` under `nosniff`. Never the file's own type: this is
    /// the daemon's origin, and a `text/html` answer would run with the auth
    /// cookie (see `FilePreview`).
    static let contentType = "text/plain; charset=utf-8"

    /// One summary per goal folder under the knowledge directory, in
    /// `KnowledgeSummary.isOrderedBefore` order, or nil when the directory
    /// is missing or refused. A goal folder is a direct child whose name is
    /// a slug (`ProjectStore.isValidID`, the rule `kitterm goal new`
    /// enforces), that is a real directory holding a regular `STATE.md`: a
    /// child with any other name, or without a `STATE.md`, is not a goal
    /// and is skipped; a symlinked child, or a symlinked `STATE.md`, is
    /// refused like every other component and skipped too. The first
    /// `maxGoalFolders` such names in name order are read; the rest are
    /// skipped. The folder name is the slug and prefixes `lastRecord`. A
    /// package with no goal folder is an empty list.
    static func summaries(root: String, knowledge: String) -> [KnowledgeSummary]? {
        guard let directory = try? jailedDirectory(root: root, knowledge: knowledge) else { return nil }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter(ProjectStore.isValidID).sorted().prefix(maxGoalFolders)
        var goals: [KnowledgeSummary] = []
        for name in names {
            let folder = directory + "/" + name
            guard isRegular(folder, type: S_IFDIR), isRegular(folder + "/STATE.md", type: S_IFREG),
                  var summary = summary(root: root, knowledge: knowledge + "/" + name)
            else { continue }
            summary.slug = name
            summary.lastRecord = summary.lastRecord.map { name + "/" + $0 }
            goals.append(summary)
        }
        goals.sort(by: KnowledgeSummary.isOrderedBefore)
        return goals
    }

    /// The summary of one goal folder, `<root>/<knowledge>`, or nil when
    /// the directory is missing or refused. Every file goes through the
    /// jailed read, so a symlinked `STATE.md` leaves its fields absent.
    static func summary(root: String, knowledge: String) -> KnowledgeSummary? {
        guard let directory = try? jailedDirectory(root: root, knowledge: knowledge) else { return nil }
        let text = { (path: String) -> String? in
            guard let payload = try? read(root: root, knowledge: knowledge, path: path) else { return nil }
            return String(data: payload.data, encoding: .utf8)
        }
        // A symlinked `rounds/` would list its target's names; refuse it like
        // every other component, and treat it as no records.
        var roundNames: [String] = []
        if (try? refuseSymlink(directory + "/rounds")) != nil {
            roundNames = (try? FileManager.default.contentsOfDirectory(atPath: directory + "/rounds")) ?? []
        }
        // The record is read by the name the listing gave, so `rounds/7.md`
        // is the file the summary describes and the file the card links to.
        let record = KnowledgeSummary.latestRecordName(roundNames)
        return KnowledgeSummary.parse(
            state: text("STATE.md"),
            goal: text("goal.md"),
            latestRecord: record,
            latestRound: record.flatMap { text("rounds/" + $0) }
        )
    }

    // MARK: - the jail

    /// `<root>/<knowledge>` when the root and every component under it are
    /// real directories. A missing directory is `notFound`; a symlink is
    /// `refused`. The root is checked too: a registered root is a `realpath`
    /// when it exists at load time, and a symlink put there later must not
    /// be followed by the listing.
    static func jailedDirectory(root: String, knowledge: String) throws -> String {
        guard ProjectStore.isValidKnowledge(knowledge) else { throw Failure.badPath }
        try refuseSymlink(root)
        var current = root
        for segment in knowledge.split(separator: "/") {
            current += "/" + segment
            try refuseSymlink(current)
        }
        var info = stat()
        guard stat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.notFound }
        return current
    }

    /// `name` opened relative to the descriptor `directory`, never through a
    /// symlink. A directory component is opened `O_DIRECTORY`; the file is
    /// opened `O_NONBLOCK`, so a FIFO does not wait for a writer. A symlink
    /// at `name` is `refused`; anything else that fails to open is `notFound`.
    private static func openComponent(at directory: Int32, _ name: String, directory isDirectory: Bool) throws -> Int32 {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isDirectory ? O_DIRECTORY : O_NONBLOCK)
        let fd = openat(directory, name, flags)
        if fd >= 0 { return fd }
        // The kernel refused it; `lstat` only names the reason.
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw Failure.refused
        }
        throw Failure.notFound
    }

    /// True when `lstat` sees `type` at `path`: a symlink is never it.
    private static func isRegular(_ path: String, type: mode_t) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == type
    }

    /// `refused` for a symlink at `path`; `notFound` when nothing is there.
    private static func refuseSymlink(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Failure.notFound }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw Failure.refused }
    }
}
