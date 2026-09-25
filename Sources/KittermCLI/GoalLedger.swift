import Foundation
import KittermDaemon

/// `kitterm goal cost`: the ledger of a knowledge package, per goal and per
/// round, read from the round records and the archives.
///
/// ## Two sources, and which wins
///
/// A round record's `Cost:` line is rounded for reading: cents, whole
/// thousands of tokens, a whole percent, whole minutes. The transcript is
/// exact. For every session a record's `Sessions:` line names, the ledger
/// looks up the session's archive (`SessionArchive.agentJoin(of:)`, under
/// `DaemonPaths.archiveDirectory`, so `KITTERM_STATE_DIR` moves it); when
/// the archive names a transcript and `TranscriptBill` reads a bill from it,
/// those numbers are used and `--json` carries them unrounded under the
/// transcript's own field names. Otherwise the `Cost:` line at the same
/// position in the record is parsed. A record with neither predates the bill
/// and prints a dash; the footer counts those rounds.
///
/// ## What the other columns read
///
/// Files changed come from `git diff --name-only <base>..<result>` in the
/// checkout, with the first sha on the record's `Base:` line and the last on
/// its `Result:` line, because `totalLinesAdded` in the transcript reads 0
/// on a round that edits through heredocs. A round with no count prints a
/// dash and a footer that says why (`FilesChanged.reason`): the line that
/// names no sha, or git's status and what it wrote to stderr. Tests added is
/// the first `N new` in the record's `## Floor` section. The decision is the
/// first word of `## Decision`. The PR is the first `#N` on the `Result:`
/// line.
enum GoalLedger {
    // MARK: - The record

    /// The lines of one round record the ledger reads.
    struct Record: Equatable {
        var number: Int
        var slug: String
        /// The UUIDs on the `Sessions:` line, in order.
        var sessions: [UUID]
        /// The UUIDs after `Archives:` on that line; the sessions when the
        /// line says `the same` or names none.
        var archives: [UUID]
        var base: String?
        var result: String?
        var pr: Int?
        /// One entry per `- Cost:` line, in order; nil for `none recorded`.
        var costLines: [CostLine?]
        var testsAdded: Int?
        var decision: String?

        var hasCostLine: Bool { !costLines.isEmpty }
    }

    /// `- Cost: $D · Nk in (C% cached) · Nk out · Hh Mm`, as `LOOP.md`
    /// defines it, with the tokens scaled back to units.
    struct CostLine: Equatable {
        var costUSD: Double
        var inTokens: Int
        var cachedPercent: Int
        var outTokens: Int
        var durationMs: Int
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals below; a typo is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let uuidPattern = regex("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    /// A short or full sha: hex, 7 to 40 characters, as a whole word.
    private static let shaPattern = regex("\\b[0-9a-f]{7,40}\\b")
    private static let prPattern = regex("#([0-9]+)\\b")
    private static let newTestsPattern = regex("\\b([0-9]+) new\\b")
    private static let headingPattern = regex("^# Round ([0-9]+): (.+)$")

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [[String]] {
        let whole = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: whole).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// The shas in `text`, in order. The ones with a digit when there are
    /// any, else every hex word: a word like `deadbeef` or `effaced` is hex
    /// too, so a digit used to be required, but one short sha in a thousand
    /// is `a` to `f` alone (`dcaacec`), and that rule read a real sha as no
    /// sha and printed a dash for a round git could count (`green-ci-again`
    /// round 2). A hex word alone on a line is now taken and git says
    /// `unknown revision` in the footer, which is a fact where the dash was
    /// not.
    private static func shas(in text: String) -> [String] {
        let words = matches(shaPattern, in: text).map { $0[0] }
        let withDigit = words.filter { $0.contains(where: \.isNumber) }
        return withDigit.isEmpty ? words : withDigit
    }

    /// Parse one record's text. `number` is the file's `NNN`; the heading's
    /// slug is the queue item, or the file name when the heading is missing.
    static func parse(_ text: String, number: Int) -> Record {
        var record = Record(
            number: number, slug: String(format: "%03d", number), sessions: [], archives: [],
            base: nil, result: nil, pr: nil, costLines: [], testsAdded: nil, decision: nil
        )
        var section = ""
        var decisionText: String?
        var floorText = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let heading = matches(headingPattern, in: line).first {
                record.slug = heading[2].trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("## ") {
                section = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            switch section {
            case "":
                parseHeaderLine(line, into: &record)
            case "Floor":
                floorText += line + "\n"
            case "Decision":
                if decisionText == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    decisionText = line
                }
            default:
                break
            }
        }
        if let count = matches(newTestsPattern, in: floorText).first.flatMap({ Int($0[1]) }) {
            record.testsAdded = count
        }
        if let decisionText {
            let word = decisionText.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if !trimmed.isEmpty { record.decision = trimmed }
        }
        if record.archives.isEmpty { record.archives = record.sessions }
        return record
    }

    private static func parseHeaderLine(_ line: String, into record: inout Record) {
        if line.hasPrefix("- Sessions:") {
            let parts = line.components(separatedBy: "Archives:")
            record.sessions = matches(uuidPattern, in: parts[0]).compactMap { UUID(uuidString: $0[0]) }
            if parts.count > 1 {
                record.archives = matches(uuidPattern, in: parts[1]).compactMap { UUID(uuidString: $0[0]) }
            }
        } else if line.hasPrefix("- Base:") {
            let parts = line.components(separatedBy: "Result:")
            record.base = shas(in: parts[0]).first
            if parts.count > 1 {
                record.result = shas(in: parts[1]).last
                record.pr = matches(prPattern, in: parts[1]).first.flatMap { Int($0[1]) }
            }
        } else if line.hasPrefix("- Cost:") {
            // The daemon's parser, so the route's goal total and this
            // table read one shape.
            if let cost = KnowledgeSummary.costLine(line) {
                record.costLines.append(CostLine(
                    costUSD: cost.costUSD, inTokens: cost.inTokens, cachedPercent: cost.cachedPercent,
                    outTokens: cost.outTokens, durationMs: cost.durationMs
                ))
            } else {
                record.costLines.append(nil)
            }
        }
    }

    // MARK: - The bill

    /// One session's bill, from whichever source answered for it.
    struct SessionBill: Equatable {
        enum Source: String, Equatable { case transcript, line }
        var source: Source
        var costUSD: Double
        var durationMs: Int
        /// `inputTokens` + `cacheCreationInputTokens` + `cacheReadInputTokens`.
        var inTokens: Int
        /// Exact from a transcript; `in` times the line's percent from a line,
        /// so a total over both sources has one unit.
        var cacheRead: Int
        var outTokens: Int
        /// The transcript's own numbers, when the source is a transcript.
        var bill: TranscriptBill?

        init(bill: TranscriptBill) {
            source = .transcript
            costUSD = bill.totalCostUSD
            durationMs = bill.totalDuration
            let usage = bill.modelUsage.values
            let cacheRead = usage.reduce(0) { $0 + $1.cacheReadInputTokens }
            inTokens = usage.reduce(0) { $0 + $1.inputTokens + $1.cacheCreationInputTokens } + cacheRead
            self.cacheRead = cacheRead
            outTokens = usage.reduce(0) { $0 + $1.outputTokens }
            self.bill = bill
        }

        init(line: CostLine) {
            source = .line
            costUSD = line.costUSD
            durationMs = line.durationMs
            inTokens = line.inTokens
            cacheRead = Int((Double(line.inTokens) * Double(line.cachedPercent) / 100).rounded())
            outTokens = line.outTokens
            bill = nil
        }
    }

    /// What `git diff --name-only <base>..<result>` answered: the count, or
    /// why there is none. A dash in the table is a fact only when the reason
    /// is printed beside it, so every case but `count` carries one.
    enum FilesChanged: Equatable {
        case count(Int)
        /// The record's `Base:` or `Result:` line names no sha, so git was
        /// never asked. `line` names the one, `Base:`, `Result:` or both.
        case noSha(line: String)
        /// git could not be started; `error` is what `Process.run` threw.
        case notRun(error: String)
        /// git exited with `status` for `range` (`<base>..<result>`); `stderr`
        /// is what it said, whole.
        case failed(range: String, status: Int32, stderr: String)

        var count: Int? {
            if case .count(let value) = self { return value }
            return nil
        }

        /// One line for the table's footer and `--json`; nil for a count.
        /// A failure quotes git's first stderr line, which is where git puts
        /// its `fatal:`.
        var reason: String? {
            switch self {
            case .count:
                return nil
            case .noSha(let line):
                return "the \(line) line names no sha"
            case .notRun(let error):
                return "git did not start: \(error)"
            case .failed(let range, let status, let stderr):
                let said = stderr.split(separator: "\n").first.map(String.init) ?? "nothing on stderr"
                return "git diff --name-only \(range) exited \(status): \(said)"
            }
        }
    }

    /// One round of the ledger: the record, the bills its sessions answered,
    /// and the file count from git.
    struct Row: Equatable {
        var record: Record
        var bills: [SessionBill]
        var files: FilesChanged

        var filesChanged: Int? { files.count }

        var costUSD: Double { bills.reduce(0) { $0 + $1.costUSD } }
        var durationMs: Int { bills.reduce(0) { $0 + $1.durationMs } }
        var inTokens: Int { bills.reduce(0) { $0 + $1.inTokens } }
        var cacheRead: Int { bills.reduce(0) { $0 + $1.cacheRead } }
        var outTokens: Int { bills.reduce(0) { $0 + $1.outTokens } }
        var hasBill: Bool { !bills.isEmpty }

        /// `totalAPIDuration` summed over the round's bills, only when every
        /// session billed from a transcript: a `Cost:` line carries no API
        /// time, so a line-sourced or mixed round has none either, the same
        /// rule `--json`'s own `totalAPIDuration` already follows.
        var apiDurationMs: Int? {
            guard hasBill, bills.allSatisfy({ $0.source == .transcript }) else { return nil }
            return bills.reduce(0) { $0 + ($1.bill?.totalAPIDuration ?? 0) }
        }
    }

    struct Goal: Equatable {
        var slug: String
        var rows: [Row]
    }

    /// The bill of every session in `record`: the archive's transcript when
    /// it names one that reads as a bill, else the `Cost:` line at the same
    /// position, else nothing for that session.
    static func bills(for record: Record) -> [SessionBill] {
        var bills: [SessionBill] = []
        for (index, session) in record.sessions.enumerated() {
            let archive = index < record.archives.count ? record.archives[index] : session
            if let join = SessionArchive.agentJoin(of: archive),
               case .bill(let bill) = TranscriptBill.read(path: join.transcriptPath) {
                bills.append(SessionBill(bill: bill))
            } else if index < record.costLines.count, let line = record.costLines[index] {
                bills.append(SessionBill(line: line))
            }
        }
        // Lines past the sessions the record names still count: a record
        // whose `Sessions:` line the parser could not read keeps its bill.
        if record.sessions.isEmpty {
            bills = record.costLines.compactMap { $0.map { SessionBill(line: $0) } }
        }
        return bills
    }

    /// `git diff --name-only <base>..<result>` in `root`: the count of the
    /// names it printed, or why there is none. An unresolved sha is a
    /// `failed` with git's own `fatal:` line; nothing git says is dropped.
    static func filesChanged(root: String, base: String?, result: String?) -> FilesChanged {
        guard let base, let result else {
            let missing = [base == nil ? "Base:" : nil, result == nil ? "Result:" : nil].compactMap { $0 }
            return .noSha(line: missing.joined(separator: " and "))
        }
        let range = "\(base)..\(result)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root, "diff", "--name-only", range]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .notRun(error: "\(error)") }
        // stdout to its end, then stderr: git writes a few lines to one of
        // them and nothing to the other, so neither read waits on a pipe
        // the other is filling.
        let names = output.fileHandleForReading.readDataToEndOfFile()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failed(range: range, status: process.terminationStatus, stderr: String(decoding: said, as: UTF8.self))
        }
        return .count(String(decoding: names, as: UTF8.self).split(separator: "\n").count)
    }

    // MARK: - Reading a package

    /// The round records under `<folder>/rounds/NNN.md`, by number.
    static func records(inGoalFolder folder: URL) throws -> [Record] {
        let rounds = folder.appendingPathComponent("rounds", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rounds.path) else { return [] }
        var records: [Record] = []
        for name in names.sorted() {
            guard name.hasSuffix(".md"), let number = Int(name.dropLast(3)), name.count == 6 else { continue }
            let text = try String(contentsOf: rounds.appendingPathComponent(name), encoding: .utf8)
            records.append(parse(text, number: number))
        }
        return records.sorted { $0.number < $1.number }
    }

    /// Every goal of the package, or the one named, in the order
    /// `kitterm goal list` prints. A named goal that has no folder is an
    /// error; a package with no goal folder is an empty ledger.
    static func goals(root: String, knowledge: String, slug: String?) throws -> [Goal] {
        let summaries = KnowledgeFile.summaries(root: root, knowledge: knowledge) ?? []
        var slugs = summaries.compactMap(\.slug)
        if let slug {
            guard slugs.contains(slug) else {
                throw CLIError.usage("no goal folder \(knowledge)/\(slug) under \(root)")
            }
            slugs = [slug]
        }
        return try slugs.map { slug in
            let folder = URL(fileURLWithPath: root).appendingPathComponent(knowledge).appendingPathComponent(slug)
            let rows = try records(inGoalFolder: folder).map { record in
                Row(
                    record: record,
                    bills: bills(for: record),
                    files: filesChanged(root: root, base: record.base, result: record.result)
                )
            }
            return Goal(slug: slug, rows: rows)
        }
    }

    // MARK: - The table

    static let dash = "—"

    static func dollars(_ value: Double) -> String { String(format: "%.2f", value) }

    /// Whole units under a thousand, one decimal of `k` under a million, two
    /// decimals of `M` above: `0`, `17.7k`, `1.10M`.
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.1fk", Double(count) / 1000) }
        return String(count)
    }

    static func cached(read: Int, of total: Int) -> String {
        guard total > 0 else { return dash }
        return "\(Int((100 * Double(read) / Double(total)).rounded()))%"
    }

    /// Minutes and seconds, `5m48`, from milliseconds rounded to the second.
    /// Minutes and seconds under an hour, hours and minutes at or over one.
    /// A round that sat open overnight printed `1013m00` before this rolled,
    /// which is both unreadable and wider than its column.
    static func wall(_ milliseconds: Int) -> String {
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        if seconds >= 3600 {
            let minutes = Int((Double(seconds) / 60).rounded())
            return String(format: "%dh%02d", minutes / 60, minutes % 60)
        }
        return String(format: "%dm%02d", seconds / 60, seconds % 60)
    }

    private static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, width - text.count))
        return left ? text + fill : fill + text
    }

    /// The lines of one goal's table, the shape of
    /// `docs/goals/cost-per-round/corpus/01-what-did-that-goal-cost.md`.
    static func table(_ goal: Goal) -> [String] {
        struct Cells {
            var name: String
            var values: [String]
            var decision: String
            var pr: String
        }
        var lines: [Cells] = []
        for row in goal.rows {
            let record = row.record
            let numbers: [String]
            if row.hasBill {
                numbers = [
                    dollars(row.costUSD), tokens(row.inTokens), cached(read: row.cacheRead, of: row.inTokens),
                    tokens(row.outTokens), wall(row.durationMs), row.apiDurationMs.map(wall) ?? dash,
                ]
            } else {
                numbers = Array(repeating: dash, count: 6)
            }
            lines.append(Cells(
                name: "  " + String(format: "%03d", record.number) + " " + record.slug,
                values: numbers + [
                    record.testsAdded.map { "+\($0)" } ?? dash,
                    row.filesChanged.map(String.init) ?? dash,
                ],
                decision: record.decision ?? dash,
                pr: record.pr.map { "#\($0)" } ?? dash
            ))
        }
        let billed = goal.rows.filter(\.hasBill)
        let inTotal = billed.reduce(0) { $0 + $1.inTokens }
        let apiTotals = goal.rows.compactMap(\.apiDurationMs)
        let tests = goal.rows.compactMap(\.record.testsAdded)
        let files = goal.rows.compactMap(\.filesChanged)
        lines.append(Cells(
            name: "  total",
            values: [
                billed.isEmpty ? dash : dollars(billed.reduce(0) { $0 + $1.costUSD }),
                billed.isEmpty ? dash : tokens(inTotal),
                billed.isEmpty ? dash : cached(read: billed.reduce(0) { $0 + $1.cacheRead }, of: inTotal),
                billed.isEmpty ? dash : tokens(billed.reduce(0) { $0 + $1.outTokens }),
                billed.isEmpty ? dash : wall(billed.reduce(0) { $0 + $1.durationMs }),
                apiTotals.isEmpty ? dash : wall(apiTotals.reduce(0, +)),
                tests.isEmpty ? dash : "+\(tests.reduce(0, +))",
                files.isEmpty ? dash : String(files.reduce(0, +)),
            ],
            decision: "", pr: ""
        ))

        let headers = ["$", "in", "cached", "out", "wall", "api", "tests", "files"]
        let minimums = [6, 8, 8, 9, 6, 6, 6, 7]
        let widths = (0..<headers.count).map { column in
            max(minimums[column], headers[column].count, lines.map { $0.values[column].count }.max() ?? 0)
        }
        let nameWidth = max(27, goal.slug.count + 1, (lines.map(\.name.count).max() ?? 0) + 3)
        let decisionWidth = max(12, (lines.map(\.decision.count).max() ?? 0) + 1)
        let prWidth = max(4, lines.map(\.pr.count).max() ?? 0)
        func line(_ name: String, _ values: [String], _ decision: String, _ pr: String) -> String {
            var text = pad(name, nameWidth, left: true)
            for (value, width) in zip(values, widths) { text += pad(value, width) }
            text += "   " + pad(decision, decisionWidth, left: true) + pad(pr, prWidth)
            while text.hasSuffix(" ") { text.removeLast() }
            return text
        }
        var output = [line(goal.slug, headers, "decision", "PR")]
        for cells in lines { output.append(line(cells.name, cells.values, cells.decision, cells.pr)) }
        let predate = goal.rows.filter { !$0.hasBill && !$0.record.hasCostLine }.count
        if predate > 0 {
            output.append(predate == 1
                ? "  1 round predates the bill and is not counted."
                : "  \(predate) rounds predate the bill and are not counted.")
        }
        let unrecorded = goal.rows.filter { !$0.hasBill && $0.record.hasCostLine }.count
        if unrecorded > 0 {
            output.append(unrecorded == 1
                ? "  1 round recorded no bill and is not counted."
                : "  \(unrecorded) rounds recorded no bill and are not counted.")
        }
        // A dash in the files column is a fact only with its reason beside
        // it: one line per round whose diff git did not count, with what
        // git said.
        for row in goal.rows {
            if let reason = row.files.reason {
                output.append("  " + String(format: "%03d", row.record.number) + " files not counted: " + reason)
            }
        }
        return output
    }

    // MARK: - JSON

    /// One round as `--json` prints it: the same numbers as the table,
    /// unrounded, under the transcript's field names where the source is a
    /// transcript, and `null` where a line-sourced round cannot know them.
    struct RoundJSON: Encodable {
        var goal: String
        var round: Int
        var slug: String
        var sessions: [String]
        /// `transcript`, `line`, `mixed` for a multi-session round with one
        /// of each, or null for a round with no bill.
        var source: String?
        var totalCostUSD: Double?
        var totalDuration: Int?
        var totalAPIDuration: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        var thinkingTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreationInputTokens: Int?
        /// `inputTokens` + `cacheCreationInputTokens` + `cacheReadInputTokens`.
        var `in`: Int?
        var cacheReadShare: Double?
        var testsAdded: Int?
        var filesChanged: Int?
        /// Why `filesChanged` is null (`FilesChanged.reason`); null with a count.
        var filesChangedReason: String?
        var decision: String?
        var pr: Int?
        var base: String?
        var result: String?

        enum CodingKeys: String, CodingKey {
            case goal, round, slug, sessions, source, totalCostUSD, totalDuration, totalAPIDuration
            case inputTokens, outputTokens, thinkingTokens, cacheReadInputTokens, cacheCreationInputTokens
            case `in`, cacheReadShare, testsAdded, filesChanged, filesChangedReason, decision, pr, base, result
        }

        // Explicit nulls: a consumer sees every field on every round.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(goal, forKey: .goal)
            try c.encode(round, forKey: .round)
            try c.encode(slug, forKey: .slug)
            try c.encode(sessions, forKey: .sessions)
            try c.encode(source, forKey: .source)
            try c.encode(totalCostUSD, forKey: .totalCostUSD)
            try c.encode(totalDuration, forKey: .totalDuration)
            try c.encode(totalAPIDuration, forKey: .totalAPIDuration)
            try c.encode(inputTokens, forKey: .inputTokens)
            try c.encode(outputTokens, forKey: .outputTokens)
            try c.encode(thinkingTokens, forKey: .thinkingTokens)
            try c.encode(cacheReadInputTokens, forKey: .cacheReadInputTokens)
            try c.encode(cacheCreationInputTokens, forKey: .cacheCreationInputTokens)
            try c.encode(`in`, forKey: .in)
            try c.encode(cacheReadShare, forKey: .cacheReadShare)
            try c.encode(testsAdded, forKey: .testsAdded)
            try c.encode(filesChanged, forKey: .filesChanged)
            try c.encode(filesChangedReason, forKey: .filesChangedReason)
            try c.encode(decision, forKey: .decision)
            try c.encode(pr, forKey: .pr)
            try c.encode(base, forKey: .base)
            try c.encode(result, forKey: .result)
        }
    }

    struct TotalsJSON: Encodable {
        var roundsBilled: Int
        var roundsWithoutBill: Int
        var totalCostUSD: Double
        var totalDuration: Int
        var `in`: Int
        var outputTokens: Int
        var cacheReadShare: Double?
        var testsAdded: Int
        var filesChanged: Int
    }

    struct GoalJSON: Encodable {
        var goal: String
        var rounds: [RoundJSON]
        var totals: TotalsJSON
    }

    struct LedgerJSON: Encodable {
        var goals: [GoalJSON]
    }

    static func json(_ goal: Goal) -> GoalJSON {
        let rounds = goal.rows.map { row -> RoundJSON in
            let record = row.record
            var json = RoundJSON(
                goal: goal.slug, round: record.number, slug: record.slug,
                sessions: record.sessions.map(\.uuidString),
                testsAdded: record.testsAdded, filesChanged: row.filesChanged, filesChangedReason: row.files.reason,
                decision: record.decision, pr: record.pr, base: record.base, result: record.result
            )
            guard row.hasBill else { return json }
            let sources = Set(row.bills.map(\.source))
            json.source = sources.count == 1 ? sources.first?.rawValue : "mixed"
            json.totalCostUSD = row.costUSD
            json.totalDuration = row.durationMs
            json.outputTokens = row.outTokens
            json.in = row.inTokens
            json.cacheReadShare = row.inTokens > 0 ? Double(row.cacheRead) / Double(row.inTokens) : nil
            if sources == [.transcript] {
                let bills = row.bills.compactMap(\.bill)
                let usage = bills.flatMap { $0.modelUsage.values }
                json.totalAPIDuration = bills.reduce(0) { $0 + $1.totalAPIDuration }
                json.inputTokens = usage.reduce(0) { $0 + $1.inputTokens }
                json.thinkingTokens = usage.reduce(0) { $0 + $1.thinkingTokens }
                json.cacheReadInputTokens = usage.reduce(0) { $0 + $1.cacheReadInputTokens }
                json.cacheCreationInputTokens = usage.reduce(0) { $0 + $1.cacheCreationInputTokens }
            }
            return json
        }
        let billed = goal.rows.filter(\.hasBill)
        let inTotal = billed.reduce(0) { $0 + $1.inTokens }
        let totals = TotalsJSON(
            roundsBilled: billed.count,
            roundsWithoutBill: goal.rows.count - billed.count,
            totalCostUSD: billed.reduce(0) { $0 + $1.costUSD },
            totalDuration: billed.reduce(0) { $0 + $1.durationMs },
            in: inTotal,
            outputTokens: billed.reduce(0) { $0 + $1.outTokens },
            cacheReadShare: inTotal > 0 ? Double(billed.reduce(0) { $0 + $1.cacheRead }) / Double(inTotal) : nil,
            testsAdded: goal.rows.compactMap(\.record.testsAdded).reduce(0, +),
            filesChanged: goal.rows.compactMap(\.filesChanged).reduce(0, +)
        )
        return GoalJSON(goal: goal.slug, rounds: rounds, totals: totals)
    }

    static func jsonText(_ goals: [Goal]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(LedgerJSON(goals: goals.map(json)))
        return String(decoding: data, as: UTF8.self)
    }
}
