import Foundation
import NIOConcurrencyHelpers

/// The quota windows the Claude Code statusline renders have given the
/// daemon, each at the time of the post that carried it, on disk at
/// `~/.kitterm/usage-limits.json`.
///
/// ## Why the daemon has to be given it
///
/// No file on disk carries the quota. Claude Code hands its statusline script
/// a JSON object on stdin at every render, and since 2.1.251 that object
/// carries `rate_limits`: `five_hour`, `seven_day` and `spend_limit`, each
/// with a `used_percentage` and an epoch-seconds `resets_at`. A window is
/// present only for a Pro or Max subscriber, only after the first API
/// response of a session, and is dropped once its own reset passes. The value
/// exists nowhere else, so the statusline is the one thing that can post it
/// (`kitterm statusline install` teaches it to). The quota is one account's,
/// so a later post from any session is newer than an earlier one from any
/// other.
///
/// ## Why a post merges
///
/// The object does not always carry every window: a render can name
/// `seven_day` alone, and the human saw the Session row vanish from the
/// fleet view until a later render named `five_hour` again (round 18 of
/// `agent-dashboard`). So a post replaces each window it carries, with the
/// post's time as that window's `receivedAt`, and every window it does not
/// carry keeps its last value and its own time (`merging`). The reading's
/// own `receivedAt` is the newest post's, and so is `stale`; a window older
/// than that says so through its own age. The held set is bounded at
/// `maxWindows`: past it the oldest window goes.
///
/// ## What the file holds
///
/// `version` (2), `receivedAt` in epoch milliseconds, and `rateLimits`, one
/// window per key with the statusline's own field names plus the
/// `receivedAt` of the post that carried it. A version-1 file, which held
/// one post, loads with every window at the file's time. The file
/// exists so a restart does not turn "read four minutes ago" into "never
/// read": the age is the whole point of the route, and a reading that
/// survives a restart carries its true age. It is `0600` like the rollup,
/// because the accounting is what a watch token exists to withhold.
///
/// ## The age
///
/// The route answers `ageSeconds` on every reading and marks it `stale` past
/// `staleAfterSeconds`. A statusline renders only while a session is active,
/// so a reading ages whenever the human is away from every pane; the reading
/// stays exact while no other device spends the same account, and goes wrong
/// silently when one does. One hour is a fifth of the shortest window, and
/// the longest a bar may stand for without saying how old it is.
public struct UsageLimits: Codable, Equatable, Sendable {
    /// One window as the statusline sees it, and when. The first two names
    /// are the source's; `receivedAt` is the post that carried the window,
    /// epoch milliseconds, which is the reading's own time until a later
    /// post carries the other windows and not this one.
    public struct Window: Codable, Equatable, Sendable {
        public var used_percentage: Double
        public var resets_at: Int64
        public var receivedAt: Int64

        public init(used_percentage: Double, resets_at: Int64, receivedAt: Int64) {
            self.used_percentage = used_percentage
            self.resets_at = resets_at
            self.receivedAt = receivedAt
        }

        /// The same share and the same reset, whenever each was read.
        public func sameValue(as other: Window) -> Bool {
            used_percentage == other.used_percentage && resets_at == other.resets_at
        }

        /// Seconds since the post that carried this window, never negative.
        public func age(now: Date) -> Int {
            max(0, Int(now.timeIntervalSince1970) - Int(receivedAt / 1000))
        }
    }

    /// Epoch milliseconds, when the daemon took the newest post.
    public var receivedAt: Int64
    /// The windows by the statusline's key: `five_hour`, `seven_day`,
    /// `spend_limit`, or a key a later Claude Code adds; each from the
    /// newest post that carried it.
    public var rateLimits: [String: Window]

    public init(receivedAt: Int64, rateLimits: [String: Window]) {
        self.receivedAt = receivedAt
        self.rateLimits = rateLimits
    }

    /// Past this age the route says `stale: true`.
    public static let staleAfterSeconds = 3600
    /// A statusline body is a few hundred bytes; a post over this is a
    /// mistake or an attack.
    public static let maxBodyBytes = 4096
    /// Three windows today; room for a few more, never for a flood.
    public static let maxWindows = 8

    /// Why a body was refused, in the words the 400 carries.
    public struct Invalid: Error, Equatable, Sendable {
        public let reason: String
    }

    /// Parse the `rate_limits` object: every key names a window whose
    /// `used_percentage` is a finite non-negative number and whose
    /// `resets_at` is a positive whole number of seconds. Any other field in
    /// a window decodes away. An empty object is a reading with no window,
    /// which is what an API-key account or a session before its first
    /// response is given, and it is kept as such: the page then says that,
    /// rather than showing a bar it was never given.
    public static func parse(_ json: [String: Any], now: Date = Date()) -> Result<UsageLimits, Invalid> {
        let receivedAt = Int64(now.timeIntervalSince1970 * 1000)
        guard json.count <= maxWindows else {
            return .failure(Invalid(reason: "at most \(maxWindows) windows"))
        }
        var windows: [String: Window] = [:]
        for (key, value) in json {
            guard isWindowKey(key) else {
                return .failure(Invalid(reason: "window keys are lowercase words, like five_hour"))
            }
            guard let object = value as? [String: Any] else {
                return .failure(Invalid(reason: "\(key) must be {used_percentage, resets_at}"))
            }
            guard let used = number(object["used_percentage"]), used.isFinite, used >= 0 else {
                return .failure(Invalid(reason: "\(key).used_percentage must be a non-negative number"))
            }
            guard let resets = number(object["resets_at"]), resets.isFinite, resets > 0,
                  resets == resets.rounded(), resets < 1e12
            else {
                return .failure(Invalid(reason: "\(key).resets_at must be epoch seconds"))
            }
            windows[key] = Window(used_percentage: used, resets_at: Int64(resets), receivedAt: receivedAt)
        }
        return .success(UsageLimits(receivedAt: receivedAt, rateLimits: windows))
    }

    /// This reading with `post` on top: each window the post carries
    /// replaces the one held under its key, at the post's time; a window
    /// the post does not carry keeps its last value and time; the reading's
    /// time becomes the post's. Over `maxWindows`, the oldest windows go,
    /// so a source that renames its keys cannot grow the file without bound.
    public func merging(_ post: UsageLimits) -> UsageLimits {
        var windows = rateLimits
        for (key, window) in post.rateLimits { windows[key] = window }
        while windows.count > Self.maxWindows,
              let oldest = windows.min(by: { $0.value.receivedAt < $1.value.receivedAt || ($0.value.receivedAt == $1.value.receivedAt && $0.key < $1.key) })
        {
            windows.removeValue(forKey: oldest.key)
        }
        return UsageLimits(receivedAt: post.receivedAt, rateLimits: windows)
    }

    /// The same windows at the same values, whenever each was read.
    public func sameValues(as other: UsageLimits) -> Bool {
        guard rateLimits.count == other.rateLimits.count else { return false }
        return rateLimits.allSatisfy { key, window in
            other.rateLimits[key].map(window.sameValue(as:)) ?? false
        }
    }

    /// `[a-z][a-z0-9_]{0,31}`: the shape of `five_hour` and `spend_limit`.
    static func isWindowKey(_ key: String) -> Bool {
        guard let first = key.utf8.first, first >= 0x61, first <= 0x7A, key.utf8.count <= 32 else { return false }
        return key.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F
        }
    }

    /// A JSON number, refusing a JSON boolean: a `true` is not a percentage.
    /// Darwin's `JSONSerialization` hands back an `NSNumber` for both and
    /// only CoreFoundation tells them apart; Linux's hands back a `Bool`,
    /// and has no CoreFoundation, which the Linux build caught.
    private static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        #if canImport(Darwin)
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        return nil
        #else
        if value is Bool { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
        #endif
    }

    /// Seconds since the reading, never negative.
    public func age(now: Date) -> Int {
        max(0, Int(now.timeIntervalSince1970) - Int(receivedAt / 1000))
    }

    public func isStale(now: Date) -> Bool {
        age(now: now) > Self.staleAfterSeconds
    }
}

/// The reading the daemon keeps, merged from every post, and the file it
/// survives in.
///
/// Every method is synchronous under a lock. The routes hop onto `queue`
/// before they call one, so the disk write never runs on the event loop.
/// A statusline renders many times a second while a turn streams, and the
/// installed wrapper posts only when the object changed or a minute passed;
/// the store writes the file on the same rule, so an unchanged value costs a
/// compare and no write.
public final class UsageLimitsStore: @unchecked Sendable {
    /// Version 2 since round 18 of `agent-dashboard`: a time per window.
    /// A version-1 file still loads, every window at the file's time.
    public static let formatVersion = 2
    /// How often an unchanged reading is still written, so the file's
    /// `receivedAt` is never more than this behind the daemon's.
    public static let rewriteAfterSeconds = 60
    /// Where the HTTP routes run the store's disk I/O, off the event loop.
    static let queue = DispatchQueue(label: "kitterm.usage-limits")

    /// The file's window: version 1 wrote no time per window.
    private struct FileWindow: Codable {
        var used_percentage: Double
        var resets_at: Int64
        var receivedAt: Int64?
    }

    private struct FileShape: Codable {
        var version: Int
        var receivedAt: Int64
        var rateLimits: [String: FileWindow]
    }

    private let file: URL
    private let lock = NIOLock()
    private var current: UsageLimits?
    private var written: UsageLimits?

    public init(file: URL) {
        self.file = file
        let loaded = Self.load(file)
        current = loaded
        written = loaded
    }

    /// Take this post on top of what is held (`UsageLimits.merging`). The
    /// file is rewritten when a window's value changed or
    /// `rewriteAfterSeconds` passed since the last write.
    public func record(_ post: UsageLimits) {
        lock.withLock {
            let merged = current?.merging(post) ?? post
            current = merged
            if let written, written.sameValues(as: merged),
               merged.receivedAt - written.receivedAt < Int64(Self.rewriteAfterSeconds) * 1000 {
                return
            }
            persistLocked(merged)
        }
    }

    /// Every window held, at the newest post's time, or nil when no post
    /// has ever arrived.
    public var reading: UsageLimits? { lock.withLock { current } }

    /// The file's reading, or none when the file is absent, unreadable, or a
    /// version this build was not built for. A version-1 file held one post,
    /// so every window in it was read at the file's time.
    private static func load(_ file: URL) -> UsageLimits? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            let shape = try JSONDecoder().decode(FileShape.self, from: data)
            guard shape.version == 1 || shape.version == formatVersion else {
                FileHandle.standardError.write(Data(
                    "kitterm: ignoring \(file.path): format version \(shape.version), expected \(formatVersion)\n".utf8
                ))
                return nil
            }
            let windows = shape.rateLimits.mapValues { window in
                UsageLimits.Window(
                    used_percentage: window.used_percentage, resets_at: window.resets_at,
                    receivedAt: window.receivedAt ?? shape.receivedAt
                )
            }
            return UsageLimits(receivedAt: shape.receivedAt, rateLimits: windows)
        } catch {
            FileHandle.standardError.write(Data("kitterm: ignoring \(file.path): \(error)\n".utf8))
            return nil
        }
    }

    /// Caller holds `lock`. Whole-file atomic replace, then owner-only, the
    /// order `push.json` and `usage-daily.json` use.
    private func persistLocked(_ reading: UsageLimits) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let shape = FileShape(
                version: Self.formatVersion, receivedAt: reading.receivedAt,
                rateLimits: reading.rateLimits.mapValues {
                    FileWindow(used_percentage: $0.used_percentage, resets_at: $0.resets_at, receivedAt: $0.receivedAt)
                }
            )
            try encoder.encode(shape).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            written = reading
        } catch {
            FileHandle.standardError.write(Data("kitterm: cannot write \(file.path): \(error)\n".utf8))
        }
    }
}
