import Foundation
import NIOConcurrencyHelpers

/// The daily cost and token rollup the daemon keeps, on disk at
/// `~/.kitterm/usage-daily.json`, so history accumulates past Claude Code's
/// own retention.
///
/// ## Why the file exists
///
/// Claude Code deletes a transcript thirty days after its last write
/// (`cleanupPeriodDays`). Every dollar and token the dashboard could show
/// lives in those transcripts and nowhere else, so a ninety-day chart built
/// from them is a thirty-day chart with a flat tail. This file is where a
/// day goes on living after its transcript is gone.
///
/// ## What the file holds, and why the key is a session
///
/// `version`, the zone the days were bucketed in, when the last refresh
/// ran, and one record per transcript keyed by its path under
/// `~/.claude/projects/`. A record is what `TranscriptUsage` read: the
/// session id, the project the cwd resolved to, the bill's total when the
/// session has one, tokens per day, and the fingerprint of the file it was
/// read from. A day is not a key on disk. A day is a *sum* over the records,
/// taken at serve time, because the thing a refresh can replace whole is one
/// session, and the thing a deletion removes is one session. Keying by day
/// would make a refresh do arithmetic on a total it cannot see the parts
/// of, and a resumed session — whose bill is cumulative, so its old total
/// must come out before its new one goes in — would need a ledger of what
/// it had already put on each day. The session record *is* that ledger.
///
/// ## What "never loses a day" means
///
/// A refresh lists the transcripts it can see, reads the ones whose size or
/// mtime differ from their record, and replaces exactly those records. A
/// record whose transcript is no longer on disk is not visited, so it is
/// not replaced, so it stays, and the days it holds stay with it. Nothing
/// in the refresh subtracts. `UsageRollupTests` writes a record older than
/// any transcript in its scratch root, refreshes, and reads it back.
///
/// ## Which day a turn is on
///
/// The daemon's own zone at the time of the read, recorded in the file.
/// When the zone differs from the file's, every transcript still on disk
/// is read again into the new zone; a record whose transcript is gone keeps
/// the days it has, in the zone it had, which is the zone the human lived
/// in when the work was done. The route reports the current zone.
///
/// ## The scan
///
/// One directory listing per project directory, one `stat` per transcript
/// and per subagent file, and a full read only of what changed. A refresh
/// with nothing changed is the listing and the stats. Every refresh runs on
/// `queue`, never on the event loop; the route hops to the same queue to
/// sum, so the loop pays for an encode and a write.
public final class UsageRollup: @unchecked Sendable {
    public static let formatVersion = 1
    /// How often the daemon refreshes after the one at start. Five minutes:
    /// a live session's file grows every turn, and rereading a large one
    /// every tick is the cost of a fresh number.
    public static let refreshIntervalSeconds = 300
    /// The most days one request may ask for.
    public static let maxRangeDays = 400
    /// Where the scan, the timer and the route's sum run.
    static let queue = DispatchQueue(label: "kitterm.usage", qos: .utility)

    /// Where Claude Code keeps its transcripts: `$CLAUDE_CONFIG_DIR/projects`
    /// or `~/.claude/projects`.
    public static var defaultTranscriptsRoot: URL {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        return base.appendingPathComponent("projects", isDirectory: true)
    }

    /// The project a session's cwd resolved to when it was read.
    public struct ProjectRef: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var root: String
        public var registered: Bool
    }

    /// One transcript as last read.
    public struct SessionRecord: Codable, Equatable, Sendable {
        public var sessionId: String?
        public var cwd: String?
        public var project: ProjectRef?
        /// Bytes and epoch milliseconds of the main file at the read.
        public var size: Int64
        public var mtime: Int64
        /// Subagent files under `<session>/subagents/` at the read.
        public var subagentFiles: Int
        public var subagentBytes: Int64
        /// True when the last line was a `cost-state` bill. A bill of zero
        /// is a bill.
        public var billed: Bool
        public var totalCostUSD: Double
        /// The bill's `startTime` as a day, for a bill with no turns.
        public var startDay: String?
        public var days: [String: TokenCounts]
        /// The bill's `modelUsage` map, as `TranscriptBill` read it: dollars
        /// and tokens per model id. Nil on a record written before the
        /// rollup kept it (format version 1 before 2026-09-18) and on an
        /// unbilled session; a bill of zero holds an empty map. A billed
        /// record with nil is read again on the next refresh while its
        /// transcript is on disk, and stays whole but unsplit once it is
        /// gone: the report counts its dollars under `unsplitUSD`.
        public var models: [String: TranscriptBill.ModelUsage]?
    }

    struct FileShape: Codable {
        var version: Int
        var timeZone: String
        var refreshedAt: Int64
        var sessions: [String: SessionRecord]
    }

    /// What one refresh did.
    public struct RefreshReport: Equatable, Sendable {
        /// Transcripts on disk.
        public var scanned: Int
        /// Read in full because they were new or changed.
        public var read: Int
        /// Left as recorded because size and mtime matched.
        public var skipped: Int
        /// Records kept whose transcript is no longer on disk.
        public var retained: Int
        public var durationMs: Int
        public var wrote: Bool
    }

    private let file: URL
    private let transcriptsRoot: URL
    private let projects: ProjectStore
    private let zone: TimeZone
    private let lock = NIOLock()
    private var sessions: [String: SessionRecord]
    private var fileZone: String?
    private var refreshedAt: Int64
    private var timer: DispatchSourceTimer?

    public init(file: URL, transcriptsRoot: URL, projects: ProjectStore, zone: TimeZone = .current) {
        self.file = file
        self.transcriptsRoot = transcriptsRoot
        self.projects = projects
        self.zone = zone
        if let shape = Self.load(file) {
            sessions = shape.sessions
            fileZone = shape.timeZone
            refreshedAt = shape.refreshedAt
        } else {
            sessions = [:]
            fileZone = nil
            refreshedAt = 0
        }
    }

    /// The zone every day is keyed in.
    public var timeZone: TimeZone { zone }

    /// Refresh now on `queue`, then every `refreshIntervalSeconds`.
    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: Self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(Self.refreshIntervalSeconds), leeway: .seconds(10))
            timer.setEventHandler { [weak self] in _ = self?.refresh() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - Refresh

    /// The listing and the stats, then a read of every transcript whose
    /// fingerprint changed. Synchronous; the daemon calls it on `queue`.
    @discardableResult
    public func refresh(now: Date = Date()) -> RefreshReport {
        let started = Date()
        let listed = Self.list(transcriptsRoot)
        let before = lock.withLock { (sessions, fileZone) }
        let zoneChanged = before.1 != zone.identifier
        var replaced: [String: SessionRecord] = [:]
        var skipped = 0
        for entry in listed {
            // A billed record with no per-model map was written before the
            // rollup kept one; it is read once more so the split fills in.
            if !zoneChanged, let record = before.0[entry.key], record.size == entry.size, record.mtime == entry.mtime,
               record.subagentFiles == entry.subagents.count, record.subagentBytes == entry.subagentBytes,
               record.models != nil || !record.billed {
                skipped += 1
                continue
            }
            replaced[entry.key] = read(entry)
        }
        let seen = Set(listed.map(\.key))
        let retained = before.0.keys.filter { !seen.contains($0) }.count
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        let wrote: Bool = lock.withLock {
            for (key, record) in replaced { sessions[key] = record }
            refreshedAt = stamp
            guard !replaced.isEmpty || fileZone != zone.identifier || !FileManager.default.fileExists(atPath: file.path) else {
                return false
            }
            fileZone = zone.identifier
            persistLocked()
            return true
        }
        return RefreshReport(
            scanned: listed.count, read: replaced.count, skipped: skipped, retained: retained,
            durationMs: Int(Date().timeIntervalSince(started) * 1000), wrote: wrote
        )
    }

    struct Listed {
        var key: String
        var path: String
        var size: Int64
        var mtime: Int64
        var subagents: [String]
        var subagentBytes: Int64
    }

    /// Every `<dir>/<session>.jsonl` under `root`, with its subagent files
    /// at `<dir>/<session>/subagents/*.jsonl`. Sorted by key, so a report
    /// reads the same on every run.
    static func list(_ root: URL) -> [Listed] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let dirs = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var listed: [Listed] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let entries = try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else {
                continue
            }
            for entry in entries where entry.pathExtension == "jsonl" {
                guard let values = try? entry.resourceValues(forKeys: keys), values.isDirectory != true else { continue }
                let session = entry.deletingPathExtension().lastPathComponent
                let subagentDir = dir.appendingPathComponent(session, isDirectory: true)
                    .appendingPathComponent("subagents", isDirectory: true)
                var subagents: [String] = []
                var subagentBytes: Int64 = 0
                if let files = try? manager.contentsOfDirectory(at: subagentDir, includingPropertiesForKeys: [.fileSizeKey]) {
                    for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "jsonl" {
                        subagents.append(file.path)
                        subagentBytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
                listed.append(Listed(
                    key: dir.lastPathComponent + "/" + entry.lastPathComponent,
                    path: entry.path,
                    size: Int64(values.fileSize ?? 0),
                    mtime: Int64(((values.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000).rounded()),
                    subagents: subagents,
                    subagentBytes: subagentBytes
                ))
            }
        }
        return listed.sorted { $0.key < $1.key }
    }

    private func read(_ entry: Listed) -> SessionRecord {
        let usage = TranscriptUsage.read(path: entry.path, subagents: entry.subagents, zone: zone)
        var billed = false
        var total = 0.0
        var startDay: String?
        var models: [String: TranscriptBill.ModelUsage]?
        if case .bill(let bill) = usage.bill {
            billed = true
            total = bill.totalCostUSD
            models = bill.modelUsage
            if let start = bill.startTime {
                startDay = DayKey(Date(timeIntervalSince1970: Double(start) / 1000), in: zone).description
            }
        }
        return SessionRecord(
            sessionId: usage.sessionId,
            cwd: usage.cwd,
            project: usage.cwd.map(project(for:)),
            size: entry.size,
            mtime: entry.mtime,
            subagentFiles: entry.subagents.count,
            subagentBytes: entry.subagentBytes,
            billed: billed,
            totalCostUSD: total,
            startDay: startDay,
            days: usage.days,
            models: models
        )
    }

    /// The project for a transcript's cwd: the store's resolution, which
    /// folds a worktree into its checkout, or the cwd itself as its own
    /// project when it lies outside every checkout and every registered
    /// root (`/Users/antran` for a job session).
    private func project(for cwd: String) -> ProjectRef {
        if let resolved = projects.resolve(cwd: cwd) {
            return ProjectRef(id: resolved.id, name: resolved.name, root: resolved.root ?? cwd, registered: resolved.registered)
        }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        let id = ProjectStore.slug(name)
        return ProjectRef(id: id.isEmpty ? "unknown" : id, name: name.isEmpty ? cwd : name, root: cwd, registered: false)
    }

    // MARK: - The report

    /// Cost and tokens for one day or one project, the shape the route
    /// answers per day, per project within a day, and per project over the
    /// range. `costUSD` is the dollars attributed; `apportionedUSD` is the
    /// part of it that came from a session spanning more than one day and
    /// was split by token share. `unbilledSessions` had turns and no bill.
    public struct Bucket: Codable, Equatable, Sendable {
        public var costUSD: Double = 0
        public var apportionedUSD: Double = 0
        /// The part of `costUSD` from a record read before the rollup kept
        /// the per-model map, whose transcript is gone: it is in the total
        /// and in no model's row, so the rows plus this equal the total.
        public var unsplitUSD: Double = 0
        public var tokens: TokenCounts = .zero
        public var sessions: Int = 0
        public var unbilledSessions: Int = 0

        mutating func add(_ share: TranscriptUsage.Share, billed: Bool) {
            costUSD += share.costUSD
            if share.apportioned { apportionedUSD += share.costUSD }
            tokens += share.tokens
            sessions += 1
            if !billed { unbilledSessions += 1 }
        }
    }

    /// One model's part of a day or of the range: the bill's own field
    /// names, and the name the page prints (`ModelName`). A session on two
    /// days puts each day's share of its per-model dollars and tokens here,
    /// by the same token share that splits its total.
    public struct ModelBucket: Codable, Equatable, Sendable {
        public var model: String
        public var name: String
        public var costUSD: Double = 0
        public var apportionedUSD: Double = 0
        public var inputTokens: Double = 0
        public var outputTokens: Double = 0
        public var cacheReadInputTokens: Double = 0
        public var cacheCreationInputTokens: Double = 0
        /// Sessions that used the model in the range, or on the day.
        public var sessions: Int = 0

        mutating func add(_ usage: TranscriptBill.ModelUsage, fraction: Double, apportioned: Bool) {
            costUSD += usage.costUSD * fraction
            if apportioned { apportionedUSD += usage.costUSD * fraction }
            inputTokens += Double(usage.inputTokens) * fraction
            outputTokens += Double(usage.outputTokens) * fraction
            cacheReadInputTokens += Double(usage.cacheReadInputTokens) * fraction
            cacheCreationInputTokens += Double(usage.cacheCreationInputTokens) * fraction
            sessions += 1
        }
    }

    public struct ProjectBucket: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var root: String
        public var registered: Bool
        public var costUSD: Double
        public var apportionedUSD: Double
        public var tokens: TokenCounts
        public var sessions: Int
        public var unbilledSessions: Int
    }

    public struct Day: Codable, Equatable, Sendable {
        public var day: String
        public var costUSD: Double
        public var apportionedUSD: Double
        public var unsplitUSD: Double
        public var tokens: TokenCounts
        public var sessions: Int
        public var unbilledSessions: Int
        /// The day's dollars per model, dearest first; they sum to
        /// `costUSD` less `unsplitUSD`.
        public var models: [ModelBucket]
        public var projects: [ProjectBucket]
    }

    public struct DailyReport: Codable, Equatable, Sendable {
        public var ok = true
        public var timeZone: String
        public var from: String
        public var to: String
        /// Epoch milliseconds of the last refresh; 0 before the first.
        public var refreshedAt: Int64
        /// Records in the file, on disk or retained.
        public var recordedSessions: Int
        /// One entry per day in the range, zero-filled, oldest first.
        public var days: [Day]
        public var totals: Bucket
        /// The range's dollars and tokens per model, dearest first. Their
        /// dollars sum to `totals.costUSD` less `totals.unsplitUSD`.
        public var models: [ModelBucket]
        /// The range's totals per project, dearest first.
        public var projects: [ProjectBucket]
    }

    /// The range, summed from the records. Pure over memory; the route runs
    /// it on `queue` only to stay off the loop.
    public func daily(from: DayKey, to: DayKey) -> DailyReport {
        let (records, stamp) = lock.withLock { (sessions, refreshedAt) }
        var range: [DayKey] = []
        var cursor = from
        while cursor <= to {
            range.append(cursor)
            cursor = cursor.advanced(by: 1)
        }
        let wanted = Set(range.map(\.description))
        var perDay: [String: Bucket] = [:]
        var perDayProject: [String: [String: ProjectBucket]] = [:]
        var perProject: [String: ProjectBucket] = [:]
        var totals = Bucket()
        var counted = Set<String>()
        var countedUnbilled = Set<String>()
        // A session on two days is one session in the range's totals and
        // in a project's, so those count keys, not shares.
        var projectSessions: [String: Set<String>] = [:]
        var projectUnbilled: [String: Set<String>] = [:]
        var perDayModel: [String: [String: ModelBucket]] = [:]
        var perModel: [String: ModelBucket] = [:]
        var modelSessions: [String: Set<String>] = [:]
        for (key, record) in records {
            let shares = TranscriptUsage.apportion(
                days: record.days, totalCostUSD: record.billed ? record.totalCostUSD : nil, fallbackDay: record.startDay
            )
            let sessionTokens = record.days.values.reduce(0) { $0 + $1.total }
            for (day, share) in shares where wanted.contains(day) {
                perDay[day, default: Bucket()].add(share, billed: record.billed)
                let project = record.project ?? ProjectRef(id: "unknown", name: "unknown", root: "", registered: false)
                perDayProject[day, default: [:]][project.root, default: Self.empty(project)].add(share, billed: record.billed)
                perProject[project.root, default: Self.empty(project)].add(share, billed: record.billed)
                projectSessions[project.root, default: []].insert(key)
                if !record.billed { projectUnbilled[project.root, default: []].insert(key) }
                totals.costUSD += share.costUSD
                if share.apportioned { totals.apportionedUSD += share.costUSD }
                totals.tokens += share.tokens
                if counted.insert(key).inserted { totals.sessions += 1 }
                if !record.billed, countedUnbilled.insert(key).inserted { totals.unbilledSessions += 1 }
                // The per-model split, by the day's share of the session's
                // tokens: the fraction `apportion` gives the dollars.
                guard record.billed else { continue }
                guard let models = record.models else {
                    perDay[day, default: Bucket()].unsplitUSD += share.costUSD
                    totals.unsplitUSD += share.costUSD
                    continue
                }
                let fraction = sessionTokens > 0 ? Double(share.tokens.total) / Double(sessionTokens) : 1
                for (id, usage) in models {
                    perDayModel[day, default: [:]][id, default: Self.empty(id)]
                        .add(usage, fraction: fraction, apportioned: share.apportioned)
                    perModel[id, default: Self.empty(id)].add(usage, fraction: fraction, apportioned: share.apportioned)
                    modelSessions[id, default: []].insert(key)
                }
            }
        }
        for root in perProject.keys {
            perProject[root]?.sessions = projectSessions[root]?.count ?? 0
            perProject[root]?.unbilledSessions = projectUnbilled[root]?.count ?? 0
        }
        for id in perModel.keys {
            perModel[id]?.sessions = modelSessions[id]?.count ?? 0
        }
        let days = range.map { day -> Day in
            let bucket = perDay[day.description] ?? Bucket()
            return Day(
                day: day.description, costUSD: bucket.costUSD, apportionedUSD: bucket.apportionedUSD,
                unsplitUSD: bucket.unsplitUSD, tokens: bucket.tokens, sessions: bucket.sessions,
                unbilledSessions: bucket.unbilledSessions,
                models: Self.sorted(perDayModel[day.description] ?? [:]),
                projects: Self.sorted(perDayProject[day.description] ?? [:])
            )
        }
        return DailyReport(
            timeZone: zone.identifier, from: from.description, to: to.description, refreshedAt: stamp,
            recordedSessions: records.count, days: days, totals: totals,
            models: Self.sorted(perModel), projects: Self.sorted(perProject)
        )
    }

    private static func empty(_ model: String) -> ModelBucket {
        ModelBucket(model: model, name: ModelName.name(for: model))
    }

    private static func sorted(_ buckets: [String: ModelBucket]) -> [ModelBucket] {
        buckets.values.sorted { ($0.costUSD, $1.model) > ($1.costUSD, $0.model) }
    }

    private static func empty(_ project: ProjectRef) -> ProjectBucket {
        ProjectBucket(
            id: project.id, name: project.name, root: project.root, registered: project.registered,
            costUSD: 0, apportionedUSD: 0, tokens: .zero, sessions: 0, unbilledSessions: 0
        )
    }

    private static func sorted(_ buckets: [String: ProjectBucket]) -> [ProjectBucket] {
        buckets.values.sorted { ($0.costUSD, $0.tokens.total, $1.root) > ($1.costUSD, $1.tokens.total, $0.root) }
    }

    /// For a test: the records as the file holds them.
    public var records: [String: SessionRecord] { lock.withLock { sessions } }

    // MARK: - The file

    private static func load(_ file: URL) -> FileShape? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            let shape = try JSONDecoder().decode(FileShape.self, from: data)
            guard shape.version == formatVersion else {
                FileHandle.standardError.write(Data(
                    "kitterm: ignoring \(file.path): format version \(shape.version), expected \(formatVersion)\n".utf8
                ))
                return nil
            }
            return shape
        } catch {
            FileHandle.standardError.write(Data("kitterm: ignoring \(file.path): \(error)\n".utf8))
            return nil
        }
    }

    /// Caller holds `lock`. Whole-file atomic replace, then owner-only, the
    /// order `push.json` uses: the accounting is what a watch token exists
    /// to withhold.
    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let shape = FileShape(version: Self.formatVersion, timeZone: zone.identifier, refreshedAt: refreshedAt, sessions: sessions)
            try encoder.encode(shape).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            FileHandle.standardError.write(Data("kitterm: cannot write \(file.path): \(error)\n".utf8))
        }
    }
}

extension UsageRollup.ProjectBucket {
    mutating func add(_ share: TranscriptUsage.Share, billed: Bool) {
        costUSD += share.costUSD
        if share.apportioned { apportionedUSD += share.costUSD }
        tokens += share.tokens
        sessions += 1
        if !billed { unbilledSessions += 1 }
    }
}
