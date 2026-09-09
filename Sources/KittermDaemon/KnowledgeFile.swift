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
/// The summary opens the knowledge directory once and each goal folder
/// once, and reads every file and lists `rounds/` relative to that
/// descriptor. Files are capped at `maxBytes`. Every function here touches the disk, so
/// the routes call them off the loop. `kitterm goal list` calls `summaries`
/// too, so the CLI and the route list the same folders.
///
/// Accepted: a hard link under the knowledge directory to a file elsewhere
/// on the volume is served. The linker needs write access to the project
/// tree, and that writer can copy the file into the directory outright.
public enum KnowledgeFile {
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
        guard isValidRelative(path) else { throw Failure.badPath }
        let segments = path.split(separator: "/").map(String.init)
        var current = try openDirectory(root: root, knowledge: knowledge)
        defer { close(current) }
        for segment in segments.dropLast() {
            let next = try openComponent(at: current, segment, directory: true)
            close(current)
            current = next
        }
        let file = try openComponent(at: current, segments[segments.count - 1], directory: false)
        defer { close(file) }
        return Payload(data: try contents(of: file), contentType: contentType)
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
    public static func summaries(root: String, knowledge: String) -> [KnowledgeSummary]? {
        guard let directory = try? openDirectory(root: root, knowledge: knowledge) else { return nil }
        defer { close(directory) }
        let names = entries(of: directory).filter(ProjectStore.isValidID).sorted().prefix(maxGoalFolders)
        var goals: [KnowledgeSummary] = []
        for name in names {
            // A symlinked child fails `O_NOFOLLOW`; a file fails `O_DIRECTORY`.
            guard let folder = try? openComponent(at: directory, name, directory: true) else { continue }
            defer { close(folder) }
            guard var summary = summary(folder: folder) else { continue }
            summary.slug = name
            summary.lastRecord = summary.lastRecord.map { name + "/" + $0 }
            goals.append(summary)
        }
        goals.sort(by: KnowledgeSummary.isOrderedBefore)
        return goals
    }

    /// The summary of one goal folder, `<root>/<knowledge>`, or nil when
    /// the folder is missing or refused, or holds no regular `STATE.md`.
    static func summary(root: String, knowledge: String) -> KnowledgeSummary? {
        guard let folder = try? openDirectory(root: root, knowledge: knowledge) else { return nil }
        defer { close(folder) }
        return summary(folder: folder)
    }

    /// The summary of the goal folder open at `folder`, or nil when
    /// `STATE.md` is not a regular file there (missing, a symlink, a FIFO),
    /// so the folder is not a goal. Every file is opened relative to
    /// `folder`, never by a walk from the root: per goal folder the cost is
    /// the folder's own open plus at most four `openat` (`STATE.md`,
    /// `goal.md`, `rounds/`, the latest record), three `fstat`, three reads,
    /// and one `readdir` of `rounds/`. A `STATE.md` over `maxBytes` is a
    /// goal with no fields, the same as a record over the cap.
    private static func summary(folder: Int32) -> KnowledgeSummary? {
        let state: String?
        do { state = try text(at: folder, "STATE.md") } catch { return nil }
        let goal = (try? text(at: folder, "goal.md")) ?? nil
        // A symlinked `rounds/` fails `O_NOFOLLOW` like every other
        // component and reads as no records. The record is read by the name
        // the listing gave, so `rounds/7.md` is the file the summary
        // describes and the file the card links to.
        var record: String?
        var latestRound: String?
        if let rounds = try? openComponent(at: folder, "rounds", directory: true) {
            defer { close(rounds) }
            record = KnowledgeSummary.latestRecordName(entries(of: rounds))
            latestRound = record.flatMap { (try? text(at: rounds, $0)) ?? nil }
        }
        return KnowledgeSummary.parse(state: state, goal: goal, latestRecord: record, latestRound: latestRound)
    }

    // MARK: - the jail

    /// `<root>/<knowledge>` open as a directory descriptor: the root, then
    /// every component of `knowledge`, each opened `O_NOFOLLOW` relative to
    /// the one before, so a symlink anywhere in the chain is `refused`, the
    /// root included (a registered root is a `realpath` when it exists at
    /// load time, and a symlink put there later must not be followed). A
    /// missing directory is `notFound`. The caller closes the descriptor.
    private static func openDirectory(root: String, knowledge: String) throws -> Int32 {
        guard ProjectStore.isValidKnowledge(knowledge) else { throw Failure.badPath }
        var current = try openComponent(at: AT_FDCWD, root, directory: true)
        for segment in knowledge.split(separator: "/") {
            let next: Int32
            do {
                next = try openComponent(at: current, String(segment), directory: true)
            } catch {
                close(current)
                throw error
            }
            close(current)
            current = next
        }
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

    /// The bytes of the regular file open at `file`: `notFound` for any
    /// other type, `tooLarge` past `maxBytes`. The size and the type come
    /// from `fstat` on the descriptor the bytes are read from.
    private static func contents(of file: Int32) throws -> Data {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw Failure.notFound }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.notFound }
        guard info.st_size <= maxBytes else { throw Failure.tooLarge }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return data
    }

    /// The text of the regular file `name` under the descriptor `directory`.
    /// Throws when nothing regular is there; nil when the file is over
    /// `maxBytes` or not UTF-8, which leaves the summary's fields absent.
    private static func text(at directory: Int32, _ name: String) throws -> String? {
        let file = try openComponent(at: directory, name, directory: false)
        defer { close(file) }
        do {
            return String(data: try contents(of: file), encoding: .utf8)
        } catch Failure.tooLarge {
            return nil
        }
    }

    /// The names in the directory open at `directory`, `.` and `..` left
    /// out, in no order. Read through a duplicate of the descriptor, so the
    /// caller's stays open for the `openat` calls that follow.
    private static func entries(of directory: Int32) -> [String] {
        let copy = dup(directory)
        guard copy >= 0 else { return [] }
        guard let stream = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
