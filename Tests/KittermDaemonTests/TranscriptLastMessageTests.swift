import Foundation
import XCTest

@testable import KittermDaemon

/// `TranscriptLastMessage` over transcripts written into a scratch
/// directory: the last assistant line with a `text` block, which is what
/// `kitterm foreman catch-up` prints for a predecessor.
final class TranscriptLastMessageTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-transcript-last-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// One assistant line with one content block, as Claude Code writes it.
    private func assistant(
        _ block: [String: Any], model: String = "claude-opus-5-5", sidechain: Bool = false,
        timestamp: String = "2026-09-25T03:28:05.703Z"
    ) throws -> String {
        let line: [String: Any] = [
            "type": "assistant", "isSidechain": sidechain, "timestamp": timestamp, "requestId": "r",
            "message": ["model": model, "role": "assistant", "content": [block]] as [String: Any],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }

    private func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }
    private let toolUse: [String: Any] = ["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "ls"]]
    private let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
    private let costState = #"{"type":"cost-state","totalCostUSD":1,"totalDuration":1,"totalAPIDuration":1,"totalLinesAdded":0,"totalLinesRemoved":0,"modelUsage":{}}"#

    private func write(_ lines: [String], as name: String = "t.jsonl", trailingNewline: Bool = true) throws -> String {
        let path = scratch.appendingPathComponent(name).path
        let body = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testTheLastTextIsReadBehindToolLinesAndTheBill() throws {
        let path = try write([
            try assistant(text("an earlier answer"), timestamp: "2026-09-25T03:00:00.000Z"),
            try assistant(["type": "thinking", "thinking": "hidden"]),
            try assistant(text("Round 3 is done.\n\nThe human said: merge PR 12 first.")),
            try assistant(toolUse),
            toolResult,
            costState,
        ])
        XCTAssertEqual(
            TranscriptLastMessage.read(path: path),
            .message(.init(
                text: "Round 3 is done.\n\nThe human said: merge PR 12 first.",
                timestamp: "2026-09-25T03:28:05.703Z", truncated: false, path: path
            ))
        )
    }

    func testASyntheticLineAndASidechainLineAreNotTheAgentsWords() throws {
        let path = try write([
            try assistant(text("the foreman's own words")),
            try assistant(text("a subagent's words"), sidechain: true),
            try assistant(text("API Error: overloaded"), model: "<synthetic>"),
        ])
        guard case .message(let message) = TranscriptLastMessage.read(path: path) else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(message.text, "the foreman's own words")
    }

    func testALongTextIsCutAndSaysSo() throws {
        let path = try write([try assistant(text(String(repeating: "a", count: 1600)))])
        guard case .message(let message) = TranscriptLastMessage.read(path: path) else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(message.text.count, 1500)
        XCTAssertTrue(message.truncated)
    }

    func testATranscriptWithNoTextHasNoMessage() throws {
        XCTAssertEqual(TranscriptLastMessage.read(path: try write([try assistant(toolUse), toolResult])), .none)
        XCTAssertEqual(TranscriptLastMessage.read(path: try write([])), .none)
    }

    func testALineStillBeingWrittenIsNotRead() throws {
        let path = try write(
            [try assistant(text("complete")), try assistant(text("half written"))], trailingNewline: false
        )
        guard case .message(let message) = TranscriptLastMessage.read(path: path) else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(message.text, "complete")
    }

    /// The window is one read of the tail: a line the window's start cuts
    /// is not read, and a text before the window is not found.
    func testOnlyTheWindowIsRead() throws {
        let path = try write([
            try assistant(text("before the window")),
            try assistant(["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": String(repeating: "x", count: 4096)]]),
        ])
        XCTAssertEqual(TranscriptLastMessage.read(path: path, window: 2048), .none)
    }

    // MARK: - A session that continued in another file

    private let next = "CD53EBD7-FDE3-444F-8030-42AACD047101"

    private func continuedIn(_ id: String) -> String {
        #"{"type":"continued-in","timestamp":"2026-09-28T03:26:51.038Z","sessionId":"s","continuedInSessionId":"\#(id)"}"#
    }

    func testAContinuedSessionIsReadInTheFileItsRecordNames() throws {
        let first = try write([try assistant(text("said before the session continued")), costState, continuedIn(next)])
        let second = try write([try assistant(text("said after")), try assistant(toolUse)], as: next + ".jsonl")

        guard case .message(let message) = TranscriptLastMessage.read(path: first) else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(message.text, "said after")
        XCTAssertEqual(message.path, second)
    }

    /// The newest text found stays when the next file is gone, holds no
    /// text yet, or the record names something that is not a session id.
    func testAContinuationThatGivesNothingKeepsTheFirstFilesText() throws {
        let first = try write([try assistant(text("the last words on disk")), continuedIn(next)])
        let expected = TranscriptLastMessage.Outcome.message(.init(
            text: "the last words on disk", timestamp: "2026-09-25T03:28:05.703Z", truncated: false, path: first
        ))
        XCTAssertEqual(TranscriptLastMessage.read(path: first), expected, "the next file is gone")

        _ = try write([try assistant(toolUse)], as: next + ".jsonl")
        XCTAssertEqual(TranscriptLastMessage.read(path: first), expected, "the next file holds no text")

        let outside = try write([try assistant(text("outside"))], as: "outside.jsonl")
        let escaping = try write([try assistant(text("stays here")), continuedIn("../" + scratch.lastPathComponent + "/outside")])
        guard case .message(let message) = TranscriptLastMessage.read(path: escaping) else {
            return XCTFail("expected a message")
        }
        XCTAssertEqual(message.text, "stays here", "\(outside) is not read: the id is not a UUID")
    }

    func testTwoFilesThatNameEachOtherEndTheRead() throws {
        let other = "26C08591-8D55-476E-B7EF-A3F08B406B58"
        let first = try write([try assistant(text("one")), continuedIn(next)], as: other + ".jsonl")
        _ = try write([try assistant(text("two")), continuedIn(other)], as: next + ".jsonl")

        guard case .message = TranscriptLastMessage.read(path: first) else { return XCTFail("expected a message") }
    }

    func testAMissingFileIsUnreadable() {
        let path = scratch.appendingPathComponent("gone.jsonl").path
        guard case .unreadable(let detail) = TranscriptLastMessage.read(path: path) else {
            return XCTFail("expected unreadable")
        }
        XCTAssertTrue(detail.contains(path), detail)
    }
}
