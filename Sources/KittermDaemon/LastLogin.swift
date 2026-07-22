import Darwin
import Foundation

/// The `Last login:` banner a native terminal shows when a shell starts.
///
/// Terminal.app gets this from `login(1)`, which reads utmpx. kitterm spawns
/// the shell directly — going through `login` would mean reworking the
/// controlling-TTY setup that Ctrl+C depends on — so the banner is produced
/// here instead, and "last login" means *the previous kitterm session* rather
/// than the last console login. That is both cheaper and more useful: the
/// utmpx answer would be the same stale boot-time login in every pane.
public enum LastLogin {
    /// `Wed Jul 22 18:04:25` — the format `login(1)` prints.
    ///
    /// Assembled in pieces because the day uses `%e` (space-padded), which ICU
    /// date patterns cannot express; `en_US_POSIX` keeps the weekday and month
    /// English regardless of the user's locale, matching login(1)'s C locale.
    static func formatted(_ date: Date, tty: String, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        formatter.dateFormat = "EEE MMM"
        let prefix = formatter.string(from: date)
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: date)
        let day = calendar.component(.day, from: date)

        return "Last login: \(prefix) \(String(format: "%2d", day)) \(time) on \(tty)\r\n"
    }

    /// `/dev/ttys073` → `ttys073`, matching what `login(1)` prints.
    static func ttyName(forSlave fd: Int32) -> String? {
        guard let raw = ttyname(fd) else { return nil }
        let path = String(cString: raw)
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/dev/") ? String(path.dropFirst("/dev/".count)) : path
    }

    /// A shell is quiet when `~/.hushlogin` exists — the long-standing opt-out
    /// that `login(1)` honours, so we honour it too.
    static func isHushed(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".hushlogin").path)
    }

    /// Read the previous session's timestamp, then record this one.
    ///
    /// Returns nil the very first time, when there is no previous session to
    /// report — a banner claiming "last login: just now" would be a lie.
    static func rotate(now: Date = Date(), file: URL = DaemonPaths.lastLoginFile) -> Date? {
        let previous = readTimestamp(file)
        writeTimestamp(now, to: file)
        return previous
    }

    /// The banner for a newly spawned shell, or nil when there is nothing to
    /// show (first run, hushed, or an unknown tty).
    public static func banner(
        forSlave fd: Int32,
        now: Date = Date(),
        file: URL = DaemonPaths.lastLoginFile
    ) -> String? {
        guard !isHushed() else { return nil }
        guard let tty = ttyName(forSlave: fd) else { return nil }
        guard let previous = rotate(now: now, file: file) else { return nil }
        return formatted(previous, tty: tty)
    }

    private static func readTimestamp(_ file: URL) -> Date? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        guard let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func writeTimestamp(_ date: Date, to file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "\(date.timeIntervalSince1970)".write(to: file, atomically: true, encoding: .utf8)
    }
}
