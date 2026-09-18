import Foundation
import XCTest

@testable import KittermDaemon

/// `TranscriptModel` over transcripts written into a scratch directory,
/// `TranscriptModelCache` over the same files as they grow, and the naming
/// rule of `design-foundation.md` (`ModelName`), which the row prints.
final class TranscriptModelTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-transcript-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func user(_ text: String = "…") -> String {
        #"{"parentUuid":null,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u","timestamp":"2026-09-18T01:00:00.000Z","cwd":"/x","sessionId":"s"}"#
    }

    private func assistant(_ model: String, text: String = "…") -> String {
        #"{"parentUuid":"u","message":{"model":"\#(model)","id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":1,"output_tokens":1}},"requestId":"r","type":"assistant","uuid":"a","timestamp":"2026-09-18T01:00:01.000Z","cwd":"/x","sessionId":"s"}"#
    }

    private func write(_ lines: [String], as name: String = "t.jsonl", trailingNewline: Bool = true) throws -> String {
        let path = scratch.appendingPathComponent(name).path
        let body = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func append(_ lines: [String], to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    // MARK: - The reader

    func testTheLastAssistantLineNamesTheModel() throws {
        let path = try write([
            user(), assistant("claude-opus-5"), user("tool result"), assistant("claude-fable-5-1"),
            user("a tool result that quotes \\\"model\\\":\\\"claude-haiku-4-5-20251001\\\" in its text"),
        ])
        XCTAssertEqual(TranscriptModel.read(path: path), .model("claude-fable-5-1"))
    }

    func testATranscriptWithNoAssistantTurnYieldsNothing() throws {
        let path = try write([user(), user("still typing")])
        XCTAssertEqual(TranscriptModel.read(path: path), .none)
        let empty = try write([], as: "empty.jsonl", trailingNewline: false)
        XCTAssertEqual(TranscriptModel.read(path: empty), .none)
    }

    func testASyntheticAssistantLineIsNotAModel() throws {
        let path = try write([user(), assistant("<synthetic>", text: "API error")])
        XCTAssertEqual(TranscriptModel.read(path: path), .none)
    }

    func testAnUnreadablePathSaysWhy() {
        let missing = scratch.appendingPathComponent("missing.jsonl").path
        guard case .unreadable(let reason) = TranscriptModel.read(path: missing) else {
            return XCTFail("expected unreadable")
        }
        XCTAssertTrue(reason.contains("cannot open"), reason)
    }

    /// A line the window cuts is not read: its model could be inside a
    /// tool call's text rather than on `message.model`.
    func testALineCutByTheWindowIsNotRead() throws {
        let path = try write([assistant("claude-opus-5", text: String(repeating: "x", count: 600)), user("short")])
        XCTAssertEqual(TranscriptModel.read(path: path, window: 400), .none)
        XCTAssertEqual(TranscriptModel.read(path: path), .model("claude-opus-5"))
    }

    func testALineStillBeingWrittenIsNotRead() throws {
        let path = try write([user(), assistant("claude-opus-5")], trailingNewline: false)
        XCTAssertEqual(TranscriptModel.read(path: path), .none)
    }

    // MARK: - The cache

    func testAnUnchangedFileAnswersFromTheEntryAndAGrownOneIsReadAgain() throws {
        let path = try write([user(), assistant("claude-opus-5")])
        let cache = TranscriptModelCache()
        XCTAssertEqual(cache.model(forTranscriptAt: path), "claude-opus-5")
        let first = try XCTUnwrap(cache.entry(for: path))
        XCTAssertEqual(cache.model(forTranscriptAt: path), "claude-opus-5")
        XCTAssertEqual(cache.entry(for: path), first, "an unchanged file keeps its entry")

        try append([user("tool result"), assistant("claude-fable-5-1")], to: path)
        XCTAssertEqual(cache.model(forTranscriptAt: path), "claude-fable-5-1")
        XCTAssertNotEqual(cache.entry(for: path)?.size, first.size, "the size invalidated the entry")
    }

    /// A long tool result after the last turn pushes every assistant line
    /// out of the window; the entry keeps the model the path last yielded.
    func testAGrownFileWithNoAssistantLineInTheWindowKeepsTheLastModel() throws {
        let path = try write([user(), assistant("claude-opus-5")])
        let cache = TranscriptModelCache(window: 2048)
        XCTAssertEqual(cache.model(forTranscriptAt: path), "claude-opus-5")
        try append([user(String(repeating: "y", count: 4096))], to: path)
        XCTAssertEqual(TranscriptModel.read(path: path, window: 2048), .none)
        XCTAssertEqual(cache.model(forTranscriptAt: path), "claude-opus-5")

        // A path never seen with the same tail yields nothing: no guess.
        let fresh = try write([user(String(repeating: "y", count: 4096))], as: "fresh.jsonl")
        XCTAssertNil(cache.model(forTranscriptAt: fresh))
    }

    func testTheListKeepsOneEntryPerLivePathAndSkipsAMissingFile() throws {
        let a = try write([user(), assistant("claude-opus-5")], as: "a.jsonl")
        let b = try write([user()], as: "b.jsonl")
        let cache = TranscriptModelCache()
        let first = cache.models(for: [(key: "A", path: a), (key: "B", path: b), (key: "C", path: scratch.appendingPathComponent("c.jsonl").path)])
        XCTAssertEqual(first, ["A": "claude-opus-5"])
        XCTAssertNotNil(cache.entry(for: a))
        XCTAssertNotNil(cache.entry(for: b), "no model is still an entry: the file was read")

        let second = cache.models(for: [(key: "B", path: b)])
        XCTAssertEqual(second, [:])
        XCTAssertNil(cache.entry(for: a), "a path no longer listed is dropped")
    }

    // MARK: - The name

    func testTheNamingRuleFromTheFoundation() {
        XCTAssertEqual(ModelName.name(for: "claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ModelName.name(for: "claude-opus-5[1m]"), "Opus 5 · 1M")
        XCTAssertEqual(ModelName.name(for: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelName.name(for: "claude-fable-5"), "Fable 5")
        XCTAssertEqual(ModelName.name(for: "claude-opus-4-1-20250805[1m]"), "Opus 4.1 · 1M")
    }

    func testAnIdTheRuleDoesNotFitPrintsUnchanged() {
        XCTAssertEqual(ModelName.name(for: "us.anthropic.claude-fable-5-1"), "us.anthropic.claude-fable-5-1")
        XCTAssertEqual(ModelName.name(for: "claude-3-5-sonnet-20241022"), "claude-3-5-sonnet-20241022")
        XCTAssertEqual(ModelName.name(for: "claude-"), "claude-")
        XCTAssertEqual(ModelName.name(for: "claude-opus"), "claude-opus")
        XCTAssertEqual(ModelName.name(for: "<synthetic>"), "<synthetic>")
    }
}
