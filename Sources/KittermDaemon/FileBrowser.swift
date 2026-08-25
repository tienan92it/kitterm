import Foundation
import KittermProtocol

/// Directory listings, so a caller can pick a file or folder and hand its real
/// path to whatever is running in the session.
///
/// No copy and no second source of truth: the daemon runs on the machine the
/// files are on, so the path it reports is the one the agent should edit. A
/// dropped file cannot do this — browsers never reveal where a file came from —
/// so dropping stays for files that are not on this machine.
///
/// There is no allowlist here on purpose. Anyone who can reach this can already
/// type `ls` into the session, and the daemon runs as the user, so the OS is
/// what decides what is readable. The one real limit is the grade: watch-only
/// callers cannot type, so they must not be able to browse either, and that is
/// enforced at the route.
enum FileBrowser {
    struct Entry: Sendable {
        let name: String
        let isDirectory: Bool
        let size: Int64?
    }

    struct Listing: Sendable {
        let path: String
        let parent: String?
        let entries: [Entry]
    }

    enum BrowseError: Error {
        case notADirectory
        case unreadable(String)
    }

    /// Resolve what the caller asked for into a real directory: `~` expanded,
    /// relative paths taken from `base`, symlinks followed to where they land.
    static func resolve(_ requested: String?, base: String?) -> URL {
        let fallback = base ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard var path = requested, !path.isEmpty else {
            return URL(fileURLWithPath: fallback).standardizedFileURL
        }
        if path == "~" || path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            path = home + path.dropFirst(1)
        }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: fallback).appendingPathComponent(path)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Directories first, then files, each alphabetically — the order that makes
    /// a list scannable rather than the order the filesystem happens to give.
    static func list(_ directory: URL, includeHidden: Bool = false) throws -> Listing {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw BrowseError.notADirectory
        }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
        } catch {
            throw BrowseError.unreadable("\(error.localizedDescription)")
        }

        let entries = contents
            .map { url -> Entry in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values?.isDirectory ?? false
                return Entry(
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : values?.fileSize.map(Int64.init)
                )
            }
            .sorted {
                $0.isDirectory == $1.isDirectory
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.isDirectory
            }
            .prefix(KittermConstants.maxDirectoryEntries)

        let parent = directory.path == "/" ? nil : directory.deletingLastPathComponent().path
        return Listing(path: directory.path, parent: parent, entries: Array(entries))
    }

    /// What a single path names, if anything.
    struct Stat: Sendable {
        /// Exactly what the caller asked about, so a reply can be matched to a
        /// request without the caller re-deriving our resolution.
        let requested: String
        let exists: Bool
        let isDirectory: Bool
        /// The resolved absolute path, so a later read need not resolve twice.
        let resolved: String
    }

    /// Answer "does this name anything" for several paths at once.
    ///
    /// The client asks about every path-shaped token on a screen of output, and a
    /// screen can name files in many directories. Listing each parent to find out
    /// would send directory contents across the wire merely to underline a word;
    /// this sends back one line per question instead.
    ///
    /// Resolution is `resolve`'s, so `~`, relative-to-cwd and symlinks behave
    /// exactly as they do for browsing. A path that resolves to nothing is not an
    /// error: "no" is the answer, and the client leaves the text plain.
    static func stat(_ requested: [String], base: String?) -> [Stat] {
        requested.map { candidate in
            let url = resolve(candidate, base: base)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return Stat(
                requested: candidate,
                exists: exists,
                isDirectory: exists && isDirectory.boolValue,
                resolved: url.path
            )
        }
    }
}
