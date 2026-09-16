#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// The bill Claude Code writes as the last line of a session's transcript:
/// the `"type":"cost-state"` line, with the dollars, the wall-clock, the API
/// time, the lines added and removed, and the tokens by kind per model.
///
/// ## What the line is
///
/// Claude Code appends one JSON object per line to
/// `~/.claude/projects/<cwd>/<session>.jsonl` and writes a `cost-state` line
/// when the session ends. The totals are cumulative: a session that is
/// resumed appends its turns after the old `cost-state` line and writes a new
/// one at its next end, with the old numbers folded in. So the bill is the
/// *last* line, and only when the last line is a `cost-state` line. A
/// `cost-state` line with lines after it is the bill of a run that has since
/// continued, and the reader reports "no bill yet" for it rather than a
/// total it knows is stale.
///
/// The field names here are the transcript's own, unrounded, so a consumer
/// that prints `--json` passes them through. The daemon computes nothing:
/// no price table, no sum over turns.
///
/// ## A bill of zero
///
/// A session that recorded no billable turn still gets a `cost-state` line,
/// with `totalCostUSD: 0` and `modelUsage: {}`, and a real `totalDuration`.
/// That is a bill of zero, not the absence of a bill: Claude Code wrote a
/// total, the wall-clock in it is true, and a ledger row can print it. "No
/// bill yet" is reserved for the file that has no complete `cost-state` line
/// at its end.
public struct TranscriptBill: Codable, Equatable, Sendable {
    /// One model's share of the bill, keyed by model id in `modelUsage`.
    public struct ModelUsage: Codable, Equatable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        /// Absent on a transcript written before Claude Code counted
        /// thinking tokens per model (five real bills, $221, on
        /// 2026-09-16), and zero then: a model line with no count is not
        /// a malformed bill.
        public var thinkingTokens: Int
        public var cacheReadInputTokens: Int
        public var cacheCreationInputTokens: Int
        /// Present since Claude Code 2.1; absent on an older transcript.
        public var webSearchRequests: Int?
        public var costUSD: Double

        public init(
            inputTokens: Int, outputTokens: Int, thinkingTokens: Int,
            cacheReadInputTokens: Int, cacheCreationInputTokens: Int,
            webSearchRequests: Int? = nil, costUSD: Double
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.thinkingTokens = thinkingTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.webSearchRequests = webSearchRequests
            self.costUSD = costUSD
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try container.decode(Int.self, forKey: .inputTokens)
            outputTokens = try container.decode(Int.self, forKey: .outputTokens)
            thinkingTokens = try container.decodeIfPresent(Int.self, forKey: .thinkingTokens) ?? 0
            cacheReadInputTokens = try container.decode(Int.self, forKey: .cacheReadInputTokens)
            cacheCreationInputTokens = try container.decode(Int.self, forKey: .cacheCreationInputTokens)
            webSearchRequests = try container.decodeIfPresent(Int.self, forKey: .webSearchRequests)
            costUSD = try container.decode(Double.self, forKey: .costUSD)
        }
    }

    /// The Claude Code session id on the line; the transcript's file name.
    public var sessionId: String?
    public var totalCostUSD: Double
    /// Milliseconds of wall-clock, from `startTime` to the end of the session.
    public var totalDuration: Int
    /// Milliseconds spent waiting on the API, retries included.
    public var totalAPIDuration: Int
    public var totalAPIDurationWithoutRetries: Int?
    public var totalToolDuration: Int?
    public var totalLinesAdded: Int
    public var totalLinesRemoved: Int
    /// Epoch milliseconds, when the session began.
    public var startTime: Int64?
    /// Empty on a session with no billable turn.
    public var modelUsage: [String: ModelUsage]
    public var hasUnknownModelCost: Bool?

    /// Why a transcript has no bill. The raw value is what the route says.
    public enum NoBill: String, Equatable, Sendable {
        /// The last complete line is not a `cost-state` line: the session is
        /// still running, or it was resumed after its last end. Also an
        /// empty file, and a last line that is not JSON.
        case noCostStateLine
        /// The file does not end in a newline: the last line is mid-write,
        /// or the file was cut. The line before it is not consulted.
        case lastLineIncomplete
        /// The last line is longer than `tailWindowBytes`, so the reader
        /// never saw where it starts. A `cost-state` line is a few hundred
        /// bytes per model; a line this long is a turn, not a bill.
        case lastLineTooLong
        /// The last line says `cost-state` but lacks a field this reader
        /// needs. A change in what Claude Code writes, worth a look.
        case costStateMalformed
    }

    /// What a read of a transcript found.
    public enum Outcome: Equatable, Sendable {
        case bill(TranscriptBill)
        case noBill(NoBill)
        /// The file could not be opened or read; the message names why.
        case unreadable(String)
    }

    /// How far back from the end the reader looks: one `pread` of this many
    /// bytes. The largest last line across 60 real transcripts was 1517
    /// bytes, and a `cost-state` line grows by about 170 bytes per model, so
    /// 64 KiB holds any bill. Nothing before the last line's own newline is
    /// read, whatever the size of the file or of the line before it.
    public static let tailWindowBytes = 65_536

    /// Where the HTTP route runs the read, off the event loop, the way
    /// `PushSubscriptionStore.queue` carries that store's writes.
    static let queue = DispatchQueue(label: "kitterm.transcript")

    /// Read the bill from the transcript at `path`.
    ///
    /// Seeks to the end and reads back `window` bytes at most, then takes the
    /// last newline-terminated line. A file another process is appending to
    /// is read as it is at that moment: a partial last line is
    /// `.noBill(.lastLineIncomplete)`, never an error.
    public static func read(path: String, window: Int = tailWindowBytes) -> Outcome {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            return .unreadable("cannot open \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        let size = lseek(fd, 0, SEEK_END)
        guard size >= 0 else {
            return .unreadable("cannot seek \(path): \(String(cString: strerror(errno)))")
        }
        let length = Int(min(size, off_t(window)))
        let start = size - off_t(length)
        var tail = [UInt8](repeating: 0, count: length)
        var filled = 0
        while filled < length {
            let n = tail.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress! + filled, length - filled, start + off_t(filled))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return .unreadable("cannot read \(path): \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            filled += n
        }
        return parseTail(tail[0..<filled], tailIsWholeFile: start == 0)
    }

    /// The last line of a transcript's tail bytes, parsed. `tailIsWholeFile`
    /// says the window reached the start of the file, so a tail with no
    /// newline before its last line is one whole line rather than the end of
    /// a longer one.
    static func parseTail(_ tail: ArraySlice<UInt8>, tailIsWholeFile: Bool) -> Outcome {
        let newline = UInt8(ascii: "\n")
        guard let last = tail.last else { return .noBill(.noCostStateLine) }
        guard last == newline else { return .noBill(.lastLineIncomplete) }
        let body = tail.dropLast()
        let lineStart: ArraySlice<UInt8>.Index
        if let previous = body.lastIndex(of: newline) {
            lineStart = body.index(after: previous)
        } else if tailIsWholeFile {
            lineStart = body.startIndex
        } else {
            return .noBill(.lastLineTooLong)
        }
        let line = Data(body[lineStart...])
        // A cheap gate before the decoder: most last lines are turns, and
        // the type key is the first thing on a `cost-state` line.
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "cost-state"
        else { return .noBill(.noCostStateLine) }
        do {
            return .bill(try JSONDecoder().decode(TranscriptBill.self, from: line))
        } catch {
            return .noBill(.costStateMalformed)
        }
    }
}
