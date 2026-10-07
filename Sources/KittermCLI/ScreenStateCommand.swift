import Foundation
import KittermDaemon

/// `kitterm screen-state stats [--days N] [--json]` — the count per state
/// and the share of `unknown` over a window, read from `ScreenStateLog`'s
/// two files with no daemon (`goal.md` condition 3). Default window: 7 days.
enum ScreenStateCommand {
    static let usage = "usage: kitterm screen-state stats [--days N] [--json]"
    static let defaultDays = 7

    /// Run one subcommand. `out` takes every line meant for stdout.
    static func run<S: Sequence>(_ args: S, out: (String) -> Void = { print($0) }) throws
    where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "stats":
            try stats(Array(array.dropFirst()), out: out)
        default:
            throw CLIError.usage(usage)
        }
    }

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
        out(json ? ScreenStateStats.json(for: summary) : ScreenStateStats.text(for: summary))
    }
}
