#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import KittermProtocol

/// The save behind `PUT /api/files/content`: the first HTTP route that writes
/// outside `~/.kitterm/` (ADR 0005, phase 2a). It replaces the bytes of one
/// existing regular file inside a project, and nothing else.
///
/// The jail is the project root. The walk opens the root by its path, then
/// every component of the file's path relative to it with `openat` and
/// `O_NOFOLLOW` (`O_NOFOLLOW_ANY` too on Darwin), so a symlink anywhere in
/// the chain is refused rather than followed, and the file's type, link
/// count and mode come from `fstat` on the descriptor the bytes are read
/// from and the rename replaces. The checks and the write see one inode.
///
/// `.git` is refused twice: by name, case-insensitively, at every depth
/// (APFS is case-insensitive, so `.GIT` opens `.git`), and by the
/// `(st_dev, st_ino)` of the root's own `.git` against every directory the
/// walk opens, so no spelling the filesystem accepts reaches the object
/// store or the hooks.
///
/// The save is atomic: a temporary file created `O_CREAT|O_EXCL|O_NOFOLLOW`
/// in the target's directory, written, synced, given the target's mode, then
/// renamed over the target. The rename replaces the inode, which is why a
/// hard-linked file is refused: a save would silently split the link.
///
/// The precondition is the content. The client holds the `ETag` the read
/// gave it, the SHA-256 of the whole file, and sends it as `If-Match`; a
/// file an agent changed in a pane since answers 412 with the current tag.
/// The hash is checked again after the temporary file is written and before
/// the rename, and the whole save runs on one serial queue, so two saves
/// with the same tag cannot both win.
public enum FileEdit {
    /// The read cap, so a save never writes more than a read can show: the
    /// page refuses to edit a truncated file.
    public static let maxBytes = KittermConstants.apiCommandOutputMaxBytes

    /// Every save and every audit line, in order, off the event loop.
    static let queue = DispatchQueue(label: "kitterm.edit")

    /// The temporary file's prefix, so a leftover is recognisable.
    static let temporaryPrefix = ".kitterm-save-"

    public enum Failure: Error, Equatable {
        /// The path is under no project root.
        case outsideProject
        /// A symlink in the chain, the target included.
        case symlink
        /// A component is `.git`, by name or by inode.
        case gitDirectory
        /// Nothing at the path, or a parent is not a directory.
        case notFound
        /// A FIFO, a device, a socket, a directory.
        case notRegular
        /// `st_nlink` is over one.
        case hardLinked
        /// `If-Match` is not the current content; `current` is the current
        /// tag, nil when the target was replaced with something unreadable
        /// between the check and the rename.
        case preconditionFailed(current: String?)
        /// A syscall failed; the text names it.
        case ioFailed(String)
    }

    public struct Saved: Sendable, Equatable {
        /// The tag of the bytes written.
        public let etag: String
        public let bytes: Int
        /// The tag of the bytes replaced.
        public let previousEtag: String
    }

    /// `"sha256:<hex>"`, quoted, the shape of the `ETag` header and of
    /// `If-Match`.
    public static func etag(_ data: Data) -> String {
        "\"" + hashName(data) + "\""
    }

    /// `sha256:<hex>` of `data`, bare: what the audit log writes.
    public static func hashName(_ data: Data) -> String {
        hashName(SHA256.hash(data: data))
    }

    /// The bare `sha256:<hex>` of a quoted tag.
    public static func bare(_ etag: String) -> String {
        etag.hasPrefix("\"") && etag.hasSuffix("\"") && etag.count >= 2
            ? String(etag.dropFirst().dropLast()) : etag
    }

    /// Whether an `If-Match` header names `etag`. One tag, quoted or bare;
    /// a list or a weak tag matches nothing, because the save is exact.
    public static func matches(ifMatch header: String, etag: String) -> Bool {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("W/") else { return false }
        return quoted(trimmed) == etag
    }

    /// The file `path` resolved with no symlink followed: `~` expanded, a
    /// relative path taken from `base`, `.` and `..` removed lexically. The
    /// content route follows symlinks when it resolves; this one must not,
    /// because the walk is what judges every link. Lexical by hand:
    /// `URL.standardizedFileURL` rewrites `/private/var` to `/var` when the
    /// file exists, which is a symlink's business, not this function's.
    public static func resolve(_ requested: String, base: String?) -> String {
        var path = requested
        if path == "~" || path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst(1)
        }
        let fallback = base ?? FileManager.default.homeDirectoryForCurrentUser.path
        if !path.hasPrefix("/") { path = fallback + "/" + path }
        var parts: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(segment)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The project root that holds the resolved `path`, and the components
    /// of `path` below it.
    public struct Jail: Sendable, Equatable {
        public let root: String
        public let components: [String]
    }

    /// Where `path` sits: the project of its real parent directory (the
    /// nearest checkout or registered root, the cwd rule of `ProjectStore`),
    /// then the longest ancestor of the lexical path whose `realpath` is
    /// that root, the shortest one. A symlink above the root is allowed,
    /// because the root is the trusted boundary and its stored path is
    /// already a `realpath` (`/tmp/x/a.ts` saves into the project at
    /// `/private/tmp/x`); every component below the root is the walk's,
    /// where a symlink is refused.
    /// `notFound` when the parent directory does not exist; `outsideProject`
    /// when no project holds it or no ancestor is the root.
    public static func jail(for path: String, projects: ProjectStore) throws -> Jail {
        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = realPath(parent) else { throw Failure.notFound }
        guard let root = projects.resolve(cwd: realParent)?.root else { throw Failure.outsideProject }
        // The shortest such ancestor, not the first: a symlink below the
        // root that points back at the root has the root's real path too,
        // and taking it would put the link above the walk. Scanning to `/`
        // leaves it in the components, where the walk refuses it.
        var ancestor = parent
        var match: String?
        while true {
            if realPath(ancestor) == root { match = ancestor }
            if ancestor == "/" || ancestor.isEmpty { break }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        guard let match, let parts = components(of: path, under: match) else { throw Failure.outsideProject }
        return Jail(root: root, components: parts)
    }

    /// Where a file sits, for the editor page: the project that would jail
    /// its save, and its path under that root.
    public struct Located: Sendable, Equatable {
        /// The project's id, name and real root, as `ProjectStore` names them.
        public let id: String
        public let name: String
        public let root: String
        /// The components below the root, joined: `Web/terminal/src/md.ts`.
        public let relative: String
    }

    /// The outcome of locating the lexical `path`: `project` is nil for a
    /// file under no project, and the whole answer is nil when the parent
    /// directory does not exist. Blocking (`realpath`, the `.git` walk):
    /// the caller runs it off the loop.
    public struct Location: Sendable, Equatable {
        public let project: Located?
    }

    /// `jail`'s resolution with the project's identity kept, so the page
    /// can name the project and draw its tree from the root. The same two
    /// steps as `jail`, so the page and the save never disagree on where a
    /// file is.
    public static func locate(_ path: String, projects: ProjectStore) -> Location? {
        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = realPath(parent) else { return nil }
        guard let project = projects.resolve(cwd: realParent), project.root != nil,
              let jail = try? jail(for: path, projects: projects)
        else { return Location(project: nil) }
        return Location(project: Located(
            id: project.id, name: project.name, root: jail.root,
            relative: jail.components.joined(separator: "/")
        ))
    }

    /// `realpath(3)`, or nil when the path names nothing.
    static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return ProjectStore.normalize(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    /// The components of `path` under `root`, or nil when `path` is the
    /// root itself or not under it.
    static func components(of path: String, under root: String) -> [String]? {
        let root = ProjectStore.normalize(root)
        guard root != path, ProjectStore.isPrefix(root, of: path) else { return nil }
        let rest = root == "/" ? path.dropFirst() : path.dropFirst(root.count + 1)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts
    }

    /// Replace the bytes of the regular file `components` name under the
    /// project root `root` with `data`, when `ifMatch` names its current
    /// content. Blocking: the caller runs it on `queue`.
    public static func save(root: String, components parts: [String], ifMatch: String, data: Data) throws -> Saved {
        guard !parts.isEmpty else { throw Failure.outsideProject }
        var directory = try openDirectory(at: AT_FDCWD, root)
        defer { close(directory) }
        let gitIdentity = identity(at: directory, ".git")

        for segment in parts.dropLast() {
            guard !isGitName(segment) else { throw Failure.gitDirectory }
            let next = try openComponent(at: directory, segment, directory: true)
            if let gitIdentity, identity(of: next) == gitIdentity {
                close(next)
                throw Failure.gitDirectory
            }
            close(directory)
            directory = next
        }

        let name = parts[parts.count - 1]
        guard !isGitName(name) else { throw Failure.gitDirectory }
        let file = try openComponent(at: directory, name, directory: false)
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw Failure.ioFailed("fstat: \(errnoText())") }
        if let gitIdentity, Identity(info) == gitIdentity { throw Failure.gitDirectory }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.notRegular }
        guard Int(info.st_nlink) == 1 else { throw Failure.hardLinked }
        let current = try hash(of: file)
        guard matches(ifMatch: ifMatch, etag: current) else {
            throw Failure.preconditionFailed(current: current)
        }

        let temporary = temporaryPrefix + randomSuffix()
        let scratch = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | noFollowFlags, 0o600)
        guard scratch >= 0 else { throw Failure.ioFailed("open temporary: \(errnoText())") }
        var kept = false
        defer {
            close(scratch)
            if !kept { unlinkat(directory, temporary, 0) }
        }
        try writeAll(data, to: scratch)
        try sync(scratch)
        guard fchmod(scratch, mode_t(info.st_mode & 0o7777)) == 0 else {
            throw Failure.ioFailed("fchmod: \(errnoText())")
        }

        // The target may have changed since the hash: an agent writing in a
        // pane, or a save on another path to the same file. Same inode and
        // same bytes, or the precondition no longer holds.
        var now = stat()
        guard fstatat(directory, name, &now, AT_SYMLINK_NOFOLLOW) == 0, Identity(now) == Identity(info) else {
            throw Failure.preconditionFailed(current: currentTag(at: directory, name))
        }
        let again = try hash(of: file)
        guard again == current else { throw Failure.preconditionFailed(current: again) }

        try rename(at: directory, from: temporary, to: name)
        kept = true
        return Saved(etag: etag(data), bytes: data.count, previousEtag: current)
    }

    // MARK: - the walk

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    private static func identity(of descriptor: Int32) -> Identity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return Identity(info)
    }

    private static func identity(at directory: Int32, _ name: String) -> Identity? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Identity(info)
    }

    static func isGitName(_ segment: String) -> Bool {
        segment.lowercased() == ".git"
    }

    /// Every open here: never through a symlink. On Darwin `O_NOFOLLOW_ANY`
    /// alone, which refuses a symlink in any component the kernel resolves,
    /// the last one included; with `O_NOFOLLOW` beside it the kernel answers
    /// `EINVAL` (measured on macOS 26.6.2, `code-editor` round 3). On Linux
    /// `O_NOFOLLOW`, and every component is one `openat` away, so the last
    /// is the only one the kernel could follow.
    private static var noFollowFlags: Int32 {
        #if canImport(Darwin)
        return O_NOFOLLOW_ANY | O_CLOEXEC
        #else
        return O_NOFOLLOW | O_CLOEXEC
        #endif
    }

    /// The directory at `path` relative to `at`: the root, by its full
    /// path, so a root that became a symlink is refused too.
    private static func openDirectory(at base: Int32, _ path: String) throws -> Int32 {
        let fd = openat(base, path, O_RDONLY | O_DIRECTORY | noFollowFlags)
        guard fd >= 0 else {
            var info = stat()
            if fstatat(base, path, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw Failure.symlink
            }
            throw Failure.notFound
        }
        return fd
    }

    /// `name` opened relative to `directory`, never through a symlink. A
    /// directory component is opened `O_DIRECTORY`; the file `O_NONBLOCK`,
    /// so a FIFO does not wait for a writer and `fstat` refuses it.
    private static func openComponent(at directory: Int32, _ name: String, directory isDirectory: Bool) throws -> Int32 {
        let flags = (isDirectory ? O_RDONLY | O_DIRECTORY : O_RDONLY | O_NONBLOCK) | noFollowFlags
        let fd = openat(directory, name, flags)
        if fd >= 0 { return fd }
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw Failure.symlink
        }
        throw Failure.notFound
    }

    // MARK: - the bytes

    /// The tag of the whole file open at `descriptor`, read from its start,
    /// in 64 KiB pieces: the target may be larger than the save cap, and
    /// its tag is still the honest answer to a stale `If-Match`.
    private static func hash(of descriptor: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress, raw.count, offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.ioFailed("read: \(errnoText())")
            }
            if count == 0 { break }
            hasher.update(data: buffer[0..<count])
            offset += off_t(count)
        }
        return "\"" + hashName(hasher.finalize()) + "\""
    }

    /// The tag of whatever regular file `name` is now, for a 412 after the
    /// target was replaced; nil when nothing readable is there.
    private static func currentTag(at directory: Int32, _ name: String) -> String? {
        guard let fd = try? openComponent(at: directory, name, directory: false) else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return try? hash(of: fd)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var written = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while written < raw.count {
                let count = systemWrite(descriptor, base + written, raw.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure.ioFailed("write: \(errnoText())")
                }
                written += count
            }
        }
    }

    /// The bytes onto the disk, not only into the cache: `F_FULLFSYNC` on
    /// Darwin, where `fsync` alone stops at the drive's cache.
    private static func sync(_ descriptor: Int32) throws {
        #if canImport(Darwin)
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        #endif
        guard fsync(descriptor) == 0 else { throw Failure.ioFailed("fsync: \(errnoText())") }
    }

    /// `from` over `to`, both names in the directory open at `directory`.
    /// On Darwin `renameatx_np` with `RENAME_NOFOLLOW_ANY`, with the plain
    /// `renameat` as the fallback where the kernel refuses the flag; a
    /// rename never follows its last component on either, so a symlink at
    /// `to` is replaced, not written through.
    private static func rename(at directory: Int32, from: String, to: String) throws {
        #if canImport(Darwin)
        if renameatx_np(directory, from, directory, to, UInt32(RENAME_NOFOLLOW_ANY)) == 0 { return }
        guard errno == EINVAL || errno == ENOTSUP else {
            throw Failure.ioFailed("rename: \(errnoText())")
        }
        #endif
        guard renameat(directory, from, directory, to) == 0 else {
            throw Failure.ioFailed("rename: \(errnoText())")
        }
    }

    private static func hashName(_ digest: SHA256Digest) -> String {
        "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func quoted(_ tag: String) -> String {
        tag.hasPrefix("\"") && tag.hasSuffix("\"") && tag.count >= 2 ? tag : "\"" + tag + "\""
    }

    private static func randomSuffix() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
