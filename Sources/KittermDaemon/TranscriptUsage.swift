#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// A calendar day as the rollup keys it: `YYYY-MM-DD` in one time zone.
///
/// The transcript stamps every turn in UTC. The human reads the page in
/// the zone the machine runs in, so a turn at `17:30Z` on the 10th is the
/// 11th at `00:30` in `+07`, and a chart bucketed in UTC would put an
/// evening's work on the next day. The rollup buckets in the daemon's own
/// zone (`TimeZone.current`), which on the machine that runs `claude` is
/// the zone the human lives in, and the route says which zone it used.
///
/// The arithmetic is civil-date arithmetic on a day number (days since
/// 1970-01-01), not `Calendar`, so a scan over fifty thousand turns spends
/// its time on the JSON and not on the calendar, and a test can drive the
/// midnight case in both directions with a fixed zone.
public struct DayKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Days since 1970-01-01 in the civil calendar of the chosen zone.
    public let number: Int

    public init(number: Int) { self.number = number }

    /// `YYYY-MM-DD`, or nil for anything else. The route's `from` and `to`
    /// take this form; a month or day out of range is refused too.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let number = Self.daysFromCivil(year: year, month: month, day: day)
        // Reject 2026-02-31 by round-tripping.
        guard Self.civilFromDays(number) == (year, month, day) else { return nil }
        self.number = number
    }

    /// The day `instant` falls on in `zone`, DST-aware.
    public init(_ instant: Date, in zone: TimeZone) {
        let seconds = Int(instant.timeIntervalSince1970.rounded(.down)) + zone.secondsFromGMT(for: instant)
        // Floor division, so a stamp before 1970 does not round toward zero.
        number = seconds >= 0 ? seconds / 86_400 : -((-seconds + 86_399) / 86_400)
    }

    public var description: String {
        let (year, month, day) = Self.civilFromDays(number)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool { lhs.number < rhs.number }

    public func advanced(by days: Int) -> DayKey { DayKey(number: number + days) }

    // Howard Hinnant's algorithms, exact for the proleptic Gregorian calendar.

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (month <= 2 ? y + 1 : y, month, day)
    }
}

/// Tokens by kind, the four counts every assistant turn carries in
/// `message.usage`, plus how many turns they came from.
public struct TokenCounts: Codable, Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    /// API requests (`requestId`s), not lines: one request is written as
    /// several assistant lines, one per content block, each carrying the
    /// same `usage`.
    public var requests: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0, requests: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.requests = requests
    }

    public static let zero = TokenCounts()

    /// Every kind, weighted equally. The share of a session's cost a day
    /// takes is this day's `total` over the session's.
    public var total: Int { input + output + cacheCreation + cacheRead }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheCreation += rhs.cacheCreation
        lhs.cacheRead += rhs.cacheRead
        lhs.requests += rhs.requests
    }
}

/// What one Claude Code session put on each day, read from its transcript.
///
/// ## Where the numbers come from
///
/// Two places in the same file, and they are not the same measurement:
///
/// - **Dollars** come from the last line, the `cost-state` bill that
///   `TranscriptBill` reads. Exact, Claude Code's own arithmetic, one number
///   for the whole session, with no date on it.
/// - **Tokens per day** come from every `"type":"assistant"` line, each of
///   which carries an ISO `timestamp` and its `message.usage`. One API
///   request is written as several such lines, one per content block, all
///   with the same `requestId` and the same `usage`, so the reader counts
///   each `requestId` once. A session's subagents write their own files
///   under `<session>/subagents/`, and those turns are on the parent's
///   bill, so they are read into the parent.
///
/// On the real corpus the turns sum to 2–6% under the bill's own token
/// totals, because the bill also counts calls that are not turns (the Haiku
/// title and summary calls, for one). The daemon uses the turns only to
/// decide each day's *share* and never to price anything, so the gap moves
/// a split by a fraction of a percent and never moves a total.
///
/// ## The apportionment
///
/// A session inside one day puts its whole bill on that day: exact. A
/// session that spans midnight is split by each day's share of the
/// session's tokens, every kind weighted equally, which is an
/// apportionment and not a measurement, and the route says so in a field
/// of its own. A price table would make each day exact and `goal.md`
/// excludes one.
public struct TranscriptUsage: Equatable, Sendable {
    /// The `sessionId` on the lines; the file's name.
    public var sessionId: String?
    /// The `cwd` on the first line that carries one.
    public var cwd: String?
    /// Tokens per day, keyed by `DayKey.description`, in the zone the read
    /// was given.
    public var days: [String: TokenCounts]
    /// What the last line said.
    public var bill: TranscriptBill.Outcome
    /// Lines the reader could not use: not JSON, or an assistant line with a
    /// `usage` but no parsable `timestamp`. Reported, never guessed at.
    public var skippedLines: Int

    public var tokens: TokenCounts {
        days.values.reduce(into: .zero) { $0 += $1 }
    }

    /// The bill's total, or nil when the session has no bill yet.
    public var totalCostUSD: Double? {
        if case .bill(let bill) = bill { return bill.totalCostUSD }
        return nil
    }

    // MARK: - The read

    /// Read `path` and its subagent files, bucketing turns in `zone`. The
    /// caller decides the queue: this walks the whole file once, line by
    /// line, and a transcript can be tens of megabytes.
    public static func read(path: String, subagents: [String] = [], zone: TimeZone) -> TranscriptUsage {
        var usage = TranscriptUsage(sessionId: nil, cwd: nil, days: [:], bill: .noBill(.noCostStateLine), skippedLines: 0)
        var seen = Set<String>()
        scanLines(path: path) { line in usage.take(line, zone: zone, seen: &seen) }
        for subagent in subagents {
            scanLines(path: subagent) { line in usage.take(line, zone: zone, seen: &seen) }
        }
        usage.bill = TranscriptBill.read(path: path)
        return usage
    }

    /// The bytes a scan reads at a time. A line is never longer than the
    /// largest tool result, well under this.
    static let chunkBytes = 1 << 20

    /// Call `body` with each newline-terminated line of `path`. An
    /// unreadable file yields nothing; the bill read reports why.
    static func scanLines(path: String, _ body: (ArraySlice<UInt8>) -> Void) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var carry: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, raw.baseAddress, chunkBytes)
                #else
                return Glibc.read(fd, raw.baseAddress, chunkBytes)
                #endif
            }
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if n == 0 { return }
            carry.append(contentsOf: buffer[0..<n])
            var start = carry.startIndex
            while let newline = newlineIndex(in: carry, from: start) {
                body(carry[start..<newline])
                start = newline + 1
            }
            carry.removeSubrange(carry.startIndex..<start)
        }
    }

    /// `memchr`, because a Swift loop over 380 MB of transcript is the
    /// scan's whole cost in a debug build and a good part of it in release.
    private static func newlineIndex(in bytes: [UInt8], from start: Int) -> Int? {
        bytes.withUnsafeBufferPointer { buffer -> Int? in
            guard start < buffer.count, let base = buffer.baseAddress,
                  let hit = memchr(base + start, Int32(UInt8(ascii: "\n")), buffer.count - start)
            else { return nil }
            return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
        }
    }

    /// The bytes an assistant line carries near its start; a cheap gate so
    /// the decoder runs only on the lines that can hold a `usage`.
    private static let assistantGate = Array(#""type":"assistant""#.utf8)

    private mutating func take(_ line: ArraySlice<UInt8>, zone: TimeZone, seen: inout Set<String>) {
        guard Self.contains(line, Self.assistantGate) else { return }
        // The fast path: the three fields the count needs, cut out of the
        // line by position and decoded alone, so the decoder never sees a
        // tool result. The session id and the cwd are taken once per file
        // from a full decode, and any line the fast path cannot vouch for
        // gets the full decode too.
        if sessionId != nil, cwd != nil, let turn = Self.extract(line) {
            count(turn, zone: zone, seen: &seen)
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "assistant"
        else {
            skippedLines += 1
            return
        }
        if sessionId == nil { sessionId = object["sessionId"] as? String }
        if cwd == nil { cwd = object["cwd"] as? String }
        guard let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }
        let request = (object["requestId"] as? String) ?? (message["id"] as? String) ?? (object["uuid"] as? String) ?? ""
        count(Turn(request: request, timestamp: object["timestamp"] as? String ?? "", usage: usage), zone: zone, seen: &seen)
    }

    struct Turn {
        var request: String
        var timestamp: String
        var usage: [String: Any]
    }

    private mutating func count(_ turn: Turn, zone: TimeZone, seen: inout Set<String>) {
        // One request, several lines: the first one counts.
        guard !turn.request.isEmpty, !seen.contains(turn.request) else { return }
        guard let instant = Self.parseUTC(turn.timestamp) else {
            skippedLines += 1
            return
        }
        seen.insert(turn.request)
        let counts = TokenCounts(
            input: turn.usage["input_tokens"] as? Int ?? 0,
            output: turn.usage["output_tokens"] as? Int ?? 0,
            cacheCreation: turn.usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: turn.usage["cache_read_input_tokens"] as? Int ?? 0,
            requests: 1
        )
        days[DayKey(instant, in: zone).description, default: .zero] += counts
    }

    private static let timestampKey = Array(#""timestamp":""#.utf8)
    private static let requestKey = Array(#""requestId":""#.utf8)
    private static let usageKey = Array(#""usage":{"#.utf8)

    /// The request id, the timestamp and the `usage` object of an assistant
    /// line, by position. Each is the *last* occurrence in the line: the
    /// line's own fields follow `message`, and a tool call inside `message`
    /// can quote anything, including another transcript's lines. Nil when
    /// any piece is missing or does not decode, and the caller falls back
    /// to a full decode of the line.
    static func extract(_ line: ArraySlice<UInt8>) -> Turn? {
        guard let timestamp = lastString(after: timestampKey, in: line),
              let request = lastString(after: requestKey, in: line),
              let usageStart = lastIndex(of: usageKey, in: line),
              let usageEnd = objectEnd(from: usageStart + usageKey.count - 1, in: line),
              let usage = try? JSONSerialization.jsonObject(with: Data(line[(usageStart + usageKey.count - 1)...usageEnd])) as? [String: Any]
        else { return nil }
        return Turn(request: request, timestamp: timestamp, usage: usage)
    }

    /// The string value after the last `key` in `line`, up to the next `"`.
    /// Nil when the value holds an escape, which the fields this reads never
    /// do; the slow path decodes it then.
    private static func lastString(after key: [UInt8], in line: ArraySlice<UInt8>) -> String? {
        guard let start = lastIndex(of: key, in: line) else { return nil }
        let valueStart = start + key.count
        guard valueStart < line.endIndex, let end = line[valueStart...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        let value = line[valueStart..<end]
        guard !value.contains(UInt8(ascii: "\\")) else { return nil }
        return String(decoding: value, as: UTF8.self)
    }

    /// The index of the last occurrence of `needle` in `line`.
    private static func lastIndex(of needle: [UInt8], in line: ArraySlice<UInt8>) -> Int? {
        var found: Int?
        var from = line.startIndex
        while from + needle.count <= line.endIndex {
            let hit: Int? = line[from...].withUnsafeBufferPointer { haystack in
                needle.withUnsafeBufferPointer { pattern -> Int? in
                    guard let base = haystack.baseAddress, let pat = pattern.baseAddress,
                          let at = memmem(base, haystack.count, pat, pattern.count)
                    else { return nil }
                    return from + (UnsafeRawPointer(at) - UnsafeRawPointer(base))
                }
            }
            guard let hit else { break }
            found = hit
            from = hit + 1
        }
        return found
    }

    /// The index of the `}` that closes the object opened at `open`,
    /// skipping strings. Nil when the line ends first.
    private static func objectEnd(from open: Int, in line: ArraySlice<UInt8>) -> Int? {
        var depth = 0
        var inString = false
        var index = open
        while index < line.endIndex {
            let byte = line[index]
            if inString {
                if byte == UInt8(ascii: "\\") { index += 1 } else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func contains(_ line: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        guard line.count >= needle.count else { return false }
        return line.withUnsafeBufferPointer { haystack in
            needle.withUnsafeBufferPointer { pattern in
                // Glibc's `memmem` takes non-optional pointers; Darwin's does not care.
                guard let hay = haystack.baseAddress, let pat = pattern.baseAddress else { return false }
                return memmem(hay, haystack.count, pat, pattern.count) != nil
            }
        }
    }

    /// `2026-09-04T09:30:31.436Z` as an instant. Only this form, which is the
    /// only form Claude Code writes; a `Calendar` per line would cost more
    /// than the JSON does.
    static func parseUTC(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              bytes.last == UInt8(ascii: "Z")
        else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var fraction = 0.0
        if bytes.count > 20, bytes[19] == UInt8(ascii: ".") {
            var scale = 0.1
            for index in 20..<(bytes.count - 1) {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                fraction += Double(digit) * scale
                scale /= 10
            }
        } else if bytes.count != 20 {
            return nil
        }
        let days = DayKey.daysFromCivil(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fraction)
    }

    // MARK: - The apportionment

    /// One day's part of a session.
    public struct Share: Equatable, Sendable {
        public var tokens: TokenCounts
        /// The dollars this day takes of the session's bill; zero when the
        /// session has no bill.
        public var costUSD: Double
        /// True when the session's turns fall on more than one day, so
        /// `costUSD` is a share by tokens and not a measurement.
        public var apportioned: Bool
    }

    /// Split `totalCostUSD` over `days` by each day's share of the tokens.
    /// A session on one day is exact. A bill with no turns behind it, which
    /// a zeroed session can be, goes whole to `fallbackDay` when there is
    /// one, so a real charge is never dropped for want of a timestamp.
    public static func apportion(
        days: [String: TokenCounts], totalCostUSD: Double?, fallbackDay: String? = nil
    ) -> [String: Share] {
        let total = days.values.reduce(0) { $0 + $1.total }
        var shares: [String: Share] = [:]
        if days.isEmpty {
            if let totalCostUSD, totalCostUSD > 0, let fallbackDay {
                shares[fallbackDay] = Share(tokens: .zero, costUSD: totalCostUSD, apportioned: false)
            }
            return shares
        }
        let apportioned = days.count > 1
        for (day, tokens) in days {
            let cost: Double
            if let totalCostUSD, total > 0 {
                cost = totalCostUSD * Double(tokens.total) / Double(total)
            } else if let totalCostUSD, !apportioned {
                cost = totalCostUSD
            } else {
                cost = 0
            }
            shares[day] = Share(tokens: tokens, costUSD: cost, apportioned: apportioned)
        }
        return shares
    }
}
