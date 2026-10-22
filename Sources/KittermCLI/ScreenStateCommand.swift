import Foundation
import KittermDaemon

/// `kitterm screen-state …`, read from the state directory with no daemon:
///
/// - `stats [--days N] [--json]` — the count per state and the share of
///   `unknown` over a window, from `ScreenStateLog`'s two files (`goal.md`
///   condition 3). Default window: 7 days. One line after the counts says
///   how many samples the capture holds and whether it is on.
/// - `capture on|off|status` — the switch of the local capture of `unknown`
///   screens (`ScreenStateCapture.Settings`, `~/.kitterm/screen-state.json`).
/// - `samples [--print N] [--json] [--clear]` — the captured screens, newest
///   first; `--print N` prints the Nth file whole; `--clear` removes them.
enum ScreenStateCommand {
    static let usage = """
        usage: kitterm screen-state stats [--days N] [--json]
               kitterm screen-state capture on|off|status
               kitterm screen-state samples [--print N] [--json] [--clear]
        """
    static let defaultDays = 7

    /// Run one subcommand. `out` takes every line meant for stdout.
    static func run<S: Sequence>(_ args: S, out: (String) -> Void = { print($0) }) throws
    where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "stats":
            try stats(Array(array.dropFirst()), out: out)
        case "capture":
            try capture(Array(array.dropFirst()), out: out)
        case "samples":
            try samples(Array(array.dropFirst()), out: out)
        default:
            throw CLIError.usage(usage)
        }
    }

    // MARK: - stats

    private static func stats(_ args: [String], out: (String) -> Void) throws {
        var days = defaultDays
        var json = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json":
                json = true
            case "--days":
                index += 1
                guard index < args.count, let value = Int(args[index]), value > 0 else {
                    throw CLIError.usage(usage)
                }
                days = value
            default:
                throw CLIError.usage(usage)
            }
            index += 1
        }

        let current = DaemonPaths.screenStateLogFile
        let rotated = current.deletingLastPathComponent()
            .appendingPathComponent(current.lastPathComponent + ".1")
        guard FileManager.default.fileExists(atPath: current.path)
            || FileManager.default.fileExists(atPath: rotated.path)
        else {
            out("No screen-state log yet: call screen_state at least once (\(current.path)).")
            return
        }

        let entries = ScreenStateStats.entries(current: current, rotated: rotated)
        let summary = ScreenStateStats.summarize(entries, window: ScreenStateStats.window(days: days))
        let captureOn = ScreenStateCapture.Settings.read().captureUnknown
        let sampleCount = (try? ScreenStateCapture.samples().count) ?? 0
        if json {
            out(ScreenStateStats.json(for: summary, samples: sampleCount, captureOn: captureOn))
        } else {
            out(ScreenStateStats.text(for: summary))
            out("samples: \(sampleCount) (capture \(captureOn ? "on" : "off"))")
        }
    }

    // MARK: - capture

    private static func capture(_ args: [String], out: (String) -> Void) throws {
        guard args.count == 1 else { throw CLIError.usage(usage) }
        let file = DaemonPaths.screenStateSettingsFile
        switch args[0] {
        case "on", "off":
            let on = args[0] == "on"
            try ScreenStateCapture.Settings(captureUnknown: on).write(to: file)
            out("capture: \(on ? "on" : "off") (\(file.path))")
            if on {
                out("unknown screens are written to \(DaemonPaths.screenUnknownDirectory.path); they never leave this machine")
            }
        case "status":
            let on = ScreenStateCapture.Settings.read(from: file).captureUnknown
            out("capture: \(on ? "on" : "off")")
        default:
            throw CLIError.usage(usage)
        }
    }

    // MARK: - samples

    private static func samples(_ args: [String], out: (String) -> Void) throws {
        var printIndex: Int?
        var json = false
        var clear = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json":
                json = true
            case "--clear":
                clear = true
            case "--print":
                index += 1
                guard index < args.count, let value = Int(args[index]), value > 0 else {
                    throw CLIError.usage(usage)
                }
                printIndex = value
            default:
                throw CLIError.usage(usage)
            }
            index += 1
        }
        guard !(clear && (json || printIndex != nil)) else { throw CLIError.usage(usage) }

        let directory = DaemonPaths.screenUnknownDirectory
        if clear {
            let removed = try ScreenStateCapture.clear(in: directory)
            out("Removed \(removed) sample\(removed == 1 ? "" : "s") from \(directory.path).")
            return
        }

        let entries = try ScreenStateCapture.samples(in: directory)
        if let printIndex {
            guard printIndex <= entries.count else {
                throw CLIError.usage("no sample \(printIndex): \(entries.count) sample\(entries.count == 1 ? "" : "s") exist")
            }
            let text = try String(contentsOf: entries[printIndex - 1].url, encoding: .utf8)
            out(text.hasSuffix("\n") ? String(text.dropLast()) : text)
            return
        }

        if json {
            out(jsonList(entries))
            return
        }
        guard !entries.isEmpty else {
            let on = ScreenStateCapture.Settings.read().captureUnknown
            out("No samples in \(directory.path) (capture \(on ? "on" : "off")).")
            return
        }
        let formatter = ScreenStateLog.isoFormatter()
        for (position, entry) in entries.enumerated() {
            let at = entry.at.map { formatter.string(from: $0) } ?? "-"
            let session = entry.session.isEmpty ? "-" : entry.session
            let program = entry.program.isEmpty ? "-" : entry.program
            let size = entry.size.isEmpty ? "-" : entry.size
            out("\(position + 1)\t\(at)\t\(session)\t\(program)\t\(size)\t\(entry.bytes) bytes")
        }
    }

    private static func jsonList(_ entries: [ScreenStateCapture.Entry]) -> String {
        let formatter = ScreenStateLog.isoFormatter()
        let list: [[String: Any]] = entries.enumerated().map { position, entry in
            [
                "index": position + 1,
                "file": entry.url.path,
                "at": entry.at.map { formatter.string(from: $0) } ?? NSNull(),
                "session": entry.session,
                "program": entry.program,
                "size": entry.size,
                "bytes": entry.bytes,
            ]
        }
        let payload: [String: Any] = ["ok": true, "samples": list]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.withoutEscapingSlashes, .sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
