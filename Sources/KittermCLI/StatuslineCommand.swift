import Foundation

/// `kitterm statusline install|print` — teach Claude Code's statusline to
/// post its `rate_limits` object to the daemon (`POST /api/usage/limits`),
/// without taking the human's own statusline over.
///
/// ## Wrap, never append
///
/// The human's `~/.claude/statusline.sh` is theirs: it reads stdin once into
/// a variable, prints its line, and may be replaced by them tomorrow. A
/// snippet appended to it would have to know how that file holds stdin, and
/// would be lost with the file. So `install` writes a wrapper of its own
/// beside it, `<dir>/kitterm-statusline.sh`, and points
/// `settings.json`'s `statusLine.command` at the wrapper. The wrapper reads
/// stdin once, posts the `rate_limits` object in the background, then hands
/// the same bytes to the command that was configured before, on a marked
/// line a reinstall reads back. Their file is not opened. A human with no
/// statusline gets a wrapper that posts and prints nothing.
///
/// ## Never slow the prompt
///
/// A statusline runs on every render and the human sees its delay. The post
/// is one `curl` in the background with a 2 s cap and every descriptor
/// closed, so the script exits before the connection opens, and it runs only
/// when the object changed since the last post or a minute passed, so a
/// streaming turn that renders many times a second posts once. It is skipped
/// outright when the port file is absent (no daemon), when `jq` is missing,
/// or when the render carries no `rate_limits`. The port is read from the
/// daemon's own port file at render time, so the wrapper follows a daemon
/// that moves and never carries a stale port.
///
/// ## The settings file
///
/// `settings.json` is read as JSON and written back pretty-printed with
/// `statusLine.type` and `statusLine.command` set and every other key kept.
/// Claude Code rewrites the same file the same way from `/config`. A file
/// that is not a JSON object is an error, not a guess.
enum StatuslineCommand {
    static let usage = "usage: kitterm statusline install [--dir <claude config dir>] | print"
    static let wrapperName = "kitterm-statusline.sh"
    /// The line in the wrapper above the previous statusline's command, which
    /// a reinstall reads to keep it.
    static let innerMarker = "# The statusline that was configured before kitterm's:"

    /// `$CLAUDE_CONFIG_DIR`, else `~/.claude`: where Claude Code reads
    /// `settings.json`.
    static var defaultDirectory: String {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return dir }
        return NSHomeDirectory() + "/.claude"
    }

    static func run<S: Sequence>(_ args: S, out: (String) -> Void = { print($0) }) throws
    where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "install":
            try install(directory: try directory(Array(array.dropFirst())), out: out)
        case "print":
            guard array.count == 1 else { throw CLIError.usage(usage) }
            out(wrapper(inner: nil))
        default:
            throw CLIError.usage(usage)
        }
    }

    /// Parse `[--dir <path>]`, the way `kitterm skills install` does.
    private static func directory(_ args: [String]) throws -> String {
        var directory: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--dir":
                guard index + 1 < args.count else { throw CLIError.usage("--dir needs a value") }
                directory = args[index + 1]
                index += 2
                continue
            case _ where arg.hasPrefix("--dir="):
                directory = String(arg.dropFirst("--dir=".count))
            default:
                throw CLIError.usage("unknown option \(arg)\n\(usage)")
            }
            index += 1
        }
        guard let directory else { return defaultDirectory }
        guard !directory.isEmpty else { throw CLIError.usage("--dir needs a value") }
        if directory == "~" || directory.hasPrefix("~/") {
            return NSHomeDirectory() + directory.dropFirst()
        }
        if directory.hasPrefix("/") { return directory }
        return FileManager.default.currentDirectoryPath + "/" + directory
    }

    /// Write the wrapper and point `settings.json` at it. Prints one line per
    /// file, `wrote`, `updated` or `unchanged`, then one line naming the
    /// statusline the wrapper hands stdin to.
    static func install(directory: String, out: (String) -> Void) throws {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let wrapperFile = root.appendingPathComponent(wrapperName)
        let settingsFile = root.appendingPathComponent("settings.json")

        var settings = try readSettings(settingsFile)
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        let configured = statusLine["type"] as? String == "command" ? statusLine["command"] as? String : nil

        // The command to hand stdin to: what settings.json names, unless it
        // already names the wrapper, in which case the wrapper's own marked
        // line holds it from the last install.
        let inner: String?
        if let configured, !namesWrapper(configured, wrapperFile) {
            inner = configured
        } else {
            inner = innerOf(try? String(contentsOf: wrapperFile, encoding: .utf8))
        }
        if let inner, inner.contains("\n") {
            throw CLIError.usage("statusLine.command spans several lines; the wrapper hands stdin to one line")
        }

        let bytes = Data(wrapper(inner: inner).utf8)
        let existing = try? Data(contentsOf: wrapperFile)
        if existing == bytes {
            out("unchanged \(wrapperFile.path)")
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: wrapperFile, options: .atomic)
            out("\(existing == nil ? "wrote" : "updated") \(wrapperFile.path)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperFile.path)

        if configured.map({ namesWrapper($0, wrapperFile) }) == true {
            out("unchanged \(settingsFile.path)")
        } else {
            statusLine["type"] = "command"
            statusLine["command"] = wrapperFile.path
            settings["statusLine"] = statusLine
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try (data + Data("\n".utf8)).write(to: settingsFile, options: .atomic)
            out("\(configured == nil && existing == nil ? "wrote" : "updated") \(settingsFile.path)")
        }

        if let inner {
            out("the wrapper posts rate_limits, then hands stdin to: \(inner)")
        } else {
            out("no statusline was configured before; the wrapper posts rate_limits and prints nothing")
        }
        if !onPath("jq") {
            FileHandle.standardError.write(Data("kitterm: jq is not on PATH; the wrapper posts nothing until it is\n".utf8))
        }
    }

    /// `settings.json` as a JSON object; an empty object when the file is
    /// absent. A file that exists and is not a JSON object is refused.
    static func readSettings(_ file: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.usage("\(file.path) is not a JSON object; fix it before installing")
        }
        return object
    }

    /// Does a configured command name the wrapper, spelled absolute or with
    /// a leading `~`?
    static func namesWrapper(_ command: String, _ wrapper: URL) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed == wrapper.path { return true }
        let home = NSHomeDirectory()
        return wrapper.path.hasPrefix(home + "/") && trimmed == "~" + wrapper.path.dropFirst(home.count)
    }

    /// The previous statusline's command from an installed wrapper: the
    /// line under `innerMarker`, less the `printf | ` that pipes to it.
    static func innerOf(_ contents: String?) -> String? {
        guard let contents else { return nil }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard let at = lines.firstIndex(of: Substring(innerMarker)), at + 1 < lines.count else { return nil }
        let line = lines[at + 1]
        guard line.hasPrefix(pipePrefix) else { return nil }
        return String(line.dropFirst(pipePrefix.count))
    }

    private static let pipePrefix = "printf '%s' \"$input\" | "

    /// The wrapper's text. `inner` is the command it hands stdin to, spelled
    /// exactly as `settings.json` held it, so it runs as Claude Code ran it.
    static func wrapper(inner: String?) -> String {
        let tail: String
        if let inner {
            tail = """
                \(innerMarker)
                \(pipePrefix)\(inner)
                """
        } else {
            tail = "# No statusline was configured before kitterm's; nothing is printed."
        }
        return """
            #!/usr/bin/env bash
            # kitterm statusline wrapper, written by `kitterm statusline install`.
            #
            # Claude Code hands every statusline render a JSON object on stdin. This
            # script posts its `rate_limits` object to the kitterm daemon, so the fleet
            # view can show the quota bars, then hands the same stdin to the statusline
            # that was configured before. Run `kitterm statusline install` again after
            # changing statusLine.command by hand.
            #
            # The post never delays the prompt: it runs in the background with a 2 s
            # cap and every descriptor closed, and only when the object changed since
            # the last post or a minute passed. It is skipped when the render carries
            # no rate_limits (an API-key account, or a session before its first
            # response), when jq is missing, or when the daemon's port file is absent.
            set -uo pipefail
            input=$(cat)

            limits=$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
            port_file="${KITTERM_STATE_DIR:-$HOME/.kitterm}/port"
            if [ -n "$limits" ] && [ -r "$port_file" ]; then
              port=$(tr -d '[:space:]' < "$port_file")
              cache="${TMPDIR:-/tmp}/kitterm-limits-${UID:-0}"
              if [ "$(cat "$cache" 2>/dev/null)" != "$limits" ] || [ -n "$(find "$cache" -mmin +1 2>/dev/null)" ]; then
                printf '%s' "$limits" > "$cache" 2>/dev/null
                curl -s -m 2 -o /dev/null -X POST "http://127.0.0.1:${port}/api/usage/limits" \\
                  -H 'content-type: application/json' --data-binary "$limits" </dev/null >/dev/null 2>&1 &
              fi
            fi

            \(tail)

            """
    }

    private static func onPath(_ name: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }
}
