import Foundation
import KittermDaemon

/// The text `kitterm round close` writes: the round record, the edit of
/// `STATE.md`, and the line of a chore file. Pure functions of their
/// inputs, so a test pins every field with no daemon and no repository.
/// The shapes are `docs/goals/LOOP.md`, "Parsed shapes".
enum RoundRecord {
    /// The one line the command writes where only the foreman can write:
    /// the prompt, the floor, the effects, the gap, the decision, the
    /// reflection, and a chore's sentence. `round close --commit` refuses
    /// while one remains.
    static let marker = "[foreman writes this]"

    /// One session of the round, in the order the header names it.
    struct Session: Equatable {
        var id: String
        /// The model the transcript last answered with; nil with none.
        var model: String?
        /// `- Cost: …` or `- Cost: none recorded (<reason>)`.
        var costLine: String
    }

    struct Header: Equatable {
        var round: Int
        var task: String
        var goal: String
        var started: Date
        var ended: Date
        var sessions: [Session]
        var base: String
        var result: String
        var branch: String
        var pr: Int
        /// `- Foreman: …` or `- Foreman: none recorded (<reason>)`.
        var foremanLine: String
    }

    /// The record: the header in `LOOP.md`'s order, then the six sections,
    /// each holding the marker. `Floor` holds two marker lines, `before`
    /// and `after`.
    static func text(_ header: Header, zone: TimeZone = .current) -> String {
        let models = header.sessions.map { "\($0.id) (\($0.model ?? "no model"))" }.joined(separator: ", ")
        let archives = header.sessions.map(\.id).joined(separator: ", ")
        var lines = [
            String(format: "# Round %03d: %@", header.round, header.task),
            "",
            "- Goal: \(header.goal)",
            "- Started: \(stamp(header.started, zone: zone))  Ended: \(stamp(header.ended, zone: zone))",
            "- Sessions: \(models)   Archives: \(archives)",
            "- Base: \(header.base)   Result: \(header.result) on `\(header.branch)`, PR #\(header.pr)",
        ]
        lines += header.sessions.map(\.costLine)
        lines.append(header.foremanLine)
        for section in ["Prompt", "Floor", "Effects", "Gap", "Decision", "Reflection"] {
            lines += ["", "## \(section)", ""]
            lines += section == "Floor" ? ["before: \(marker)", "after: \(marker)"] : [marker]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `2026-11-11T14:04+07:00`: the minute, with the zone's offset.
    static func stamp(_ date: Date, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmxxx"
        return formatter.string(from: date)
    }

    /// `2026-11-11`, the day in the zone.
    static func day(_ date: Date, zone: TimeZone = .current) -> String {
        String(stamp(date, zone: zone).prefix(10))
    }

    /// The marker lines left in `text`.
    static func markerCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.contains(marker) }.count
    }

    // MARK: - The foreman line

    /// `- Foreman: ~$D · Nk in (C% cached) · Nk out`, the cost line's
    /// rounding with a `~`: an estimate from turns, not a bill. It starts
    /// with `- Foreman:`, so `KnowledgeSummary.costLine` and `GoalLedger`,
    /// which read `- Cost:` lines only, never count it. A model that
    /// `ModelPricing` does not know adds ` · unpriced <model>`: its tokens
    /// are in the line and its dollars are not, so `$D` is not read as whole.
    static func foremanLine(_ outcome: TranscriptEstimate.Outcome) -> String {
        switch outcome {
        case .estimate(let estimate):
            let percent = estimate.inTokens > 0
                ? Int((100 * Double(estimate.cacheReadTokens) / Double(estimate.inTokens)).rounded())
                : 0
            let unpriced = estimate.unpricedModels.isEmpty
                ? "" : " · unpriced " + estimate.unpricedModels.joined(separator: ", ")
            return String(
                format: "- Foreman: ~$%.2f · %dk in (%d%% cached) · %dk out",
                estimate.costUSD, ArchiveCommand.thousands(estimate.inTokens), percent,
                ArchiveCommand.thousands(estimate.outTokens)
            ) + unpriced
        case .noEstimate(let why): return foremanNone(why.rawValue)
        case .unreadable: return foremanNone("transcript not found")
        }
    }

    static func foremanNone(_ reason: String) -> String {
        "- Foreman: none recorded (\(reason))"
    }

    // MARK: - A chore

    /// `- <ISO date> · <marker> (<model>) · PR #N · Cost: …`, the one line
    /// of `docs/goals/chores/<ISO date>-<slug>.md` (`LOOP.md`, "Goal or
    /// chore"). The foreman replaces the marker with the sentence.
    static func choreLine(day: String, sessions: [Session], pr: Int) -> String {
        let models = Set(sessions.compactMap(\.model)).sorted()
        let model = models.isEmpty ? "" : " (\(models.joined(separator: ", ")))"
        let costs = sessions.map { $0.costLine.hasPrefix("- ") ? String($0.costLine.dropFirst(2)) : $0.costLine }
        return "- \(day) · \(marker)\(model) · PR #\(pr) · " + costs.joined(separator: " · ") + "\n"
    }

    // MARK: - STATE.md

    struct StateError: Error, Equatable {
        var reason: String
    }

    /// `state` after round `round` closed: `- Round:` counts it,
    /// `- Rounds total:` is at least `round`, `- Updated:` is `day`, and
    /// the item `task` moves from `## Queue` to `## Done` as
    /// ``- `<task>`, round R, `<sha>`, PR #N. See `rounds/NNN.md`.``.
    ///
    /// The counter `n` of `- Round: n of m` grows by the rounds that
    /// `Rounds total` has not counted yet, so a second run, which finds the
    /// total already at `round`, changes neither. `Last floor` and
    /// `Status` stay the foreman's. An item already under `## Done` with
    /// this round is not moved again.
    static func closeState(_ state: String, task: String, round: Int, sha: String, pr: Int, day: String) throws -> String {
        var lines = state.components(separatedBy: "\n")
        let total = bullet(lines, "Rounds total").flatMap { leadingInt($0.value) }
        guard let total else { throw StateError(reason: "STATE.md has no `- Rounds total: <n>` bullet") }
        let missing = max(0, round - total)
        if missing > 0, let counter = bullet(lines, "Round"), let n = leadingInt(counter.value) {
            let rest = counter.value.drop { $0.isNumber }
            lines[counter.index] = "- Round: \(n + missing)\(rest)"
        } else if bullet(lines, "Round") == nil {
            throw StateError(reason: "STATE.md has no `- Round: <n> of <m>` bullet")
        }
        if missing > 0, let line = bullet(lines, "Rounds total") {
            lines[line.index] = "- Rounds total: \(round)"
        }
        guard let updated = bullet(lines, "Updated") else {
            throw StateError(reason: "STATE.md has no `- Updated:` bullet")
        }
        lines[updated.index] = "- Updated: \(day)"

        let doneLine = "- `\(task)`, round \(round), `\(sha)`, PR #\(pr). See `rounds/\(String(format: "%03d", round)).md`."
        if let done = section(lines, "Done"), lines[done].contains(where: { $0.hasPrefix("- `\(task)`, round \(round),") }) {
            return lines.joined(separator: "\n")
        }
        guard let queue = section(lines, "Queue"), let item = item(lines, in: queue, task: task) else {
            throw StateError(reason: "no `\(task)` item under ## Queue or ## Done of STATE.md")
        }
        let others = queue.filter { !item.contains($0) && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        // The last item leaves prose that names no task, as the template has.
        lines.replaceSubrange(item, with: others.isEmpty ? ["None."] : [])
        guard let done = section(lines, "Done") else { throw StateError(reason: "STATE.md has no ## Done section") }
        // "None." alone is prose that names no task; the first item replaces it.
        if let none = lines[done].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "None." }),
           !lines[done].contains(where: { $0.hasPrefix("- ") || $0.hasPrefix("* ") }) {
            lines[none] = doneLine
        } else {
            let last = lines[done].lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? done.lowerBound
            lines.insert(doneLine, at: last + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// The first `- <key>:` bullet before the first `## ` heading.
    private static func bullet(_ lines: [String], _ key: String) -> (index: Int, value: String)? {
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("## ") { return nil }
            if line.hasPrefix("- \(key):") {
                return (index, line.dropFirst(key.count + 3).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func leadingInt(_ text: String) -> Int? {
        Int(text.prefix { $0.isNumber })
    }

    /// The lines under `## <name>`, up to the next heading.
    private static func section(_ lines: [String], _ name: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("## ") && $0.dropFirst(3).trimmingCharacters(in: .whitespaces) == name
        }) else { return nil }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("## "), !lines[end].hasPrefix("# ") { end += 1 }
        return (start + 1)..<end
    }

    /// The item `task` in `range`: its column-0 first line, whose text
    /// before the first comma names `` `task` ``, and its indented
    /// continuation lines.
    private static func item(_ lines: [String], in range: Range<Int>, task: String) -> Range<Int>? {
        for index in range {
            let line = lines[index]
            guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.first?.isNumber == true else { continue }
            let head = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard head.contains("`\(task)`") else { continue }
            var end = index + 1
            while end < range.upperBound, lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") { end += 1 }
            return index..<end
        }
        return nil
    }
}
