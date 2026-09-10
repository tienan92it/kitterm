import Foundation
import NIOConcurrencyHelpers

/// How a run of the daemon ended, written where the next run can read it:
/// `~/.kitterm/last-run.json`.
///
/// ## Why the file exists
///
/// On 2026-09-09 the daemon died three times and said nothing. `server.log`
/// held only "kitterm daemon listening" lines, every session went with each
/// death, and the cause — the kernel killed the process under memory
/// pressure, and the launchd `KeepAlive` agent restarted it — was found from
/// `launchctl print` and `sysctl vm.swapusage`, outside the product. Nothing
/// in kitterm told that apart from a `kitterm restart`, which also loses
/// every session, or from `kitterm upgrade --live`, which loses nothing.
///
/// A process the kernel kills cannot save itself. So the record is not a
/// crash report: it is a run that says it is alive while it lives, and says
/// how it ended when it can. The signal is the *absence* of an ending.
///
/// ## The three states
///
/// | On disk | What happened |
/// |---|---|
/// | `endedAt` set, `reason` `stopped` or `restarted` | the run ended on purpose |
/// | `endedAt` set, `reason` `takeover` | the run replaced itself in place; the successor keeps every session |
/// | no `endedAt` | the run never got to write one: the kernel killed it, the machine lost power, the process aborted |
///
/// The third row is the whole point, and it is why `aliveAt` is here. A
/// record with no `endedAt` still has to name *when* the run was last alive,
/// or the next run can only say "at some time before now". `aliveAt` is
/// refreshed on a slow cadence while the daemon runs, so it is late by at
/// most `KittermConstants.lastRunRefreshSeconds`, never early. `sessions` is
/// refreshed with it, so the same record says how much the death cost.
///
/// ## Versioning
///
/// `version` names the layout, the discipline `archive.json`, `respawn.json`
/// and the takeover handoff already follow. A reader that finds a version it
/// was not built for reports nothing rather than guessing: a wrong claim
/// about how the last run ended is worse than no claim. Unknown fields
/// decode away, so a newer daemon may add one without breaking an older
/// reader.
///
/// ## What this type does not do
///
/// It does not show anything. `LastRunStore.beginRun` returns the previous
/// record and the daemon's start path decides what to say about it.
public struct LastRun: Codable, Equatable, Sendable {
    /// The layout this build writes.
    public static let formatVersion = 1

    /// Why a run ended, when it ended on purpose.
    ///
    /// `stopped` and `restarted` are both clean: no session survives either,
    /// and the difference is only whether a start follows. `takeover` is the
    /// live upgrade (`docs/live-upgrade.md`): same pid, same shells, the
    /// successor adopts every master, so it must never read as a death.
    ///
    /// Nothing writes `restarted` today. `kitterm restart` reaches the daemon
    /// as a plain `SIGTERM`, the same byte `kitterm stop` sends, so the
    /// daemon cannot tell them apart from inside; recording the difference
    /// needs the CLI to state its intent before it signals. The value stays
    /// in the contract because it is the shape the plan pins and because a
    /// reader must accept it from a daemon that does write it.
    public enum Reason: String, Codable, Sendable {
        case stopped
        case restarted
        case takeover
    }

    public var version: Int
    /// The daemon's process id. A live upgrade keeps it, so `pid` alone never
    /// proves a run is the same run.
    public var pid: Int32
    /// Epoch milliseconds, when the run began.
    public var startedAt: Int64
    /// Epoch milliseconds, the last time the run said it was alive.
    public var aliveAt: Int64
    /// How many sessions the registry held at `aliveAt`.
    public var sessions: Int
    /// Epoch milliseconds, when the run ended. Absent on a run that was
    /// killed — the signal this whole file exists to carry.
    public var endedAt: Int64?
    /// Absent exactly when `endedAt` is absent.
    public var reason: Reason?

    public init(
        version: Int = LastRun.formatVersion,
        pid: Int32,
        startedAt: Int64,
        aliveAt: Int64,
        sessions: Int,
        endedAt: Int64? = nil,
        reason: Reason? = nil
    ) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.aliveAt = aliveAt
        self.sessions = sessions
        self.endedAt = endedAt
        self.reason = reason
    }

    /// The run ended on purpose and said so.
    public var endedCleanly: Bool { endedAt != nil }
}

/// The one writer of `last-run.json`, held by the daemon process for the
/// length of a run.
///
/// The order matters at start: `beginRun` reads the previous record before it
/// replaces it, and hands it back, because that record is the only copy and
/// the next thing the daemon does is overwrite it.
///
/// Every write is a whole-file atomic replace of a record under 200 bytes,
/// made off the event loop: from `runDaemon` at start and stop, from
/// `prepareHandoff` on the takeover path, and from a `Task` on the refresh
/// cadence. Nothing here runs on the output path.
public final class LastRunStore: @unchecked Sendable {
    private let file: URL
    private let lock = NIOLock()
    private var current: LastRun?

    public init(file: URL) {
        self.file = file
    }

    /// The record on disk, or nil when there is none, it cannot be read, or
    /// its version is not this build's.
    public static func read(_ file: URL) -> LastRun? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            let record = try JSONDecoder().decode(LastRun.self, from: data)
            guard record.version == LastRun.formatVersion else {
                FileHandle.standardError.write(Data(
                    "kitterm: ignoring \(file.path): format version \(record.version), expected \(LastRun.formatVersion)\n".utf8
                ))
                return nil
            }
            return record
        } catch {
            FileHandle.standardError.write(Data("kitterm: ignoring \(file.path): \(error)\n".utf8))
            return nil
        }
    }

    /// Start a run: read what the last one left, then replace it.
    ///
    /// Returns the previous record so the caller can report it. A caller that
    /// discards the return value has lost it: this call is the moment it
    /// stops existing on disk.
    @discardableResult
    public func beginRun(pid: Int32 = getpid(), sessions: Int = 0, now: Date = Date()) -> LastRun? {
        let previous = Self.read(file)
        let stamp = Self.milliseconds(now)
        lock.withLock {
            let record = LastRun(
                pid: pid, startedAt: stamp, aliveAt: stamp, sessions: sessions
            )
            current = record
            writeLocked(record)
        }
        return previous
    }

    /// The run is still alive, and holds this many sessions. Cheap enough to
    /// call on a cadence; a no-op before `beginRun`.
    public func refresh(sessions: Int, now: Date = Date()) {
        lock.withLock {
            guard var record = current, record.endedAt == nil else { return }
            record.aliveAt = Self.milliseconds(now)
            record.sessions = sessions
            current = record
            writeLocked(record)
        }
    }

    /// The run ended on purpose, holding `sessions` at the end when the caller
    /// knows it. A second call is ignored: the first reason is the true one,
    /// and a takeover whose `exec` returned runs a stop path later in the same
    /// process without being the end of that run.
    public func end(reason: LastRun.Reason, sessions: Int? = nil, now: Date = Date()) {
        lock.withLock {
            guard var record = current, record.endedAt == nil else { return }
            let stamp = Self.milliseconds(now)
            record.aliveAt = stamp
            record.endedAt = stamp
            record.reason = reason
            if let sessions { record.sessions = sessions }
            current = record
            writeLocked(record)
        }
    }

    /// What this store last wrote, for a caller that already holds the run.
    public var record: LastRun? { lock.withLock { current } }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Caller holds `lock`.
    private func writeLocked(_ record: LastRun) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: file, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("kitterm: cannot write \(file.path): \(error)\n".utf8))
        }
    }
}

// MARK: - Reporting the previous run

extension LastRun {
    /// What the previous run did, as one word the next run reports and a
    /// consumer branches on.
    ///
    /// Three values, not two, because `goal.md` asks a reader to tell three
    /// things apart and `endedCleanly` alone cannot: a stop and a live
    /// upgrade both set `endedAt`, and only one of them lost the sessions.
    public enum Outcome: String, Sendable {
        /// The run ended on purpose. `stopped` and `restarted` are one value
        /// here: both take every session, and nothing that reads the record
        /// needs the difference between them.
        case clean
        /// The run replaced itself in place. The successor kept every
        /// session, so this is never a death and never a loss.
        case takeover
        /// The run never wrote an ending. The kernel killed it, the machine
        /// lost power, or the process aborted. This is the case the goal
        /// exists for.
        case unrecorded
    }

    /// How this record reads to the run that follows it.
    ///
    /// A record needs both an end time and a reason to count as an ending. A
    /// half-written file — a hand-edited one, or a newer daemon's field this
    /// build decoded away — reads as `unrecorded` rather than as a claim
    /// this build cannot support.
    public var outcome: Outcome {
        guard endedAt != nil, let reason else { return .unrecorded }
        switch reason {
        case .stopped, .restarted: return .clean
        case .takeover: return .takeover
        }
    }
}

/// The reading half of `LastRun`: one log line and one set of event keys per
/// case, so `server.log` and the feed never disagree about what happened.
///
/// ## The four cases
///
/// The record has three states; a state directory with no record at all is a
/// fourth. Each gets a log line. Only a record gets event keys — the absence
/// of `previous` on `daemon.started` *is* "no previous run", so a consumer
/// branches on three values instead of four and a first start needs no
/// special case.
///
/// ## Why the event keys are prefixed
///
/// `daemon.started` already carries `epoch`, `version`, `pid` and
/// `takeover`, all about the run that just began. `pid` there is this run's
/// pid, so the previous run's fields cannot use the bare names `plan.md`
/// lists; every one of them is `previous`-prefixed. Nothing existing is
/// touched, so a client that reads only `epoch` is unaffected.
public enum PreviousRun {
    /// One line for `server.log`, in the daemon's own voice: short,
    /// lowercase, factual, and enough to act on. The unrecorded case names
    /// the pid, the last time the run was alive, and the sessions it held,
    /// which are the three facts `goal.md`'s completion condition 2 asks for.
    public static func logLine(_ record: LastRun?) -> String {
        guard let record else { return "kitterm: no previous run recorded\n" }
        let pid = "previous run (pid \(record.pid))"
        switch record.outcome {
        case .clean:
            let reason = record.reason?.rawValue ?? "clean"
            return "kitterm: \(pid) ended cleanly (\(reason)) at \(stamp(record.aliveAt))\n"
        case .takeover:
            return "kitterm: \(pid) handed over in place at \(stamp(record.aliveAt)), "
                + "\(record.sessions) session(s) kept\n"
        case .unrecorded:
            return "kitterm: \(pid) ended with no recorded reason, last alive "
                + "\(stamp(record.aliveAt)) holding \(record.sessions) session(s)\n"
        }
    }

    /// The same fact as `daemon.started` data: one key per field, never a
    /// blob, so a consumer branches on `previous` without parsing prose.
    /// Empty when there is no record.
    public static func eventData(_ record: LastRun?) -> [String: String] {
        guard let record else { return [:] }
        var data = [
            "previous": record.outcome.rawValue,
            "previousPid": String(record.pid),
            "previousAliveAt": String(record.aliveAt),
            "previousSessions": String(record.sessions),
        ]
        // Absent exactly when the run left no ending, which is the signal.
        if let endedAt = record.endedAt { data["previousEndedAt"] = String(endedAt) }
        return data
    }

    /// Epoch milliseconds as the ISO 8601 stamp the rest of the CLI prints.
    private static func stamp(_ milliseconds: Int64) -> String {
        ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        )
    }
}
