import Foundation

/// Reads `ScreenStateLog`'s two files and counts the states over a window,
/// for `kitterm screen-state stats`. Pure and file-based, so a test points
/// it at a fixture pair instead of the real state directory.
enum ScreenStateStats {
    /// The order `goal.md`'s table and `ScreenState.Value` list the states
    /// in; `text(for:)` prints every one of these even at zero, then any
    /// other state name a log line happened to carry, sorted.
    static let stateOrder = [
        "prompt-empty", "prompt-has-text", "working", "waiting-on-own-job",
        "trust-dialog", "permission-dialog", "agent-exited", "unknown",
    ]

    struct Entry: Equatable {
        let at: Date
        let state: String
    }

    struct Window: Equatable {
        let days: Int
        let from: Date
        let to: Date
    }

    struct Summary: Equatable {
        let window: Window
        let counts: [String: Int]
        let total: Int

        var unknownSharePercent: Int {
            guard total > 0 else { return 0 }
            let unknown = counts["unknown"] ?? 0
            return Int((100 * Double(unknown) / Double(total)).rounded())
        }
    }

    /// One complete JSON line per entry; a line that fails to parse is
    /// skipped, never a reason to fail the whole read. The rotated file is
    /// read first, so entries come back oldest first.
    static func entries(current: URL, rotated: URL) -> [Entry] {
        var result: [Entry] = []
        for url in [rotated, current] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for lineData in data.split(separator: UInt8(ascii: "\n")) where !lineData.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                      let atText = object["at"] as? String,
                      let state = object["state"] as? String,
                      let at = ScreenStateLog.parseDate(atText)
                else { continue }
                result.append(Entry(at: at, state: state))
            }
        }
        return result
    }

    static func window(days: Int, now: Date = Date()) -> Window {
        Window(days: days, from: now.addingTimeInterval(-Double(days) * 86400), to: now)
    }

    static func summarize(_ entries: [Entry], window: Window) -> Summary {
        var counts: [String: Int] = [:]
        var total = 0
        for entry in entries where entry.at >= window.from && entry.at <= window.to {
            counts[entry.state, default: 0] += 1
            total += 1
        }
        return Summary(window: window, counts: counts, total: total)
    }

    // MARK: - rendering

    static func text(for summary: Summary) -> String {
        let formatter = ScreenStateLog.isoFormatter()
        var lines = [
            "screen-state stats: last \(summary.window.days) days "
                + "(\(formatter.string(from: summary.window.from)) to \(formatter.string(from: summary.window.to)))",
        ]
        var seen = Set<String>()
        for state in stateOrder {
            seen.insert(state)
            lines.append("\(state): \(summary.counts[state] ?? 0)")
        }
        for state in summary.counts.keys.sorted() where !seen.contains(state) {
            lines.append("\(state): \(summary.counts[state] ?? 0)")
        }
        lines.append("total: \(summary.total)")
        lines.append("unknown share: \(summary.unknownSharePercent)%")
        return lines.joined(separator: "\n")
    }

    static func json(for summary: Summary) -> String {
        let formatter = ScreenStateLog.isoFormatter()
        let payload: [String: Any] = [
            "ok": true,
            "days": summary.window.days,
            "from": formatter.string(from: summary.window.from),
            "to": formatter.string(from: summary.window.to),
            "total": summary.total,
            "unknownSharePercent": summary.unknownSharePercent,
            "counts": summary.counts,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.withoutEscapingSlashes, .sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
