import Foundation

/// What the CLI means by the `SIGTERM` it is about to send, written where
/// the daemon's stop path can read it: `~/.kitterm/stop-intent.json`.
///
/// ## Why the file exists
///
/// `kitterm stop` and `kitterm restart` reach the daemon as the same signal,
/// a plain `SIGTERM` from the CLI or from `launchctl kickstart -k` under the
/// service agent. The daemon cannot tell them apart from inside, so its
/// `last-run.json` used to say `stopped` for both. The CLI knows which one it
/// is, so it states its intent here before it signals, and
/// `DaemonServer.stop()` reads it when it records the ending (`LastRun`).
///
/// ## Why a leftover file labels nothing
///
/// A file the daemon never read — the CLI fell through to `SIGKILL`, or the
/// machine died between the write and the signal — must not name a later
/// stop, or a later kill, `restarted`. Two facts bind it to one signal: the
/// `pid` it was written for, and `writtenAt`, which `consume` refuses past
/// `maxAgeSeconds`. And it is consumed: whatever it says, the read deletes
/// it, so it can decide at most one ending.
///
/// ## What it does not carry
///
/// Only `restarted` is ever written. `stopped` is what the daemon records
/// with no intent, `takeover` is written by the takeover path itself, and a
/// killed run writes nothing. Every write and read is a small whole-file
/// operation off the event loop: the CLI writes, the signal queue reads.
public struct StopIntent: Codable, Equatable, Sendable {
    /// The layout this build writes and reads.
    public static let formatVersion = 1

    /// An intent older than this is stale, whatever pid it names: a pid can
    /// be reused, and the signal follows the write within a second.
    public static let maxAgeSeconds: Int64 = 60

    public var version: Int
    /// The daemon the CLI is about to signal.
    public var pid: Int32
    public var reason: LastRun.Reason
    /// Epoch milliseconds, when the CLI wrote it.
    public var writtenAt: Int64

    public init(
        version: Int = StopIntent.formatVersion,
        pid: Int32,
        reason: LastRun.Reason,
        writtenAt: Int64
    ) {
        self.version = version
        self.pid = pid
        self.reason = reason
        self.writtenAt = writtenAt
    }

    /// Write the intent for `pid`, replacing any earlier one. Best-effort
    /// like `last-run.json`: a restart the daemon records as `stopped` is a
    /// small wrong, and refusing to restart over it would be a bigger one.
    public static func write(
        _ reason: LastRun.Reason, pid: Int32, to file: URL, now: Date = Date()
    ) {
        let intent = StopIntent(pid: pid, reason: reason, writtenAt: LastRunStore.milliseconds(now))
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(intent).write(to: file, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("kitterm: cannot write \(file.path): \(error)\n".utf8))
        }
    }

    /// Read the intent meant for `pid` and delete the file.
    ///
    /// Returns the reason only when the file names `pid`, is this build's
    /// version, and is younger than `maxAgeSeconds`. Every other file — a
    /// missing one, another pid's, a stale one, an unreadable one — answers
    /// nil, and the caller records `stopped`. The file is removed on every
    /// read, so a refused intent cannot wait for a pid it happens to match
    /// later.
    public static func consume(from file: URL, pid: Int32, now: Date = Date()) -> LastRun.Reason? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        // Delete first: whatever the file says, it decides at most once.
        try? FileManager.default.removeItem(at: file)
        guard let intent = try? JSONDecoder().decode(StopIntent.self, from: data) else {
            FileHandle.standardError.write(Data("kitterm: ignoring \(file.path): not a stop intent\n".utf8))
            return nil
        }
        guard intent.version == formatVersion else {
            FileHandle.standardError.write(Data(
                "kitterm: ignoring \(file.path): format version \(intent.version), expected \(formatVersion)\n".utf8
            ))
            return nil
        }
        guard intent.pid == pid else { return nil }
        let age = LastRunStore.milliseconds(now) - intent.writtenAt
        guard age >= 0, age <= maxAgeSeconds * 1000 else { return nil }
        return intent.reason
    }
}
