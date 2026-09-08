import Foundation

/// What the fleet view shows of a project's knowledge package
/// (`docs/goals/`), parsed from `STATE.md`, `goal.md`, the latest round
/// record, and the names under `rounds/`. Pure: text in, fields out. No
/// Markdown renderer, because the dashboard shows titles and links only.
///
/// Every field is optional. A missing file or a missing line leaves its
/// field absent; a malformed file is never an error, because the package
/// is hand-written and the card must still show what it can read.
public struct KnowledgeSummary: Equatable, Sendable {
    /// The suffix of the `# STATE: <slug>` heading.
    public var slug: String?
    /// The first `# ` heading of `goal.md`, without a `Goal:` prefix.
    public var goal: String?
    /// The value of the `- Status:` line of `STATE.md`.
    public var status: String?
    /// `N` of the `- Round: N of M` line.
    public var round: Int?
    /// `M` of the `- Round: N of M` line.
    public var budget: Int?
    /// The value of the `- Last floor:` line.
    public var lastFloor: String?
    /// The first paragraph of the `## Next action` section, capped at
    /// `nextActionCap` bytes.
    public var nextAction: String?
    /// Top-level bullets under `## Proposals waiting on the human`.
    public var proposals: Int?
    /// The highest `rounds/NNN.md` number.
    public var lastRound: Int?
    /// The first line of the latest round record's `## Decision` section.
    public var lastDecision: String?

    public static let nextActionCap = 512
    public static let lineCap = 256

    public init() {}

    /// Parse the package's texts. Each argument is nil when its file is
    /// missing or unreadable. `roundNames` holds the file names under
    /// `rounds/`; every name that is not `NNN.md` is ignored.
    public static func parse(
        state: String?, goal: String?, roundNames: [String], latestRound: String?
    ) -> KnowledgeSummary {
        var summary = KnowledgeSummary()
        if let goal {
            summary.goal = goalTitle(goal)
        }
        if let state {
            summary.slug = heading(state, prefix: "STATE:")
            summary.status = bulletValue(state, key: "Status")
            if let round = bulletValue(state, key: "Round") {
                let (n, m) = roundCounter(round)
                summary.round = n
                summary.budget = m
            }
            summary.lastFloor = bulletValue(state, key: "Last floor")
            summary.nextAction = firstParagraph(section(state, heading: "Next action"))
                .map { cap($0, bytes: nextActionCap) }
            if let proposals = section(state, heading: "Proposals waiting on the human") {
                summary.proposals = topLevelBullets(proposals)
            }
        }
        summary.lastRound = roundNames.compactMap(roundNumber).max()
        if let latestRound, let decision = section(latestRound, heading: "Decision") {
            summary.lastDecision = firstLine(decision).map { cap($0, bytes: lineCap) }
        }
        return summary
    }

    /// The JSON fields of the summary route, absent when nil.
    public var json: [String: Any] {
        var item: [String: Any] = [:]
        if let slug { item["slug"] = slug }
        if let goal { item["goal"] = goal }
        if let status { item["status"] = status }
        if let round { item["round"] = round }
        if let budget { item["budget"] = budget }
        if let lastFloor { item["lastFloor"] = lastFloor }
        if let nextAction { item["nextAction"] = nextAction }
        if let proposals { item["proposals"] = proposals }
        if let lastRound { item["lastRound"] = lastRound }
        if let lastDecision { item["lastDecision"] = lastDecision }
        return item
    }

    /// `rounds/NNN.md` → NNN. Nil for any other name.
    public static func roundNumber(_ name: String) -> Int? {
        guard name.hasSuffix(".md") else { return nil }
        let stem = name.dropLast(3)
        guard !stem.isEmpty, stem.allSatisfy(\.isNumber), let number = Int(stem) else { return nil }
        return number
    }

    /// The file name of round `number`: three digits, more when needed.
    public static func roundFileName(_ number: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, 3 - digits.count)) + digits + ".md"
    }

    // MARK: - pieces

    private static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
    }

    /// The first `# ` heading, trimmed, less a `Goal:` prefix.
    static func goalTitle(_ text: String) -> String? {
        guard let title = heading(text, prefix: nil) else { return nil }
        var value = title
        if value.lowercased().hasPrefix("goal:") {
            value = value.dropFirst("goal:".count).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? nil : cap(value, bytes: lineCap)
    }

    /// The text after the first `# ` heading; with `prefix`, only a heading
    /// that starts with it, and the text after the prefix.
    static func heading(_ text: String, prefix: String?) -> String? {
        for line in lines(text) where line.hasPrefix("# ") {
            var value = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if let prefix {
                guard value.hasPrefix(prefix) else { return nil }
                value = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
            return value.isEmpty ? nil : cap(value, bytes: lineCap)
        }
        return nil
    }

    /// The value of the first `- <key>:` bullet, trimmed and capped.
    static func bulletValue(_ text: String, key: String) -> String? {
        let marker = "- \(key):"
        for line in lines(text) where line.hasPrefix(marker) {
            let value = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : cap(value, bytes: lineCap)
        }
        return nil
    }

    /// `N of M …` → (N, M). Either is nil when the text does not hold it.
    static func roundCounter(_ value: String) -> (Int?, Int?) {
        let words = value.split(separator: " ")
        let n = words.first.flatMap { Int($0) }
        guard words.count >= 3, words[1] == "of" else { return (n, nil) }
        return (n, Int(words[2]))
    }

    /// The lines under `## <heading>` up to the next `## ` or `# ` heading.
    /// Nil when the heading is absent.
    static func section(_ text: String, heading: String) -> String? {
        let all = lines(text)
        guard let start = all.firstIndex(where: {
            $0.hasPrefix("## ") && $0.dropFirst(3).trimmingCharacters(in: .whitespaces) == heading
        }) else { return nil }
        var body: [Substring] = []
        for line in all[(start + 1)...] {
            if line.hasPrefix("## ") || line.hasPrefix("# ") { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    /// The first run of non-blank lines, joined with one space.
    static func firstParagraph(_ text: String?) -> String? {
        guard let text else { return nil }
        var paragraph: [String] = []
        for line in lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if paragraph.isEmpty { continue }
                break
            }
            paragraph.append(trimmed)
        }
        return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
    }

    /// The first non-blank line, trimmed.
    static func firstLine(_ text: String) -> String? {
        for line in lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Bullets at column 0 (`- ` or `* `); an indented bullet is a sub-item.
    static func topLevelBullets(_ text: String) -> Int {
        lines(text).filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }.count
    }

    /// The longest prefix of at most `bytes` UTF-8 bytes that ends on a
    /// character boundary.
    static func cap(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var out = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            if used + size > bytes { break }
            out.append(character)
            used += size
        }
        return out
    }
}
