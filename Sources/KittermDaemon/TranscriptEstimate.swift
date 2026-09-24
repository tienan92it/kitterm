#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers

/// What a running session has cost so far, estimated from its transcript:
/// the `message.usage` of every `"type":"assistant"` line after the last
/// `cost-state` line, summed per `message.model` and priced with
/// `ModelPricing`.
///
/// ## Why an estimate exists
///
/// Claude Code writes the bill (`TranscriptBill`) when the session ends,
/// so a running session has no bill and the page printed a dash for hours.
/// The turns are in the file the whole time. The estimate reads them, and
/// it says `estimated: true` so nothing mistakes it for the bill; when the
/// `cost-state` line lands, the bill wins.
///
/// ## What the estimate counts
///
/// One API request is written as several assistant lines, one per content
/// block, each carrying the same `requestId` and the same `usage`, and the
/// lines of one request sit together (measured 2026-09-20 over 827
/// transcripts and 20,944 requests: never interleaved), so a line whose
/// `requestId` is the previous counted line's is the same request. A
/// `"<synthetic>"` model is a line Claude Code made itself, with no usage.
/// A `cost-state` line closes the turns before it: a resumed transcript
/// estimates only the turns after its old bill.
///
/// ## What the estimate misses
///
/// Measured 2026-09-20 over 141 finished transcripts over $1: the estimate
/// sits 1.25% under the bill at the median and 2.6% under at the tenth
/// percentile, because the bill also counts requests that wrote no turn
/// (a retry, an interrupted request, the Haiku title call). A session
/// that ran subagents is further under, because their turns are in files
/// under `<session>/subagents/` and this reads the one file: 17% on the
/// dearest session on this machine. The `~` on the page is for that.
public struct TranscriptEstimate: Codable, Equatable, Sendable {
    /// One model's share, keyed by model id as the assistant lines name it.
    public struct ModelUsage: Codable, Equatable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadInputTokens: Int
        public var cacheCreationInputTokens: Int
        /// The part of `cacheCreationInputTokens` written for an hour, at
        /// twice the base rate; the rest was written for five minutes.
        public var cacheCreation1hInputTokens: Int
        /// Zero for a model `ModelPricing` does not know.
        public var costUSD: Double
        public var turns: Int

        static let zero = ModelUsage(
            inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
            cacheCreation1hInputTokens: 0, costUSD: 0, turns: 0
        )
    }

    /// Always true: the shape says which kind of number it carries.
    public var estimated: Bool = true
    public var costUSD: Double
    public var modelUsage: [String: ModelUsage]
    /// Input, cache creation and cache read, the `Nk in` of a round record.
    public var inTokens: Int
    public var cacheReadTokens: Int
    public var outTokens: Int
    /// API requests counted, not lines, the parent's and its subagents'.
    public var turns: Int
    /// Subagent transcripts under `<session>/subagents/` summed with the
    /// parent; zero for a session that spawned none.
    public var subagentFiles: Int
    /// Epoch milliseconds: when the file was last checked for new turns.
    public var asOf: Int64
    /// Epoch milliseconds of the first counted turn, so a page can place
    /// the session in a range the way it places a bill by `startTime`.
    public var startTime: Int64?
    /// Models with turns and no rate: their tokens are in, their dollars
    /// are not. Empty on every transcript this daemon knows the models of.
    public var unpricedModels: [String]

    /// Why a transcript has no estimate.
    public enum NoEstimate: String, Equatable, Sendable {
        /// No assistant turn after the last `cost-state` line: a session
        /// that has not answered yet.
        case noTurns
        /// The transcript and its subagent files together are over
        /// `TranscriptEstimateCache.maxBytes`.
        case transcriptTooLarge
    }

    public enum Outcome: Equatable, Sendable {
        case estimate(TranscriptEstimate)
        case noEstimate(NoEstimate)
        /// The file could not be opened or read; the message names why.
        case unreadable(String)
    }
}

/// The estimate per transcript path, kept with the byte offset the sum
/// reached, so an unchanged file costs one `stat` and a grown file reads
/// only the bytes past the last line it summed.
///
/// ## What invalidates an entry
///
/// The file's size or mtime, like `TranscriptModelCache`. A file that grew
/// is read from the entry's offset, which is the end of the last complete
/// line it summed; the running sums, the last request id and the start
/// time carry on. A file that shrank, or whose mtime went backwards, is
/// not the file the entry summed: it is read again from zero. A line that
/// fails to parse is skipped and the offset moves past it.
///
/// ## The subagent files
///
/// Every file, the parent and each subagent, is its own entry keyed by its
/// path, so each is read from its own offset. Every call lists
/// `<session>/subagents/` (one `readdir` and one `stat` per file; 0.13 ms
/// for 48 files on this machine, 2026-09-24), because that is what notices
/// a file that appeared or vanished: a new file is read whole, a listed
/// file that grew reads only its growth, and the entry of a file no longer
/// listed is dropped with its sums. A directory that does not exist lists
/// nothing. A subagent entry also carries the parent's start time it was
/// gated by (`Entry.since`); when the parent's turns close under a new
/// `cost-state` line and reopen, that time moves and the subagent files
/// are read again from zero under the new gate.
///
/// Confined to `TranscriptBill.queue` by its callers, so a long first
/// walk never runs twice at once; the lock keeps a caller on another
/// queue correct, not fast.
public final class TranscriptEstimateCache: @unchecked Sendable {
    /// A session whose transcript and subagent files together are over
    /// this is not estimated. The first sight of a path walks the whole
    /// file on the serial transcript queue, behind which every bill read
    /// and every session list's model read waits, and it holds a line at
    /// a time in memory; 512 MiB is minutes of that queue, for a
    /// transcript Claude Code itself can no longer resume. The largest on
    /// this machine on 2026-09-20 was 57 MB.
    public static let maxBytes: Int64 = 512 << 20

    /// The bytes read at a time; a line is never longer than the largest
    /// tool result, well under this.
    static let chunkBytes = 1 << 20
    /// A line longer than this is skipped whole, so a damaged file cannot
    /// make the reader hold it in memory.
    static let maxLineBytes = 16 << 20
    /// How many files the cache keeps; the least recently asked goes first.
    /// A session's subagents are one entry each, and one session on this
    /// machine held 239 files (2026-09-20), so the bound is well above that.
    static let maxEntries = 4096

    struct Sums: Equatable {
        var perModel: [String: TranscriptEstimate.ModelUsage] = [:]
        var lastRequestId: String?
        var startTime: Int64?
        var turns: Int { perModel.values.reduce(0) { $0 + $1.turns } }

        /// Add another file's sums: the parent's and its subagents' turns
        /// are one session's. The request id is per file and does not carry.
        mutating func add(_ other: Sums) {
            for (model, share) in other.perModel {
                var mine = perModel[model] ?? .zero
                mine.inputTokens += share.inputTokens
                mine.outputTokens += share.outputTokens
                mine.cacheReadInputTokens += share.cacheReadInputTokens
                mine.cacheCreationInputTokens += share.cacheCreationInputTokens
                mine.cacheCreation1hInputTokens += share.cacheCreation1hInputTokens
                mine.turns += share.turns
                perModel[model] = mine
            }
            if let theirs = other.startTime {
                startTime = min(startTime ?? theirs, theirs)
            }
        }
    }

    struct Entry: Equatable {
        var size: Int64
        var mtime: Int64
        /// The end of the last complete line summed.
        var offset: Int64
        var sums: Sums
        /// Set while the reader is inside a line over `maxLineBytes`: the
        /// bytes up to the next newline are dropped.
        var droppingLongLine: Bool
        /// Bytes read for this path since it was first seen; a test asserts
        /// a grown file reads only the growth.
        var bytesRead: Int64
        var touched: Int64
        /// For a subagent file: the parent's first turn after its last
        /// `cost-state` line, epoch milliseconds; a turn before it is not
        /// counted. Nil for the parent itself.
        var since: Int64?

        static func fresh(since: Int64?, touched: Int64) -> Entry {
            Entry(size: 0, mtime: 0, offset: 0, sums: Sums(), droppingLongLine: false, bytesRead: 0, touched: touched, since: since)
        }
    }

    /// One listed subagent file, with the fingerprint the listing took.
    struct Subagent: Equatable {
        var path: String
        var size: Int64
        var mtime: Int64
    }

    private let lock = NIOLock()
    private var entries: [String: Entry] = [:]
    /// The subagent paths each parent listed last, so a file that vanished
    /// loses its entry.
    private var subagentPaths: [String: [String]] = [:]
    private let maxBytes: Int64

    public init(maxBytes: Int64 = TranscriptEstimateCache.maxBytes) {
        self.maxBytes = maxBytes
    }

    /// The estimate for the session whose transcript is at `path`, its
    /// subagent files included, as of `now`.
    public func estimate(forTranscriptAt path: String, now: Date = Date()) -> TranscriptEstimate.Outcome {
        guard let (size, mtime) = TranscriptModelCache.fingerprint(path) else {
            forget(path)
            return .unreadable("cannot stat \(path): \(String(cString: strerror(errno)))")
        }
        let subagents = Self.listSubagents(of: path)
        let total = subagents.reduce(size) { $0 + $1.size }
        guard total <= maxBytes else {
            forget(path)
            return .noEstimate(.transcriptTooLarge)
        }
        let asOf = Int64(now.timeIntervalSince1970 * 1000)
        let parent: Entry
        switch refresh(path, size: size, mtime: mtime, since: nil, asOf: asOf) {
        case .entry(let entry): parent = entry
        case .unreadable(let reason):
            forget(path)
            return .unreadable(reason)
        }
        // A file listed last time and not now is gone with its sums.
        let listed = Set(subagents.map(\.path))
        lock.withLock {
            for gone in subagentPaths[path] ?? [] where !listed.contains(gone) {
                entries.removeValue(forKey: gone)
            }
            subagentPaths[path] = subagents.map(\.path)
        }
        var sums = parent.sums
        // A subagent turn follows a parent turn, so with no parent turn there
        // is nothing under the gate to count.
        if let since = parent.sums.startTime {
            for subagent in subagents {
                switch refresh(subagent.path, size: subagent.size, mtime: subagent.mtime, since: since, asOf: asOf) {
                case .entry(let entry): sums.add(entry.sums)
                case .unreadable: lock.withLock { _ = entries.removeValue(forKey: subagent.path) }
                }
            }
        }
        return Self.outcome(of: sums, asOf: asOf, subagentFiles: subagents.count)
    }

    /// For a test: the entry a path holds.
    func entry(for path: String) -> Entry? { lock.withLock { entries[path] } }

    /// Drop a parent and every subagent entry it listed.
    private func forget(_ path: String) {
        lock.withLock {
            entries.removeValue(forKey: path)
            for subagent in subagentPaths.removeValue(forKey: path) ?? [] {
                entries.removeValue(forKey: subagent)
            }
        }
    }

    enum Refreshed {
        case entry(Entry)
        case unreadable(String)
    }

    /// The entry for one file at the fingerprint just taken: the cached one
    /// when the file only grew under the same gate, read on from its offset;
    /// a fresh one read from zero otherwise; untouched when nothing changed.
    private func refresh(_ path: String, size: Int64, mtime: Int64, since: Int64?, asOf: Int64) -> Refreshed {
        var entry: Entry
        if let cached = lock.withLock({ entries[path] }), cached.offset <= size, cached.mtime <= mtime, cached.since == since {
            entry = cached
        } else {
            entry = .fresh(since: since, touched: asOf)
        }
        if entry.size != size || entry.mtime != mtime {
            switch Self.walk(path: path, from: entry.offset, to: size, entry: &entry) {
            case .read:
                entry.size = size
                entry.mtime = mtime
            case .unreadable(let reason):
                lock.withLock { _ = entries.removeValue(forKey: path) }
                return .unreadable(reason)
            }
        }
        entry.touched = asOf
        lock.withLock {
            entries[path] = entry
            if entries.count > Self.maxEntries, let oldest = entries.min(by: { $0.value.touched < $1.value.touched }) {
                entries.removeValue(forKey: oldest.key)
            }
        }
        return .entry(entry)
    }

    // MARK: - The subagent directory

    /// `<transcript minus .jsonl>/subagents`, where Claude Code writes a
    /// session's subagent transcripts.
    static func subagentDirectory(of transcript: String) -> String {
        let stem = transcript.hasSuffix(".jsonl") ? String(transcript.dropLast(".jsonl".count)) : transcript
        return stem + "/subagents"
    }

    /// The regular `*.jsonl` files under the session's subagent directory
    /// with their fingerprints, by name; none when the directory is missing
    /// or a file went away between the listing and its `stat`.
    static func listSubagents(of transcript: String) -> [Subagent] {
        let directory = subagentDirectory(of: transcript)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var listed: [Subagent] = []
        for name in names.sorted() where name.hasSuffix(".jsonl") {
            let path = directory + "/" + name
            var status = stat()
            guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { continue }
            #if canImport(Darwin)
            let spec = status.st_mtimespec
            #else
            let spec = status.st_mtim
            #endif
            listed.append(Subagent(
                path: path, size: Int64(status.st_size),
                mtime: Int64(spec.tv_sec) * 1_000_000_000 + Int64(spec.tv_nsec)
            ))
        }
        return listed
    }

    // MARK: - The walk

    enum Walk {
        case read
        case unreadable(String)
    }

    private static let assistantGate = Array(#""type":"assistant""#.utf8)
    private static let costStateGate = Array(#""type":"cost-state""#.utf8)

    /// Read `path` from `from` up to `to`, summing every complete line into
    /// `entry.sums` and moving `entry.offset` past it. The partial line at
    /// `to`, one Claude Code is still writing, is left for the next read.
    static func walk(path: String, from: Int64, to: Int64, entry: inout Entry) -> Walk {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            return .unreadable("cannot open \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var position = from
        var carry: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        while position < to {
            let want = Int(min(Int64(chunkBytes), to - position))
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress, want, off_t(position))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return .unreadable("cannot read \(path): \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            entry.bytesRead += Int64(n)
            position += Int64(n)
            carry.append(contentsOf: buffer[0..<n])
            var start = 0
            while let newline = newlineIndex(in: carry, from: start) {
                if entry.droppingLongLine {
                    entry.droppingLongLine = false
                } else {
                    take(carry[start..<newline], into: &entry.sums, since: entry.since)
                }
                start = newline + 1
            }
            entry.offset = position - Int64(carry.count - start)
            carry.removeSubrange(0..<start)
            if carry.count > maxLineBytes {
                // Too long to be a turn: drop it and everything up to its
                // newline, so the reader never holds more than a chunk.
                entry.droppingLongLine = true
                entry.offset += Int64(carry.count)
                carry.removeAll(keepingCapacity: true)
            }
        }
        return .read
    }

    /// One complete line: a `cost-state` line closes the sums, an
    /// assistant line adds its request's usage, anything else is skipped.
    /// With `since`, a turn timestamped before it is the old bill's and is
    /// skipped too.
    static func take(_ line: ArraySlice<UInt8>, into sums: inout Sums, since: Int64? = nil) {
        if contains(line, costStateGate),
           let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
           object["type"] as? String == "cost-state" {
            sums = Sums()
            return
        }
        guard contains(line, assistantGate),
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let model = message["model"] as? String, !model.isEmpty, model != TranscriptModel.syntheticModel,
              let usage = message["usage"] as? [String: Any]
        else { return }
        let stamp = (object["timestamp"] as? String).flatMap(TranscriptUsage.parseUTC).map { Int64($0.timeIntervalSince1970 * 1000) }
        if let since, let stamp, stamp < since { return }
        let request = object["requestId"] as? String ?? ""
        if !request.isEmpty, request == sums.lastRequestId { return }
        sums.lastRequestId = request.isEmpty ? nil : request
        let creation = usage["cache_creation"] as? [String: Any]
        var share = sums.perModel[model] ?? .zero
        share.inputTokens += usage["input_tokens"] as? Int ?? 0
        share.outputTokens += usage["output_tokens"] as? Int ?? 0
        share.cacheReadInputTokens += usage["cache_read_input_tokens"] as? Int ?? 0
        share.cacheCreationInputTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
        share.cacheCreation1hInputTokens += creation?["ephemeral_1h_input_tokens"] as? Int ?? 0
        share.turns += 1
        sums.perModel[model] = share
        if sums.startTime == nil, let stamp { sums.startTime = stamp }
    }

    /// The sums priced, or `.noEstimate(.noTurns)` with nothing to price.
    static func outcome(of sums: Sums, asOf: Int64, subagentFiles: Int) -> TranscriptEstimate.Outcome {
        guard sums.turns > 0 else { return .noEstimate(.noTurns) }
        var priced: [String: TranscriptEstimate.ModelUsage] = [:]
        var unpriced: [String] = []
        var total = 0.0
        for (model, share) in sums.perModel {
            var row = share
            if let rates = ModelPricing.rates(for: model) {
                row.costUSD = rates.cost(
                    input: row.inputTokens,
                    cacheWrite5m: row.cacheCreationInputTokens - row.cacheCreation1hInputTokens,
                    cacheWrite1h: row.cacheCreation1hInputTokens,
                    cacheRead: row.cacheReadInputTokens,
                    output: row.outputTokens
                )
                total += row.costUSD
            } else {
                unpriced.append(model)
            }
            priced[model] = row
        }
        let rows = priced.values
        return .estimate(TranscriptEstimate(
            costUSD: total,
            modelUsage: priced,
            inTokens: rows.reduce(0) { $0 + $1.inputTokens + $1.cacheCreationInputTokens + $1.cacheReadInputTokens },
            cacheReadTokens: rows.reduce(0) { $0 + $1.cacheReadInputTokens },
            outTokens: rows.reduce(0) { $0 + $1.outputTokens },
            turns: sums.turns,
            subagentFiles: subagentFiles,
            asOf: asOf,
            startTime: sums.startTime,
            unpricedModels: unpriced.sorted()
        ))
    }

    /// `memchr`, so a chunk of tool results costs no Swift loop.
    private static func newlineIndex(in bytes: [UInt8], from start: Int) -> Int? {
        bytes.withUnsafeBufferPointer { buffer -> Int? in
            guard start < buffer.count, let base = buffer.baseAddress,
                  let hit = memchr(base + start, Int32(UInt8(ascii: "\n")), buffer.count - start)
            else { return nil }
            return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
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
