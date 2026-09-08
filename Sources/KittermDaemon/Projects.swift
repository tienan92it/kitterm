#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers

/// A project the user registered in `~/.kitterm/projects.json`.
public struct Project: Sendable, Equatable {
    /// A slug of the root's folder name, unique in the file.
    public let id: String
    public let name: String
    /// Absolute, symlink-resolved root directory.
    public let root: String
    /// The knowledge directory, relative to `root`. `docs/goals` by default.
    public let knowledge: String

    public init(id: String, name: String, root: String, knowledge: String = ProjectStore.defaultKnowledge) {
        self.id = id
        self.name = name
        self.root = root
        self.knowledge = knowledge
    }
}

/// The project a session belongs to, as the fleet view reports it: a
/// registered project, a repository discovered by its `.git`, or the id a
/// `project:<id>` label named.
public struct ResolvedProject: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Nil only when a `project:` label names an id the file does not hold
    /// and the cwd is outside every repository.
    public let root: String?
    public let registered: Bool
    public let knowledge: String

    public init(id: String, name: String, root: String?, registered: Bool, knowledge: String) {
        self.id = id
        self.name = name
        self.root = root
        self.registered = registered
        self.knowledge = knowledge
    }

    init(_ project: Project) {
        self.init(
            id: project.id, name: project.name, root: project.root,
            registered: true, knowledge: project.knowledge
        )
    }

    /// The `project` field of a session row: `{id, name, root, registered}`.
    public var rowJSON: [String: Any] {
        var item: [String: Any] = ["id": id, "name": name, "registered": registered]
        if let root { item["root"] = root }
        return item
    }
}

/// Registered projects plus the resolution of a working directory to a
/// project (`~/.kitterm/projects.json`, `kitterm project add|list|remove`).
///
/// Resolution order: the longest registered root that is a prefix of the
/// cwd; else the nearest ancestor that holds `.git`, following a `gitdir:`
/// file one level so a worktree resolves to its main checkout; else nil.
///
/// The file is reloaded when its mtime changes, like `tokens.json`, so
/// `kitterm project add` reaches a running daemon. Lock-guarded, because
/// the cwd poll of every session and the API handler call `resolve` from
/// their own event loops.
public final class ProjectStore: @unchecked Sendable {
    public static let shared = ProjectStore()
    public static let formatVersion = 1
    public static let defaultKnowledge = "docs/goals"
    /// How many parent directories the `.git` walk visits before it gives up.
    public static let maxWalkDepth = 32
    public static let maxIDLength = 64
    public static let maxNameLength = 128
    /// Distinct discovered roots the store remembers, so their ids stay
    /// unique within one daemon run.
    static let maxDiscovered = 512

    private let lock = NIOLock()
    private let fixedURL: URL?
    private var loadedURL: URL?
    private var loadedAt: Date?
    private var projects: [Project] = []
    /// Discovered roots and the id each was given, so two repositories with
    /// the same folder name do not share an id within a run.
    private var discovered: [String: String] = [:]
    private var generationStorage = 0

    /// `url` nil reads `DaemonPaths.projectsFile` at each check, so the
    /// shared store follows `KITTERM_STATE_DIR`.
    public init(url: URL? = nil) {
        self.fixedURL = url
    }

    private var url: URL { fixedURL ?? DaemonPaths.projectsFile }

    /// Counts the reloads that changed the registered set. A session caches
    /// its project with the generation it was resolved under and resolves
    /// again when either the cwd or the generation moved.
    public var generation: Int {
        lock.withLock {
            reloadIfChangedLocked()
            return generationStorage
        }
    }

    /// The registered projects, in file order.
    public func registered() -> [Project] {
        lock.withLock {
            reloadIfChangedLocked()
            return projects
        }
    }

    public func registered(id: String) -> Project? {
        registered().first { $0.id == id }
    }

    /// The project for a working directory. See the type comment for the
    /// order. The `.git` walk is a bounded run of `stat` calls plus one
    /// small file read for a worktree; it runs with the lock released.
    public func resolve(cwd: String) -> ResolvedProject? {
        let cwd = Self.normalize(cwd)
        let projects = registered()
        if let best = projects.filter({ Self.isPrefix($0.root, of: cwd) }).max(by: { $0.root.count < $1.root.count }) {
            return ResolvedProject(best)
        }
        guard let root = Self.gitRoot(from: cwd) else { return nil }
        // A worktree kept outside a registered root still belongs to it.
        if let project = projects.first(where: { $0.root == root }) {
            return ResolvedProject(project)
        }
        let name = URL(fileURLWithPath: root).lastPathComponent
        let id: String = lock.withLock {
            if let known = discovered[root] { return known }
            let taken = Set(projects.map(\.id)).union(discovered.values)
            let id = Self.uniqueID(for: name, taken: taken)
            if discovered.count < Self.maxDiscovered { discovered[root] = id }
            return id
        }
        return ResolvedProject(id: id, name: name, root: root, registered: false, knowledge: Self.defaultKnowledge)
    }

    /// The project a session row reports: a `project:<id>` label overrides
    /// the cwd resolution. A registered id carries the registered project; an
    /// unknown id is reported as itself, unregistered, with the resolved root
    /// when there is one. A label value that is not a valid id is ignored.
    public func project(labels: [String: String], resolved: ResolvedProject?) -> ResolvedProject? {
        guard let id = labels[SessionLabels.projectKey], Self.isValidID(id) else { return resolved }
        if let project = registered(id: id) { return ResolvedProject(project) }
        return ResolvedProject(id: id, name: id, root: resolved?.root, registered: false, knowledge: Self.defaultKnowledge)
    }

    /// The project of an archive record (`archive.json`): its labels, then
    /// its cwd.
    public func project(forArchive record: [String: Any]) -> ResolvedProject? {
        let labels = record["labels"] as? [String: String] ?? [:]
        let resolved = (record["cwd"] as? String).flatMap { resolve(cwd: $0) }
        return project(labels: labels, resolved: resolved)
    }

    private func reloadIfChangedLocked() {
        let url = self.url
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard mtime != loadedAt || url != loadedURL else { return }
        loadedAt = mtime
        loadedURL = url
        projects = mtime == nil ? [] : Self.load(from: url)
        discovered = [:]
        generationStorage += 1
    }

    // MARK: - ids

    private static let idAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

    /// A project id: lowercase letters, digits and `-`, no leading or
    /// trailing `-`, at most `maxIDLength` characters.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maxIDLength && id.allSatisfy(idAllowed.contains)
            && !id.hasPrefix("-") && !id.hasSuffix("-")
    }

    /// The slug of a folder name: lowercase, every run of other characters
    /// becomes one `-`. An empty result reads `project`.
    public static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if out.isEmpty { return "project" }
        return String(out.prefix(maxIDLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The slug, with `-2`, `-3`, … appended while it is taken.
    public static func uniqueID(for name: String, taken: Set<String>) -> String {
        let base = slug(name)
        guard taken.contains(base) else { return base }
        var n = 2
        while true {
            let suffix = "-\(n)"
            let candidate = String(base.prefix(maxIDLength - suffix.count)) + suffix
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: - paths

    /// Absolute and symlink-resolved, no trailing `/`. The kernel reports a
    /// shell's cwd as a real path (`/private/var/…` on macOS), so a
    /// registered root must take that form or never match; `realpath(3)`
    /// gives it, where Foundation's resolution keeps `/var/…`. A path that
    /// does not exist is standardized only.
    public static func canonicalRoot(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(standardized, &buffer) != nil else { return normalize(standardized) }
        return normalize(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Is `root` the cwd itself or one of its ancestors?
    static func isPrefix(_ root: String, of cwd: String) -> Bool {
        if root == cwd { return true }
        if root == "/" { return cwd.hasPrefix("/") }
        return cwd.hasPrefix(root + "/")
    }

    /// The nearest ancestor of `cwd` (itself included) that holds `.git`,
    /// bounded at `maxWalkDepth` levels. A `.git` file with a `gitdir:` line
    /// is followed one level: `<main>/.git/worktrees/<name>` resolves to
    /// `<main>`. Nil outside every repository.
    static func gitRoot(from cwd: String) -> String? {
        var dir = normalize(cwd)
        for _ in 0..<maxWalkDepth {
            let dotGit = (dir == "/" ? "" : dir) + "/.git"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dir }
                if let target = gitdirTarget(file: dotGit, relativeTo: dir),
                   let main = mainCheckout(ofGitDir: target) {
                    return main
                }
                return dir
            }
            if dir == "/" { return nil }
            dir = URL(fileURLWithPath: dir).deletingLastPathComponent().path
            dir = normalize(dir)
        }
        return nil
    }

    /// The path after `gitdir:` in a `.git` file, made absolute against the
    /// directory that holds the file. Nil for any other content.
    private static func gitdirTarget(file: String, relativeTo dir: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size]) as? Int, size <= 4096,
              let text = try? String(contentsOfFile: file, encoding: .utf8)
        else { return nil }
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard line.hasPrefix("gitdir:") else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        // Made real like a registered root, so a worktree of a registered
        // project matches its root byte for byte.
        if raw.hasPrefix("/") { return canonicalRoot(raw) }
        return canonicalRoot(dir + "/" + raw)
    }

    /// `<root>/.git/worktrees/<name>` → `<root>`; `<root>/.git` → `<root>`.
    /// Nil when the path holds no `.git` component.
    static func mainCheckout(ofGitDir path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.lastIndex(of: ".git"), index > 0 else { return nil }
        return "/" + components[0..<index].joined(separator: "/")
    }

    // MARK: - file

    /// A relative directory with no `..` component.
    public static func isValidKnowledge(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.count <= 256 else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0.isEmpty }
    }

    public static func load(from url: URL = DaemonPaths.projectsFile) -> [Project] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["projects"] as? [[String: Any]]
        else {
            warn("expected {\"version\": 1, \"projects\": [...]} — file ignored")
            return []
        }
        guard (root["version"] as? Int) == formatVersion else {
            warn("unknown version \(root["version"] ?? "missing") — file ignored")
            return []
        }
        var ids = Set<String>()
        var roots = Set<String>()
        var projects: [Project] = []
        for entry in entries {
            guard let id = entry["id"] as? String, isValidID(id),
                  let rawRoot = entry["root"] as? String, rawRoot.hasPrefix("/")
            else {
                warn("entry without a valid id and absolute root — skipped")
                continue
            }
            let root = canonicalRoot(rawRoot)
            let name = (entry["name"] as? String).flatMap { $0.isEmpty || $0.count > maxNameLength ? nil : $0 }
                ?? URL(fileURLWithPath: root).lastPathComponent
            let knowledge = entry["knowledge"] as? String ?? defaultKnowledge
            guard isValidKnowledge(knowledge) else {
                warn("project \(id): knowledge must be a relative directory without `..` — skipped")
                continue
            }
            guard ids.insert(id).inserted, roots.insert(root).inserted else {
                warn("project \(id): duplicate id or root — skipped")
                continue
            }
            projects.append(Project(id: id, name: name, root: root, knowledge: knowledge))
        }
        return projects
    }

    public static func save(_ projects: [Project], to url: URL = DaemonPaths.projectsFile) throws {
        let entries: [[String: Any]] = projects.map { project in
            [
                "id": project.id,
                "name": project.name,
                "root": project.root,
                "knowledge": project.knowledge,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["version": formatVersion, "projects": entries],
            options: [.prettyPrinted, .sortedKeys]
        )
        try DaemonPaths.ensureStateDirectory()
        try data.write(to: url, options: .atomic)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("kitterm: projects.json: \(message)\n".utf8))
    }
}
