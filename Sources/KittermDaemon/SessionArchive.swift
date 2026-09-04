import Foundation

/// Cold storage for a finished session: the evidence of what happened, kept on
/// disk after the shell is gone. This is the honest scope of the feature —
/// kitterm can prove what a session did (its commands, exit codes, and
/// output), it cannot restore what a session *was* (a live process, its memory,
/// its open files). "Resume" is therefore a convention, not a restore: a
/// foreman spawns a new session with the archived name and cwd and a
/// `resumed-from:<id>` label, and reads the archive for context.
///
/// One directory per archived session under `~/.kitterm/archive/<id>/`:
/// `archive.json` (metadata + commands + marks) and `output.log` (the captured
/// bytes). The format is versioned — `"version": 1` — because it is a durable
/// on-disk contract, the same discipline the live-upgrade handoff uses.
public enum SessionArchive {
    /// File I/O runs here, never on the event loop — the `SessionLogStore`
    /// pattern.
    private static let queue = DispatchQueue(label: "kitterm.archive")

    public static let formatVersion = 1

    /// Everything an archive keeps about a session. `commands` and `marks` are
    /// the same JSON shapes the live API serves, so a reader of an archive and
    /// a reader of a live session see one format.
    public struct Record {
        public let id: UUID
        public let name: String?
        public let note: String?
        public let labels: [String: String]
        public let cwd: String
        public let shell: String
        public let profile: String?
        public let exitCode: Int32?
        public let archivedAt: Date
        public let commands: [[String: Any]]
        public let marks: [[String: Any]]
        /// Where `output.log` begins in the session's absolute stream: byte 0
        /// of the file is stream offset `outputBase`. The commands' and marks'
        /// offsets are absolute, so a reader slices `[start - base, end - base)`.
        /// `outputPruned` says the stream began before the file does (the ring
        /// rotated and no retained log covered it), so early offsets are gone.
        public let outputBase: UInt64
        public let outputPruned: Bool
        public let outputBytes: Int

        public init(
            id: UUID, name: String?, note: String?, labels: [String: String],
            cwd: String, shell: String, profile: String?, exitCode: Int32?,
            archivedAt: Date, commands: [[String: Any]], marks: [[String: Any]],
            outputBase: UInt64, outputPruned: Bool, outputBytes: Int
        ) {
            self.id = id
            self.name = name
            self.note = note
            self.labels = labels
            self.cwd = cwd
            self.shell = shell
            self.profile = profile
            self.exitCode = exitCode
            self.archivedAt = archivedAt
            self.commands = commands
            self.marks = marks
            self.outputBase = outputBase
            self.outputPruned = outputPruned
            self.outputBytes = outputBytes
        }

        func asJSON() -> [String: Any] {
            var item: [String: Any] = [
                "version": SessionArchive.formatVersion,
                "id": id.uuidString,
                "cwd": cwd,
                "shell": shell,
                "archivedAt": Int(archivedAt.timeIntervalSince1970 * 1000),
                "commands": commands,
                "marks": marks,
                "output": [
                    "base": outputBase,
                    "pruned": outputPruned,
                    "bytes": outputBytes,
                ] as [String: Any],
            ]
            if let name { item["name"] = name }
            if let note { item["note"] = note }
            if let profile { item["profile"] = profile }
            if let exitCode { item["exitCode"] = Int(exitCode) }
            if !labels.isEmpty { item["labels"] = labels }
            return item
        }
    }

    /// Write a session's serialized metadata and its output to disk.
    ///
    /// `metadata` is pre-serialized (`Record.asJSON()` → `Data`) by the caller
    /// on the event loop, so nothing non-`Sendable` crosses onto this queue —
    /// only `Data`, which is. `completion` fires on the archive queue with
    /// whether the write succeeded.
    public static func write(
        id: UUID,
        metadata: Data,
        output: Data,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async {
            let dir = DaemonPaths.archiveDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try metadata.write(to: dir.appendingPathComponent("archive.json"), options: .atomic)
                try output.write(to: dir.appendingPathComponent("output.log"), options: .atomic)
                completion(true)
            } catch {
                completion(false)
            }
        }
    }

    /// Every archived session's metadata as serialized JSON, newest first.
    /// Reads the small `archive.json` of each directory (never `output.log`)
    /// and strips the command/mark arrays — the detail route carries those.
    /// Runs on the archive queue; `completion` fires there with the encoded
    /// listing, so the route hops back to its loop with only `Data`.
    public static func list(completion: @escaping @Sendable (Data) -> Void) {
        queue.async {
            let base = DaemonPaths.archiveDirectory
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil
            )) ?? []
            let records = dirs.compactMap { dir -> [String: Any]? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("archive.json")),
                      var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { return nil }
                json.removeValue(forKey: "commands")
                json.removeValue(forKey: "marks")
                return json
            }.sorted {
                ($0["archivedAt"] as? Int ?? 0) > ($1["archivedAt"] as? Int ?? 0)
            }
            let encoded = (try? JSONSerialization.data(withJSONObject: ["ok": true, "archives": records]))
                ?? Data(#"{"ok":true,"archives":[]}"#.utf8)
            completion(encoded)
        }
    }

    /// One archive's full metadata file as bytes (already JSON), or nil. On
    /// the archive queue.
    public static func read(_ id: UUID, completion: @escaping @Sendable (Data?) -> Void) {
        queue.async {
            let file = DaemonPaths.archiveDirectory
                .appendingPathComponent(id.uuidString, isDirectory: true)
                .appendingPathComponent("archive.json")
            completion(try? Data(contentsOf: file))
        }
    }

    /// One archive's captured output bytes, or nil. On the archive queue.
    public static func output(_ id: UUID, completion: @escaping @Sendable (Data?) -> Void) {
        queue.async {
            let file = DaemonPaths.archiveDirectory
                .appendingPathComponent(id.uuidString, isDirectory: true)
                .appendingPathComponent("output.log")
            completion(try? Data(contentsOf: file))
        }
    }

    /// Remove an archive permanently. `completion` (on the archive queue)
    /// gets false if it was not there.
    public static func delete(_ id: UUID, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            let dir = DaemonPaths.archiveDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { return completion(false) }
            completion((try? FileManager.default.removeItem(at: dir)) != nil)
        }
    }
}
