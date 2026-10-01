import Foundation

/// The last thing the agent said in a Claude Code transcript: the text of
/// the last `"type":"assistant"` line that carries a `text` block.
///
/// Claude Code writes one content block per line, so the last assistant
/// line of a session is often a `tool_use` or a `thinking` block with no
/// words in it. The reader walks back to the last line with text. A
/// `"<synthetic>"` line is Claude Code's own message, not the agent's, and
/// a sidechain line is a subagent's; both are stepped over.
///
/// One `pread` of the tail (`TranscriptBill.readTail`), the window
/// `TranscriptModel` reads, whatever the size of the file. `kitterm foreman
/// catch-up` prints the answer for a new foreman's predecessor.
///
/// ## A session that continued in another file
///
/// Claude Code ends a transcript with a `"type":"continued-in"` record when
/// the conversation goes on under a new session id, in
/// `<continuedInSessionId>.jsonl` beside the first file. The join a kitterm
/// session holds can still name the first file: measured 2026-10-01, the
/// live foreman's row named a transcript that ended on 2026-09-27, and its
/// turns of four days were in the file that record names. The reader
/// follows the record, `maxHops` files at most, and keeps the newest text
/// it found when the next file does not open or holds no text.
public enum TranscriptLastMessage {
    public struct Message: Equatable, Sendable {
        /// The text blocks of the line, joined with a blank line, trimmed,
        /// and cut at `maxCharacters`.
        public var text: String
        /// The line's `timestamp`, as Claude Code wrote it.
        public var timestamp: String?
        /// Whether `text` is shorter than what the agent wrote.
        public var truncated: Bool
        /// The file the line is in: the path given, or the file a
        /// `continued-in` record led to.
        public var path: String
    }

    public enum Outcome: Equatable, Sendable {
        case message(Message)
        /// No assistant line with text in the window.
        case none
        /// The file could not be opened or read; the message names why.
        case unreadable(String)
    }

    /// How far back from the end the reader looks, in one `pread`.
    public static let tailWindowBytes = TranscriptModel.tailWindowBytes
    /// The longest text the reader returns.
    public static let maxCharacters = 1500

    /// How many `continued-in` records one read follows.
    public static let maxHops = 8

    public static func read(
        path: String, window: Int = tailWindowBytes, maxCharacters: Int = maxCharacters
    ) -> Outcome {
        var path = path
        var newest = Outcome.none
        for hop in 0...maxHops {
            switch TranscriptBill.readTail(path: path, window: window) {
            case .unreadable(let reason):
                // The file given must open. A continuation that does not
                // open leaves the newest text the files before it held.
                return hop == 0 ? .unreadable(reason) : newest
            case .tail(let tail, let wholeFile):
                let (message, continuedIn) = parseTail(tail, tailIsWholeFile: wholeFile, maxCharacters: maxCharacters)
                if var message {
                    message.path = path
                    newest = .message(message)
                }
                // The id names a file beside this one and nothing else: a
                // UUID holds no path separator.
                guard let continuedIn, UUID(uuidString: continuedIn) != nil else { return newest }
                path = URL(fileURLWithPath: path).deletingLastPathComponent()
                    .appendingPathComponent(continuedIn + ".jsonl").path
            }
        }
        return newest
    }

    private static let assistantGate = Array(#""type":"assistant""#.utf8)
    private static let continuedInGate = Array(#""type":"continued-in""#.utf8)

    /// The last complete assistant line with text in `tail`, and the
    /// session id of a `continued-in` record after it. A line cut by the
    /// window's start, or one still being written at the end, is not read.
    static func parseTail(
        _ tail: ArraySlice<UInt8>, tailIsWholeFile: Bool, maxCharacters: Int = maxCharacters
    ) -> (message: Message?, continuedIn: String?) {
        let newline = UInt8(ascii: "\n")
        var lines = tail.split(separator: newline, omittingEmptySubsequences: true)
        if tail.last != newline { lines.removeLast(lines.isEmpty ? 0 : 1) }
        if !tailIsWholeFile, !lines.isEmpty, tail.first != newline { lines.removeFirst() }
        var continuedIn: String?
        for line in lines.reversed() {
            let isAssistant = TranscriptBill.contains(line, assistantGate)
            guard isAssistant || (continuedIn == nil && TranscriptBill.contains(line, continuedInGate)),
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if object["type"] as? String == "continued-in" {
                if continuedIn == nil { continuedIn = object["continuedInSessionId"] as? String }
                continue
            }
            guard object["type"] as? String == "assistant",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  message["model"] as? String != TranscriptModel.syntheticModel,
                  let blocks = message["content"] as? [[String: Any]]
            else { continue }
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let truncated = text.count > maxCharacters
            let found = Message(
                text: truncated ? String(text.prefix(maxCharacters)) : text,
                timestamp: object["timestamp"] as? String, truncated: truncated, path: ""
            )
            return (found, continuedIn)
        }
        return (nil, continuedIn)
    }
}
