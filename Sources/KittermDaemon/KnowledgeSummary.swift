import Foundation

/// What the fleet view shows of one goal folder (`docs/goals/<slug>/`),
/// parsed from `STATE.md`, `goal.md`, the latest round record, and the
/// names under `rounds/`. Pure: text in, fields out. No Markdown renderer,
/// because the dashboard shows titles and links only.
/// `KnowledgeFile.summaries` lists a package's goal folders and parses each.
///
/// Every field is optional. A missing file or a missing line leaves its
/// field absent; a malformed file is never an error, because the package
/// is hand-written and the card must still show what it can read.
public struct KnowledgeSummary: Equatable, Sendable {
    /// The goal folder's name, set by `KnowledgeFile.summaries`. A parse
    /// of texts alone reads the suffix of the `# STATE: <slug>` heading,
    /// which the folder name replaces on the route.
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
    /// The number of the highest-numbered `rounds/<N>.md`.
    public var lastRound: Int?
    /// That record's path under the knowledge directory, by its real file
    /// name (`rounds/7.md` stays `rounds/7.md`), so a link opens the file
    /// that was read. `KnowledgeFile.summaries` prefixes the folder name,
    /// so the route answers `<slug>/rounds/NNN.md`.
    public var lastRecord: String?
    /// The first line of the latest round record's `## Decision` section.
    public var lastDecision: String?
    /// The sum of every `- Cost:` line over the goal's round records, in
    /// dollars at the full API rate, as `LOOP.md` defines the line; absent
    /// when no record carries one. The fleet view prints it beside the
    /// goal. `kitterm goal cost` reads the archived transcript where one
    /// still exists, so its total can differ from this by the line's
    /// rounding.
    public var costUSD: Double?
    /// The summed `Nk in` of those lines, in tokens: input, cache creation
    /// and cache read together.
    public var inTokens: Int?
    /// The cache-read part of `inTokens`, each line's `in` times its
    /// `C% cached`, so the page can print the share.
    public var cacheReadTokens: Int?
    /// The goal's tasks, the fourth level of the fleet view: one per slug
    /// listed under `## Queue` (pending), `## Failures` (failed) and
    /// `## Done` (done) of `STATE.md`, in that order, each slug once
    /// (`tasks(_:)`). Absent when `STATE.md` carries none of the three
    /// headings, so a goal that lists no tasks renders as it did before
    /// the level existed; empty when a heading is there and lists nothing.
    public var tasks: [Task]?
    /// One entry per `rounds/<N>.md`, by number: what the `WHERE` panel
    /// groups by goal and by task and what the `LEAKS` lines count
    /// (`agent-dashboard`, capability 7). Absent when the goal has no
    /// `rounds/` directory or no record in it.
    public var rounds: [RoundRecord]?

    /// One round record, the unit a crew runs (`LOOP.md`, "Round record").
    /// Every field but the number is absent when the record does not
    /// carry the line, so a round with no `- Cost:` line prices at nothing
    /// rather than at zero.
    public struct RoundRecord: Equatable, Sendable {
        public var number: Int
        /// The queue item after `# Round NNN:`, the value of the `task:`
        /// label.
        public var task: String?
        /// The `YYYY-MM-DD` the `- Started:` line begins with.
        public var started: String?
        /// The sum of the record's `- Cost:` lines (`costLines`).
        public var costUSD: Double?
        /// The summed `Hh Mm` of those lines, in milliseconds.
        public var durationMs: Int?
        /// The `PR #N` a `- Result:` bullet names, else the one after
        /// `Result:` on the `- Base:` line (`roundRecord`).
        public var pr: Int?
        /// The record carries a `## Correction` section: the one correction
        /// `LOOP.md` allows a round was spent.
        public var correction: Bool

        public init(
            number: Int, task: String? = nil, started: String? = nil, costUSD: Double? = nil,
            durationMs: Int? = nil, pr: Int? = nil, correction: Bool = false
        ) {
            self.number = number
            self.task = task
            self.started = started
            self.costUSD = costUSD
            self.durationMs = durationMs
            self.pr = pr
            self.correction = correction
        }

        public var json: [String: Any] {
            var entry: [String: Any] = ["number": number, "correction": correction]
            if let task { entry["task"] = task }
            if let started { entry["started"] = started }
            if let costUSD { entry["costUSD"] = costUSD }
            if let durationMs { entry["durationMs"] = durationMs }
            if let pr { entry["pr"] = pr }
            return entry
        }
    }

    /// The state a `STATE.md` section gives a task. `working` is not here:
    /// the page reads it from a live session's `task:` label.
    public enum TaskState: String, Equatable, Sendable {
        case pending, done, failed

        /// The state a reader needs most first: a failed task needs a
        /// person, a pending one says the loop runs it again, a done one
        /// needs nothing. A slug in two sections keeps the lower rank.
        var rank: Int {
            switch self {
            case .failed: return 0
            case .pending: return 1
            case .done: return 2
            }
        }
    }

    /// One task of a goal: a queue item as `LOOP.md` names it (the value
    /// of the `task:` label), with the round and the pull request its
    /// line names when it does.
    public struct Task: Equatable, Sendable {
        public var slug: String
        public var state: TaskState
        public var round: Int?
        public var pr: Int?

        public init(slug: String, state: TaskState, round: Int? = nil, pr: Int? = nil) {
            self.slug = slug
            self.state = state
            self.round = round
            self.pr = pr
        }
    }

    public static let nextActionCap = 512
    public static let lineCap = 256

    /// The statuses `LOOP.md` names, in the order goals are listed. Any
    /// other value, and a missing one, sorts after `done`.
    public static let statusOrder = ["active", "waiting", "stopped", "done"]

    public init() {}

    /// The listing order of the summary route and of `kitterm goal list`:
    /// by `statusOrder`, then by slug. Both call this one comparator, so
    /// the card and the CLI agree.
    public static func isOrderedBefore(_ a: KnowledgeSummary, _ b: KnowledgeSummary) -> Bool {
        let (ra, rb) = (statusRank(a.status), statusRank(b.status))
        return ra != rb ? ra < rb : (a.slug ?? "") < (b.slug ?? "")
    }

    /// The position of `status` in `statusOrder`; `statusOrder.count` for
    /// any other value or none.
    public static func statusRank(_ status: String?) -> Int {
        status.flatMap { statusOrder.firstIndex(of: $0) } ?? statusOrder.count
    }

    /// Parse the package's texts. Each argument is nil when its file is
    /// missing or unreadable. `roundNames` holds the file names under
    /// `rounds/`; every name that is not `<digits>.md` is ignored, and
    /// `latestRound` is the text of the highest-numbered one.
    public static func parse(
        state: String?, goal: String?, roundNames: [String], latestRound: String?
    ) -> KnowledgeSummary {
        parse(state: state, goal: goal, latestRecord: latestRecordName(roundNames), latestRound: latestRound)
    }

    /// The file name under `rounds/` with the highest number, nil when no
    /// name is `<digits>.md`. The caller reads that name, so the record the
    /// summary describes is the file the link opens.
    public static func latestRecordName(_ roundNames: [String]) -> String? {
        roundNames.compactMap { name in roundNumber(name).map { ($0, name) } }
            .max { $0.0 < $1.0 }?.1
    }

    /// Parse with the latest record named: `latestRecord` is its file name
    /// under `rounds/` and `latestRound` its text. The round number comes
    /// from the name, computed once here.
    public static func parse(
        state: String?, goal: String?, latestRecord: String?, latestRound: String?
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
            summary.tasks = tasks(state)
        }
        if let latestRecord, let number = roundNumber(latestRecord) {
            summary.lastRound = number
            summary.lastRecord = "rounds/" + latestRecord
        }
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
        if let lastRecord { item["lastRecord"] = lastRecord }
        if let lastDecision { item["lastDecision"] = lastDecision }
        if let costUSD { item["costUSD"] = costUSD }
        if let inTokens { item["inTokens"] = inTokens }
        if let cacheReadTokens { item["cacheReadTokens"] = cacheReadTokens }
        if let tasks {
            item["tasks"] = tasks.map { task -> [String: Any] in
                var entry: [String: Any] = ["slug": task.slug, "state": task.state.rawValue]
                if let round = task.round { entry["round"] = round }
                if let pr = task.pr { entry["pr"] = pr }
                return entry
            }
        }
        if let rounds { item["rounds"] = rounds.map(\.json) }
        return item
    }

    // MARK: - the round records

    /// Read one record, `rounds/<number>.md`. The task is the text after
    /// `# Round NNN:` on the first `# ` heading, trimmed; the date is the
    /// first ten characters of the `- Started:` value when they are a day;
    /// the cost and the duration sum the header's `- Cost:` lines; the
    /// correction is a `## Correction` heading.
    ///
    /// The PR is the first `PR #N` on a `- Result:` bullet, its own line;
    /// `LOOP.md`'s own shape instead puts `Result:` on the `- Base:` line
    /// (`- Base: <sha>   Result: <sha or PR #N>`), so a record with no
    /// `- Result:` bullet takes the first `PR #N` after `Result:` there.
    /// A `- Result:` bullet wins when a record somehow carries both. A
    /// result given as a sha, on either shape, names no PR.
    public static func roundRecord(number: Int, text: String) -> RoundRecord {
        var record = RoundRecord(number: number)
        if let title = heading(text, prefix: "Round") {
            // `001: the-item` → `the-item`.
            if let colon = title.firstIndex(of: ":") {
                let task = title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                record.task = task.isEmpty ? nil : task
            }
        }
        if let started = bulletValue(text, key: "Started") {
            let day = String(started.prefix(10))
            if DayKey(day) != nil { record.started = day }
        }
        let costs = costLines(text)
        if !costs.isEmpty {
            record.costUSD = costs.reduce(0) { $0 + $1.costUSD }
            record.durationMs = costs.reduce(0) { $0 + $1.durationMs }
        }
        if let result = bulletValue(text, key: "Result") {
            record.pr = firstNumber(prPattern, in: result)
        } else if let base = bulletValue(text, key: "Base"),
                  let resultRange = base.range(of: "Result:") {
            record.pr = firstNumber(prPattern, in: String(base[resultRange.upperBound...]))
        }
        record.correction = section(text, heading: "Correction") != nil
        return record
    }

    /// Every record given, by number.
    public mutating func readRounds(_ records: [(number: Int, text: String)]) {
        guard !records.isEmpty else { return }
        rounds = records.map { Self.roundRecord(number: $0.number, text: $0.text) }.sorted { $0.number < $1.number }
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

    // MARK: - the Cost line

    /// One `- Cost: $D · Nk in (C% cached) · Nk out · Hh Mm` line of a
    /// round record, as `LOOP.md` defines it, with the tokens scaled back
    /// to units. `GoalLedger` reads the same line through `costLine`, so the
    /// CLI and the route agree on the shape.
    public struct RecordCost: Equatable, Sendable {
        public var costUSD: Double
        public var inTokens: Int
        public var cachedPercent: Int
        public var outTokens: Int
        public var durationMs: Int

        public init(costUSD: Double, inTokens: Int, cachedPercent: Int, outTokens: Int, durationMs: Int) {
            self.costUSD = costUSD
            self.inTokens = inTokens
            self.cachedPercent = cachedPercent
            self.outTokens = outTokens
            self.durationMs = durationMs
        }

        /// `inTokens` times the percent, rounded: the cache-read tokens the
        /// line stands for, in one unit with a transcript's exact count.
        public var cacheReadTokens: Int {
            Int((Double(inTokens) * Double(cachedPercent) / 100).rounded())
        }
    }

    private static let costLinePattern: NSRegularExpression = {
        // The pattern is a literal; a typo is a programming error.
        try! NSRegularExpression(
            pattern: "^- Cost: \\$([0-9]+(?:\\.[0-9]+)?) · ([0-9]+)k in \\(([0-9]+)% cached\\) · ([0-9]+)k out · ([0-9]+)h ([0-9]+)m"
        )
    }()

    /// Parse one line of a record. Nil for a line that is not a `- Cost:`
    /// line, for `- Cost: none recorded (<reason>)`, and for a malformed one.
    public static func costLine(_ line: String) -> RecordCost? {
        let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
        guard text.hasPrefix("- Cost:") else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = costLinePattern.firstMatch(in: text, range: whole) else { return nil }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        guard let dollars = Double(group(1)), let inK = Int(group(2)), let percent = Int(group(3)),
              let outK = Int(group(4)), let hours = Int(group(5)), let minutes = Int(group(6))
        else { return nil }
        return RecordCost(
            costUSD: dollars, inTokens: inK * 1000, cachedPercent: percent,
            outTokens: outK * 1000, durationMs: (hours * 60 + minutes) * 60_000
        )
    }

    /// Every `- Cost:` line in a record's header, the lines before its
    /// first `## ` heading, in order. A `none recorded` line is skipped.
    public static func costLines(_ record: String) -> [RecordCost] {
        var costs: [RecordCost] = []
        for line in lines(record) {
            if line.hasPrefix("## ") { break }
            if let cost = costLine(String(line)) { costs.append(cost) }
        }
        return costs
    }

    /// Sum the `- Cost:` lines of every record given into `costUSD`,
    /// `inTokens` and `cacheReadTokens`. The three stay absent when no
    /// record carries a line, so a goal that predates the bill prints no
    /// number rather than a zero.
    public mutating func sumCosts(records: [String]) {
        let costs = records.flatMap(Self.costLines)
        guard !costs.isEmpty else { return }
        costUSD = costs.reduce(0) { $0 + $1.costUSD }
        inTokens = costs.reduce(0) { $0 + $1.inTokens }
        cacheReadTokens = costs.reduce(0) { $0 + $1.cacheReadTokens }
    }

    // MARK: - the tasks

    /// The sections that list tasks, in the order the list keeps them:
    /// the queue first because its head is what runs next, then the
    /// failures because they need a person, then the done ones, which are
    /// history.
    static let taskSections: [(heading: String, state: TaskState)] = [
        ("Queue", .pending), ("Failures", .failed), ("Done", .done),
    ]

    private static let slugPattern: NSRegularExpression = {
        // A backticked kebab slug, the shape `kitterm goal new` enforces on a
        // folder and `LOOP.md` gives a queue item. `rounds/001.md`,
        // `LiveTakeoverTests` and `sessions.css` in the same line do not match.
        try! NSRegularExpression(pattern: "`([a-z0-9]+(?:-[a-z0-9]+)*)`")
    }()
    private static let roundPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\brounds? ([0-9]+)")
    }()
    private static let prPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\bPR #([0-9]+)")
    }()

    /// The tasks `STATE.md` lists: every column-0 item (`- `, `* ` or
    /// `N. `) under `## Queue`, `## Failures` and `## Done`, each slug once
    /// with the state of the lowest `TaskState.rank`, in the order the
    /// slugs first appear. A slug is a backticked kebab word on the item's
    /// first line before its first comma, so ``- `a` (1) and `b` (2),
    /// round 1, `9784fd2`.`` yields `a` and `b` and not the sha; the round
    /// and the PR come from the whole first line. Prose under a heading
    /// (`None.`) yields nothing. Nil when none of the three headings is
    /// in the text.
    static func tasks(_ text: String) -> [Task]? {
        var found = false
        var tasks: [Task] = []
        var position: [String: Int] = [:]
        for (heading, state) in taskSections {
            guard let body = section(text, heading: heading) else { continue }
            found = true
            for line in itemLines(body) {
                let head = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
                let round = firstNumber(roundPattern, in: line)
                let pr = firstNumber(prPattern, in: line)
                for slug in matches(slugPattern, in: head) {
                    if let index = position[slug] {
                        if state.rank < tasks[index].state.rank {
                            tasks[index].state = state
                            tasks[index].round = round ?? tasks[index].round
                            tasks[index].pr = pr ?? tasks[index].pr
                        }
                        continue
                    }
                    position[slug] = tasks.count
                    tasks.append(Task(slug: slug, state: state, round: round, pr: pr))
                }
            }
        }
        return found ? tasks : nil
    }

    /// The first line of every column-0 item: `- `, `* `, or `N. `. An
    /// indented line is a continuation or a sub-item and is skipped.
    static func itemLines(_ text: String) -> [String] {
        lines(text).compactMap { line in
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return String(line.dropFirst(2)) }
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
            return String(line.dropFirst(digits.count + 2))
        }
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [String] {
        let whole = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: whole).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func firstNumber(_ pattern: NSRegularExpression, in text: String) -> Int? {
        matches(pattern, in: text).first.flatMap { Int($0) }
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
    /// Each number is the leading digits of its word, so `3 of 3, budget
    /// spent` keeps the budget.
    static func roundCounter(_ value: String) -> (Int?, Int?) {
        let words = value.split(separator: " ")
        let n = words.first.flatMap(leadingNumber)
        guard words.count >= 3, words[1] == "of" else { return (n, nil) }
        return (n, leadingNumber(words[2]))
    }

    /// The number the word starts with, nil when it starts with no digit.
    private static func leadingNumber(_ word: Substring) -> Int? {
        let digits = word.prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
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
    /// character boundary, with the C0 and C1 controls and the Unicode
    /// bidirectional formatting characters dropped: every field passes
    /// through here, and a right-to-left override in a heading would
    /// reorder the strip line on the dashboard.
    static func cap(_ text: String, bytes: Int) -> String {
        var out = ""
        var used = 0
        for character in text where !isControlOrBidi(character) {
            let size = character.utf8.count
            if used + size > bytes { break }
            out.append(character)
            used += size
        }
        return out
    }

    /// C0 (`U+0000`–`U+001F`, `U+007F`), C1 (`U+0080`–`U+009F`), and the
    /// bidi embeddings, overrides and isolates (`U+202A`–`U+202E`,
    /// `U+2066`–`U+2069`). A tab counts as a control too.
    private static func isControlOrBidi(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return value < 0x20 || (0x7F...0x9F).contains(value)
                || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
        }
    }
}
