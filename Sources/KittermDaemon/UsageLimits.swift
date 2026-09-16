import Foundation
import NIOConcurrencyHelpers

/// The newest quota reading a Claude Code statusline render gave the daemon,
/// on disk at `~/.kitterm/usage-limits.json`.
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
/// (`kitterm statusline install` teaches it to), and the daemon keeps only
/// the newest post: the quota is one account's, so a later reading from any
/// session replaces an earlier one from any other.
///
/// ## What the file holds
///
/// `version`, `receivedAt` in epoch milliseconds, and `rateLimits`, the
/// object as it was posted, with the statusline's own field names. The file
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
    /// One window as the statusline sees it. The names are the source's.
    public struct Window: Codable, Equatable, Sendable {
        public var used_percentage: Double
        public var resets_at: Int64

        public init(used_percentage: Double, resets_at: Int64) {
            self.used_percentage = used_percentage
            self.resets_at = resets_at
        }
    }

    /// Epoch milliseconds, when the daemon took the post.
    public var receivedAt: Int64
    /// The windows by the statusline's key: `five_hour`, `seven_day`,
    /// `spend_limit`, or a key a later Claude Code adds.
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
            windows[key] = Window(used_percentage: used, resets_at: Int64(resets))
        }
        return .success(UsageLimits(receivedAt: Int64(now.timeIntervalSince1970 * 1000), rateLimits: windows))
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

/// The one reading the daemon keeps, and the file it survives in.
///
/// Every method is synchronous under a lock. The routes hop onto `queue`
/// before they call one, so the disk write never runs on the event loop.
/// A statusline renders many times a second while a turn streams, and the
/// installed wrapper posts only when the object changed or a minute passed;
/// the store writes the file on the same rule, so an unchanged value costs a
/// compare and no write.
public final class UsageLimitsStore: @unchecked Sendable {
    public static let formatVersion = 1
    /// How often an unchanged reading is still written, so the file's
    /// `receivedAt` is never more than this behind the daemon's.
    public static let rewriteAfterSeconds = 60
    /// Where the HTTP routes run the store's disk I/O, off the event loop.
    static let queue = DispatchQueue(label: "kitterm.usage-limits")

    private struct FileShape: Codable {
        var version: Int
        var receivedAt: Int64
        var rateLimits: [String: UsageLimits.Window]
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

    /// Keep this reading as the newest. The file is rewritten when the
    /// windows changed or `rewriteAfterSeconds` passed since the last write.
    public func record(_ reading: UsageLimits) {
        lock.withLock {
            current = reading
            if let written, written.rateLimits == reading.rateLimits,
               reading.receivedAt - written.receivedAt < Int64(Self.rewriteAfterSeconds) * 1000 {
                return
            }
            persistLocked(reading)
        }
    }

    /// The newest reading, or nil when none has ever arrived.
    public var reading: UsageLimits? { lock.withLock { current } }

    /// The file's reading, or none when the file is absent, unreadable, or a
    /// version this build was not built for.
    private static func load(_ file: URL) -> UsageLimits? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            let shape = try JSONDecoder().decode(FileShape.self, from: data)
            guard shape.version == formatVersion else {
                FileHandle.standardError.write(Data(
                    "kitterm: ignoring \(file.path): format version \(shape.version), expected \(formatVersion)\n".utf8
                ))
                return nil
            }
            return UsageLimits(receivedAt: shape.receivedAt, rateLimits: shape.rateLimits)
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
            let shape = FileShape(version: Self.formatVersion, receivedAt: reading.receivedAt, rateLimits: reading.rateLimits)
            try encoder.encode(shape).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            written = reading
        } catch {
            FileHandle.standardError.write(Data("kitterm: cannot write \(file.path): \(error)\n".utf8))
        }
    }
}
