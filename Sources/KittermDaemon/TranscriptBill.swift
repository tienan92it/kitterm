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
/// *last* `cost-state` line, and only when no `assistant` line follows it:
/// a turn after the bill is a run that has since continued, and the reader
/// reports "no bill yet" for it rather than a total it knows is stale.
///
/// A line after the bill that is not a turn does not make it stale. Claude
/// Code appends records at exit and on a resume that carry no usage —
/// `queue-operation`, `ai-title`, `agent-name`, `system`, and a `user` line
/// with its `attachment`s when the human typed and no answer came yet — and
/// the reader steps over them (round 19 of `agent-dashboard`: measured
/// 2026-09-21 over 654 transcripts, 5 finished sessions carried such lines
/// after their bill, 1989 bytes of them at most, and read as unbilled).
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
        /// An `assistant` line sits after the last `cost-state` line, or
        /// there is no `cost-state` line: the session is still running, or
        /// it was resumed after its last end. Also an empty file, and a
        /// file of lines that are not JSON.
        case noCostStateLine
        /// The file does not end in a newline: the last line is mid-write,
        /// or the file was cut. The line before it is not consulted.
        case lastLineIncomplete
        /// The window ran out before a line decided: the last line alone is
        /// longer than `tailWindowBytes`, so the reader never saw where it
        /// starts, or the records behind the bill are. A `cost-state` line
        /// is a few hundred bytes per model, and the records Claude Code
        /// appends after it are under 2 KiB together; a run this long is a
        /// turn, not a bill.
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
    /// bytes, and a `cost-state` line grows by about 170 bytes per model.
    /// The bill sits behind the records Claude Code appends after it:
    /// measured 2026-09-21 over 654 transcripts, the last `cost-state` line
    /// and every line after it, on a session no turn resumed, was 2686
    /// bytes at most. 64 KiB holds that twenty times over, and it is the
    /// read the reader already paid, so the number did not change. Nothing
    /// before the window is read, whatever the size of the file.
    public static let tailWindowBytes = 65_536

    /// Where the HTTP route runs the read, off the event loop, the way
    /// `PushSubscriptionStore.queue` carries that store's writes.
    static let queue = DispatchQueue(label: "kitterm.transcript")

    /// Read the bill from the transcript at `path`.
    ///
    /// Seeks to the end and reads back `window` bytes at most, then walks the
    /// newline-terminated lines from the last one back to the first line
    /// that decides (`parseTail`). A file another process is appending to
    /// is read as it is at that moment: a partial last line is
    /// `.noBill(.lastLineIncomplete)`, never an error.
    public static func read(path: String, window: Int = tailWindowBytes) -> Outcome {
        switch readTail(path: path, window: window) {
        case .tail(let tail, let wholeFile):
            return parseTail(tail, tailIsWholeFile: wholeFile)
        case .unreadable(let reason):
            return .unreadable(reason)
        }
    }

    /// The last `window` bytes of a file, or fewer when the file is shorter.
    enum TailRead {
        /// `wholeFile` says the window reached the start of the file.
        case tail(ArraySlice<UInt8>, wholeFile: Bool)
        case unreadable(String)
    }

    /// One `pread` of the file's tail. Shared with `TranscriptModel`, which
    /// reads the same file for a different line.
    static func readTail(path: String, window: Int) -> TailRead {
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
        return .tail(tail[0..<filled], wholeFile: start == 0)
    }

    /// The tail bytes of a transcript, walked from the last complete line
    /// back to the first one that decides: a `cost-state` line is the bill,
    /// an `assistant` line is a turn after the bill, and any other line is a
    /// record with no usage and is stepped over. `tailIsWholeFile` says the
    /// window reached the start of the file, so a line with no newline
    /// before it is the first line rather than the end of a longer one; a
    /// walk that reaches the window's edge without a decision is
    /// `.lastLineTooLong`, and one that reaches the file's start is
    /// `.noCostStateLine`.
    static func parseTail(_ tail: ArraySlice<UInt8>, tailIsWholeFile: Bool) -> Outcome {
        let newline = UInt8(ascii: "\n")
        guard let last = tail.last else { return .noBill(.noCostStateLine) }
        guard last == newline else { return .noBill(.lastLineIncomplete) }
        // The bytes before the newline that ends the line under the walk.
        var body = tail.dropLast()
        while true {
            let lineStart: ArraySlice<UInt8>.Index
            if let previous = body.lastIndex(of: newline) {
                lineStart = body.index(after: previous)
            } else if tailIsWholeFile {
                lineStart = body.startIndex
            } else {
                return .noBill(.lastLineTooLong)
            }
            let line = body[lineStart...]
            switch classify(line) {
            case .costState:
                do {
                    return .bill(try JSONDecoder().decode(TranscriptBill.self, from: Data(line)))
                } catch {
                    return .noBill(.costStateMalformed)
                }
            case .assistant:
                return .noBill(.noCostStateLine)
            case .other:
                break
            }
            guard lineStart > body.startIndex else { return .noBill(.noCostStateLine) }
            body = body[..<body.index(before: lineStart)]
        }
    }

    /// What one line is to the walk.
    enum LineKind {
        case costState, assistant, other
    }

    private static let costStateGate = Array(#""type":"cost-state""#.utf8)
    private static let assistantGate = Array(#""type":"assistant""#.utf8)

    /// A `memmem` for the two type keys before the decoder, so a line that
    /// carries neither (a tool result, an attachment) costs no parse; a
    /// line that carries one is parsed and its own `type` decides, so a
    /// tool result that quotes a transcript is still the line it is.
    static func classify(_ line: ArraySlice<UInt8>) -> LineKind {
        guard contains(line, costStateGate) || contains(line, assistantGate),
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let type = object["type"] as? String
        else { return .other }
        switch type {
        case "cost-state": return .costState
        case "assistant": return .assistant
        default: return .other
        }
    }

    private static func contains(_ line: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        guard line.count >= needle.count else { return false }
        return line.withUnsafeBufferPointer { haystack in
            needle.withUnsafeBufferPointer { pattern in
                guard let hay = haystack.baseAddress, let pat = pattern.baseAddress else { return false }
                return memmem(hay, haystack.count, pat, pattern.count) != nil
            }
        }
    }
}
