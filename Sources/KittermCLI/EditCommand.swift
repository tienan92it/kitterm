import Foundation

/// `kitterm edit [path]` (`code-editor` round 7, `corpus/04-quick-open.md`
/// item 2): the browser at `/edit` for a file or a folder, as `kitterm open`
/// opens a shell. The pure parts, `resolve`, `existing` and `url`, are what
/// the tests pin; `openInBrowser` starts the opener, and `KittermMain` owns
/// the daemon's port and start.
enum EditCommand {
    /// The absolute, standardized path `raw` names: `~` and `~/…` under
    /// `home`, a relative path under `cwd`, `.` and `..` folded; no argument
    /// is the cwd itself.
    static func resolve(_ raw: String?, cwd: String, home: String) -> String {
        let base = raw ?? "."
        let expanded: String
        if base == "~" {
            expanded = home
        } else if base.hasPrefix("~/") {
            expanded = home + base.dropFirst(1)
        } else if base.hasPrefix("/") {
            expanded = base
        } else {
            expanded = cwd + "/" + base
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// `path` when something is there (a file or a folder; the page decides
    /// which), else `CLIError.noSuchPath`, which the CLI prints with exit 1.
    static func existing(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { throw CLIError.noSuchPath(path: path) }
        return path
    }

    /// `http://kitterm.localhost:<port>/edit?path=<path>`, the host and the
    /// port `kitterm open` uses. The path is percent-encoded so that
    /// `URLSearchParams` on the page reads it back byte for byte: a bare `+`
    /// would decode as a space and a bare `&` would end the value, so only
    /// the unreserved characters and `/` stay as they are.
    static func url(port: Int, path: String) -> String {
        "http://kitterm.localhost:\(port)/edit?path=" + percentEncoded(path)
    }

    private static let bare = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )

    static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: bare) ?? text
    }

    /// Open `url` in the browser: `/usr/bin/open` on macOS, `xdg-open` on
    /// PATH elsewhere. False when no opener is here, so the caller prints
    /// the URL instead.
    static func openInBrowser(_ url: String) -> Bool {
        guard let launcher = opener() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcher)
        process.arguments = [url]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }

    private static func opener() -> String? {
        #if os(macOS)
        return "/usr/bin/open"
        #else
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/xdg-open"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
        #endif
    }
}
