import Foundation

/// The archive list the daemon keeps in memory for `GET /api/archives`
/// (`fleet-first-paint`, round 3). The route cost one directory scan and one
/// file read per archive on every request: 80 to 90 ms warm for 624 archives.
/// The index keeps the records and the encoded bodies, and reads the
/// directory again only after the directory changed.
///
/// The index learns of a change in two ways:
///
/// - `SessionArchive.write` and `SessionArchive.delete` call `invalidate()`.
/// - Each request does one `stat` of the archive directory. A subdirectory
///   that something outside the daemon adds or removes moves the directory's
///   modification time, and a moved time reads again.
///
/// A read that started less than `settleSeconds` after the directory's
/// modification time is not kept: a writer outside the daemon makes the
/// subdirectory first and `archive.json` after, and the second step does not
/// move the directory's time. An edit of one `archive.json` in place is not
/// seen; no code does that.
///
/// Every member runs on `SessionArchive.queue`. The event loop gets `Data`
/// and the tag only.
final class ArchiveIndex: @unchecked Sendable {
    /// One encoded answer and its `ETag`.
    struct Body: Sendable {
        let data: Data
        let etag: String
    }

    /// What the kept records were read from.
    private struct Stamp: Equatable {
        let path: String
        let modified: Date
    }

    /// What one kept body was built from. A reload of `projects.json` moves
    /// the generation, so the body is built again from the kept records.
    private struct BodyKey: Hashable {
        let store: ObjectIdentifier
        let generation: Int
        let filter: String?
    }

    /// See the type comment.
    static let settleSeconds: TimeInterval = 2
    /// Bodies kept at once: the whole list and a few `?project=` filters.
    static let maxBodies = 16

    private var stamp: Stamp?
    private var records: [[String: Any]] = []
    private var bodies: [BodyKey: Body] = [:]
    private var reads = 0
    private let readsLock = NSLock()

    /// How many times the index read the archive directory, for a test.
    var directoryReads: Int {
        readsLock.lock()
        defer { readsLock.unlock() }
        return reads
    }

    /// Forget the records: the next request reads the directory.
    func invalidate() {
        stamp = nil
        bodies = [:]
    }

    /// The body of the list for `filter` (a project id, or nil for every
    /// archive), newest first. Each record carries its `project`: its
    /// labels, then its archived cwd.
    func body(projects: ProjectStore, filter: String?) -> Body {
        refreshIfChanged()
        let key = BodyKey(store: ObjectIdentifier(projects), generation: projects.generation, filter: filter)
        if let kept = bodies[key] { return kept }
        let rows = records.compactMap { record -> [String: Any]? in
            let project = projects.project(forArchive: record)
            if let filter, project?.id != filter { return nil }
            var record = record
            if let project { record["project"] = project.rowJSON }
            return record
        }
        // Sorted keys: the same list gives the same bytes and the same tag.
        let data = (try? JSONSerialization.data(
            withJSONObject: ["ok": true, "archives": rows], options: [.sortedKeys]
        )) ?? Data(#"{"archives":[],"ok":true}"#.utf8)
        let body = Body(data: data, etag: "\"\(HTTPAPIHandler.fnv1a(data))\"")
        // Kept only when the records are: a read that is not settled must
        // not outlive its request.
        if stamp != nil {
            if bodies.count >= Self.maxBodies { bodies = [:] }
            bodies[key] = body
        }
        return body
    }

    /// Read the directory when no settled read of its present state is kept.
    private func refreshIfChanged() {
        let directory = DaemonPaths.archiveDirectory
        let started = Date()
        let modified = (try? FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate]) as? Date
        if let stamp, let modified, stamp == Stamp(path: directory.path, modified: modified) { return }
        records = SessionArchive.readRecords().sorted {
            ($0["archivedAt"] as? Int ?? 0) > ($1["archivedAt"] as? Int ?? 0)
        }
        bodies = [:]
        readsLock.lock()
        reads += 1
        readsLock.unlock()
        // No directory, or a directory that changed a moment ago: answer
        // this read and read again on the next request.
        if let modified, started.timeIntervalSince(modified) >= Self.settleSeconds {
            stamp = Stamp(path: directory.path, modified: modified)
        } else {
            stamp = nil
        }
    }
}
