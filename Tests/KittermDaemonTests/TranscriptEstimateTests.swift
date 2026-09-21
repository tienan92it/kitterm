import Foundation
import XCTest

@testable import KittermDaemon

/// `TranscriptEstimateCache` over transcripts written into a scratch
/// directory: the sum of a running session's turns priced by
/// `ModelPricing`, what a resumed transcript counts, what a grown file
/// reads, what a malformed line does, and when the bill wins.
final class TranscriptEstimateTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-transcript-estimate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Fixture lines, the shape Claude Code 2.1 writes

    private func user(_ text: String = "…") -> String {
        #"{"parentUuid":null,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u","timestamp":"2026-09-20T01:00:00.000Z","cwd":"/x","sessionId":"s"}"#
    }

    /// One assistant line. `cache1h` is the part of `cacheCreation` written
    /// for an hour, the way `usage.cache_creation` splits it.
    private func assistant(
        _ model: String, request: String, input: Int, cacheCreation: Int, cacheRead: Int, output: Int,
        cache1h: Int = 0, timestamp: String = "2026-09-20T01:00:01.000Z", text: String = "…"
    ) -> String {
        let creation = #"{"ephemeral_5m_input_tokens":\#(cacheCreation - cache1h),"ephemeral_1h_input_tokens":\#(cache1h)}"#
        let usage = #"{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheCreation),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"cache_creation":\#(creation)}"#
        return #"{"parentUuid":"u","requestId":"\#(request)","message":{"model":"\#(model)","id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"usage":\#(usage)},"type":"assistant","uuid":"a","timestamp":"\#(timestamp)","cwd":"/x","sessionId":"s"}"#
    }

    private func costState(_ total: Double) -> String {
        #"{"type":"cost-state","sessionId":"s","totalCostUSD":\#(total),"totalAPIDuration":1,"totalDuration":2,"totalLinesAdded":0,"totalLinesRemoved":0,"startTime":1789000000000,"modelUsage":{}}"#
    }

    private func write(_ lines: [String], as name: String = "t.jsonl", trailingNewline: Bool = true) throws -> String {
        let path = scratch.appendingPathComponent(name).path
        let body = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func estimate(_ cache: TranscriptEstimateCache, _ path: String) throws -> TranscriptEstimate {
        guard case .estimate(let estimate) = cache.estimate(forTranscriptAt: path) else {
            XCTFail("no estimate for \(path): \(cache.estimate(forTranscriptAt: path))")
            throw XCTSkip()
        }
        return estimate
    }

    // MARK: - The proof

    /// Three turns across two models price to the sum worked by hand from
    /// the table: Opus 5 at $5 in, $6.25 a 5-minute write, $10 an hour
    /// write, $0.50 a read, $25 out; Haiku 4.5 at $1, $1.25, $2, $0.10, $5.
    func testThreeTurnsAcrossTwoModelsPriceToTheHandComputedSum() throws {
        let path = try write([
            user(),
            assistant("claude-opus-5", request: "r1", input: 1_000, cacheCreation: 20_000, cacheRead: 0, output: 500, cache1h: 20_000),
            user("tool result"),
            assistant("claude-opus-5", request: "r2", input: 200, cacheCreation: 4_000, cacheRead: 20_000, output: 1_000),
            assistant("claude-haiku-4-5-20251001", request: "r3", input: 3_000, cacheCreation: 0, cacheRead: 0, output: 100),
        ])
        let cache = TranscriptEstimateCache()
        let estimate = try estimate(cache, path)
        // Opus: 1,200 × 5 + 4,000 × 6.25 + 20,000 × 10 + 20,000 × 0.5 + 1,500 × 25 = 278,500 µ$.
        let opus = 0.2785
        // Haiku: 3,000 × 1 + 100 × 5 = 3,500 µ$.
        let haiku = 0.0035
        XCTAssertEqual(estimate.costUSD, opus + haiku, accuracy: 1e-9)
        XCTAssertTrue(estimate.estimated)
        XCTAssertEqual(estimate.turns, 3)
        XCTAssertEqual(Set(estimate.modelUsage.keys), ["claude-opus-5", "claude-haiku-4-5-20251001"])
        let share = try XCTUnwrap(estimate.modelUsage["claude-opus-5"])
        XCTAssertEqual(share, TranscriptEstimate.ModelUsage(
            inputTokens: 1_200, outputTokens: 1_500, cacheReadInputTokens: 20_000, cacheCreationInputTokens: 24_000,
            cacheCreation1hInputTokens: 20_000, costUSD: opus, turns: 2
        ))
        XCTAssertEqual(estimate.modelUsage["claude-haiku-4-5-20251001"]?.costUSD ?? 0, haiku, accuracy: 1e-9)
        XCTAssertEqual(estimate.inTokens, 1_200 + 24_000 + 20_000 + 3_000)
        XCTAssertEqual(estimate.cacheReadTokens, 20_000)
        XCTAssertEqual(estimate.outTokens, 1_600)
        XCTAssertEqual(estimate.startTime, 1_789_866_001_000, "the first counted turn's timestamp")
        XCTAssertEqual(estimate.unpricedModels, [])
    }

    /// One request is several lines with one usage: the second line of a
    /// request adds nothing, and a synthetic line is not a turn.
    func testARequestCountsOnceAndASyntheticLineNotAtAll() throws {
        let path = try write([
            assistant("claude-sonnet-5", request: "r1", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0, text: "thinking"),
            assistant("claude-sonnet-5", request: "r1", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0, text: "tool call"),
            assistant("<synthetic>", request: "", input: 0, cacheCreation: 0, cacheRead: 0, output: 0, text: "API error"),
            assistant("claude-sonnet-5", request: "r2", input: 0, cacheCreation: 0, cacheRead: 0, output: 1_000_000),
        ])
        let estimate = try estimate(TranscriptEstimateCache(), path)
        XCTAssertEqual(estimate.turns, 2)
        XCTAssertEqual(estimate.costUSD, 2 + 10, accuracy: 1e-9)
    }

    /// A transcript resumed after its bill: the old `cost-state` line closes
    /// the turns before it, and only the turns after it are estimated.
    func testAResumedTranscriptEstimatesOnlyTheTurnsAfterItsOldBill() throws {
        let path = try write([
            assistant("claude-opus-5", request: "r1", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
            costState(5),
            user("resumed"),
            assistant("claude-opus-5", request: "r2", input: 0, cacheCreation: 0, cacheRead: 0, output: 100_000, timestamp: "2026-09-20T02:00:00.000Z"),
        ])
        let estimate = try estimate(TranscriptEstimateCache(), path)
        XCTAssertEqual(estimate.turns, 1)
        XCTAssertEqual(estimate.costUSD, 2.5, accuracy: 1e-9)
        XCTAssertEqual(estimate.startTime, 1_789_869_600_000, "the first turn after the old bill")
    }

    /// A grown file reads only the bytes past the last line it summed, and
    /// the estimate adds only the new turns; an unchanged file reads nothing.
    func testAGrownFileReadsOnlyTheGrowth() throws {
        let first = [user(), assistant("claude-opus-5", request: "r1", input: 100_000, cacheCreation: 0, cacheRead: 0, output: 0)]
        let path = try write(first)
        let cache = TranscriptEstimateCache()
        XCTAssertEqual(try estimate(cache, path).costUSD, 0.5, accuracy: 1e-9)
        let size = try XCTUnwrap(cache.entry(for: path)?.bytesRead)
        let fileSize = Int64(first.joined(separator: "\n").utf8.count + 1)
        XCTAssertEqual(size, fileSize, "the first sight walks the whole file")

        XCTAssertEqual(try estimate(cache, path).costUSD, 0.5, accuracy: 1e-9)
        XCTAssertEqual(cache.entry(for: path)?.bytesRead, size, "an unchanged file is one stat and no read")

        // Claude Code is mid-write: a partial line is left for the next read.
        let partial = #"{"parentUuid":"u","requestId":"r2","type":"assistant","message":{"model":"claude-opus-5","usage":{"output_tokens":40000}"#
        try append(partial, to: path)
        // The mtime's resolution can hide a write inside the same tick; a
        // later mtime is the fingerprint the cache reads.
        try touch(path, plus: 2)
        XCTAssertEqual(try estimate(cache, path).turns, 1)
        XCTAssertEqual(cache.entry(for: path)?.bytesRead, size + Int64(partial.utf8.count))
        XCTAssertEqual(cache.entry(for: path)?.offset, fileSize, "the offset stays at the last complete line")

        try append("}}\n", to: path)
        try touch(path, plus: 4)
        let grown = try estimate(cache, path)
        XCTAssertEqual(grown.turns, 2)
        XCTAssertEqual(grown.costUSD, 0.5 + 1.0, accuracy: 1e-9)
        XCTAssertEqual(cache.entry(for: path)?.bytesRead, size + Int64(partial.utf8.count) * 2 + 3, "the growth, and the partial line once more")
    }

    /// A file that shrank is not the file the entry summed: it is read
    /// again from zero.
    func testAFileThatShrankIsReadFromZero() throws {
        let path = try write([
            assistant("claude-opus-5", request: "r1", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
            assistant("claude-opus-5", request: "r2", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
        ])
        let cache = TranscriptEstimateCache()
        XCTAssertEqual(try estimate(cache, path).costUSD, 10, accuracy: 1e-9)
        _ = try write([assistant("claude-opus-5", request: "r3", input: 200_000, cacheCreation: 0, cacheRead: 0, output: 0)])
        try touch(path, plus: 2)
        XCTAssertEqual(try estimate(cache, path).costUSD, 1, accuracy: 1e-9)
        XCTAssertEqual(cache.entry(for: path)?.sums.perModel["claude-opus-5"]?.turns, 1)
    }

    /// A line that fails to parse is skipped, never fatal, and the lines
    /// after it still count; a model with no rate counts its tokens and
    /// names itself as unpriced.
    func testAMalformedLineIsSkippedAndAnUnknownModelIsUnpriced() throws {
        let path = try write([
            assistant("claude-opus-5", request: "r1", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
            #"{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":"#,
            "not json at all",
            #"{"type":"assistant","requestId":"r9","message":{"model":"claude-opus-5"}}"#,
            assistant("claude-opus-5", request: "r2", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
            assistant("claude-novel-9", request: "r3", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
        ])
        let estimate = try estimate(TranscriptEstimateCache(), path)
        XCTAssertEqual(estimate.turns, 3)
        XCTAssertEqual(estimate.costUSD, 10, accuracy: 1e-9)
        XCTAssertEqual(estimate.unpricedModels, ["claude-novel-9"])
        XCTAssertEqual(estimate.modelUsage["claude-novel-9"]?.costUSD, 0)
        XCTAssertEqual(estimate.inTokens, 3_000_000)
    }

    /// A finished transcript is the bill's, not the estimate's: the route
    /// reads the bill first, and the estimate of a file whose last line is
    /// the bill has no turns to count.
    func testAFinishedTranscriptReturnsTheBillNotAnEstimate() throws {
        let path = try write([
            assistant("claude-opus-5", request: "r1", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
            costState(5.25),
        ])
        guard case .bill(let bill) = TranscriptBill.read(path: path) else { return XCTFail("no bill") }
        XCTAssertEqual(bill.totalCostUSD, 5.25)
        XCTAssertEqual(TranscriptEstimateCache().estimate(forTranscriptAt: path), .noEstimate(.noTurns))
        let (status, body) = HTTPAPIHandler.costBody(.bill(bill), estimate: nil, join: AgentJoin(sessionID: "s", transcriptPath: path))
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(body.contains(#""estimated":false"#), body)
        XCTAssertFalse(body.contains(#""estimate":"#), body)
    }

    /// The records Claude Code appends after the bill are no turn: the
    /// estimate has nothing to count and the bill stands, so the route
    /// prints the bill. One turn after the bill is a resume, and then the
    /// estimate counts that turn alone, as before.
    func testRecordsAfterTheBillLeaveItToTheBill() throws {
        let path = try write([
            assistant("claude-opus-5", request: "r1", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
            costState(5.25),
            TranscriptBillTests.queueEnqueue,
            TranscriptBillTests.queueDequeue,
        ])
        guard case .bill(let bill) = TranscriptBill.read(path: path) else { return XCTFail("no bill") }
        XCTAssertEqual(bill.totalCostUSD, 5.25)
        XCTAssertEqual(TranscriptEstimateCache().estimate(forTranscriptAt: path), .noEstimate(.noTurns))
        let (status, body) = HTTPAPIHandler.costBody(.bill(bill), estimate: nil, join: AgentJoin(sessionID: "s", transcriptPath: path))
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(body.contains(#""hasBill":true"#), body)

        let resumed = try write([
            assistant("claude-opus-5", request: "r1", input: 1_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
            costState(5.25),
            TranscriptBillTests.queueEnqueue,
            assistant("claude-opus-5", request: "r2", input: 2_000_000, cacheCreation: 0, cacheRead: 0, output: 0),
        ], as: "resumed.jsonl")
        XCTAssertEqual(TranscriptBill.read(path: resumed), .noBill(.noCostStateLine))
        let estimate = try estimate(TranscriptEstimateCache(), resumed)
        XCTAssertEqual(estimate.turns, 1)
        XCTAssertEqual(estimate.inTokens, 2_000_000)
        XCTAssertEqual(estimate.costUSD, 10, accuracy: 0.0001)
    }

    /// No turn yet, a file over the cap, and a missing file each say why.
    func testTheThreeEmptyAnswers() throws {
        let empty = try write([user()], as: "empty.jsonl")
        XCTAssertEqual(TranscriptEstimateCache().estimate(forTranscriptAt: empty), .noEstimate(.noTurns))
        let large = TranscriptEstimateCache(maxBytes: 16)
        XCTAssertEqual(large.estimate(forTranscriptAt: empty), .noEstimate(.transcriptTooLarge))
        guard case .unreadable(let reason) = TranscriptEstimateCache().estimate(forTranscriptAt: scratch.appendingPathComponent("gone.jsonl").path)
        else { return XCTFail("a missing file is unreadable") }
        XCTAssertTrue(reason.contains("gone.jsonl"), reason)
    }

    // MARK: - The table

    func testTheRatesFollowTheIdRuleAndAnUnknownIdHasNone() {
        XCTAssertEqual(ModelPricing.rates(for: "claude-opus-5[1m]"), ModelPricing.rates(for: "claude-opus-5"), "long context is standard pricing")
        XCTAssertEqual(ModelPricing.rates(for: "claude-haiku-4-5-20251001")?.input, 1)
        XCTAssertEqual(ModelPricing.rates(for: "claude-fable-5-1")?.cacheRead, 0.25)
        XCTAssertEqual(ModelPricing.rates(for: "claude-fable-5")?.cacheRead, 1)
        XCTAssertNil(ModelPricing.rates(for: "<synthetic>"))
        XCTAssertNil(ModelPricing.rates(for: "claude-3-5-sonnet-20241022"))
        XCTAssertNil(ModelPricing.rates(for: "us.anthropic.claude-opus-5"))
    }

    // MARK: - Helpers

    /// Move the file's mtime `seconds` past its current value, because two
    /// writes inside one filesystem tick share a fingerprint.
    private func touch(_ path: String, plus seconds: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let mtime = try XCTUnwrap(attributes[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: mtime.addingTimeInterval(TimeInterval(seconds))], ofItemAtPath: path)
    }
}


