#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers

/// The model a Claude Code session runs on, read from its transcript: the
/// `message.model` of the last `"type":"assistant"` line.
///
/// ## Where the line sits
///
/// Measured on 2026-09-18 over the 40 newest transcripts under
/// `~/.claude/projects/`: the end of a file is tool results, a `cost-state`
/// bill, `last-prompt` and `attachment` lines, and the last assistant line
/// sits within 4 KiB of the end in 3 of the 40, within 64 KiB in 39, and
/// within 256 KiB in all 40 (median 6.8 KiB, largest 101 KiB). So the
/// window is 256 KiB: one `pread`, whatever the size of the file.
///
/// ## What is never guessed
///
/// A transcript with no assistant line in the window yields `.none`, and
/// so does a `"<synthetic>"` model, which Claude Code writes on an
/// assistant line it made itself (an error message, not a turn). The row
/// then carries no model. The reader does not fall back to the bill's
/// `modelUsage`, whose keys are every model the session has used, not the
/// one it runs on now.
public enum TranscriptModel {
    public enum Outcome: Equatable, Sendable {
        case model(String)
        /// No assistant line in the window, or only synthetic ones.
        case none
        /// The file could not be opened or read; the message names why.
        case unreadable(String)
    }

    /// How far back from the end the reader looks, in one `pread`.
    public static let tailWindowBytes = 262_144

    /// The model id the transcript at `path` last answered with.
    public static func read(path: String, window: Int = tailWindowBytes) -> Outcome {
        switch TranscriptBill.readTail(path: path, window: window) {
        case .tail(let tail, let wholeFile):
            return parseTail(tail, tailIsWholeFile: wholeFile)
        case .unreadable(let reason):
            return .unreadable(reason)
        }
    }

    private static let assistantGate = Array(#""type":"assistant""#.utf8)
    static let syntheticModel = "<synthetic>"

    /// The last complete assistant line's model in `tail`. A line cut by the
    /// window's start, or one still being written at the end, is not read.
    static func parseTail(_ tail: ArraySlice<UInt8>, tailIsWholeFile: Bool) -> Outcome {
        let newline = UInt8(ascii: "\n")
        var lines = tail.split(separator: newline, omittingEmptySubsequences: true)
        if tail.last != newline { lines.removeLast(lines.isEmpty ? 0 : 1) }
        if !tailIsWholeFile, !lines.isEmpty, tail.first != newline { lines.removeFirst() }
        for line in lines.reversed() {
            guard contains(line, assistantGate) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty
            else { continue }
            return model == syntheticModel ? .none : .model(model)
        }
        return .none
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

/// The model per transcript path, as the session list serves it, so a list
/// of forty sessions costs forty `stat` calls and a read only of the files
/// that grew since the last list.
///
/// ## What invalidates an entry
///
/// The file's size or mtime. An unchanged file answers from the entry. A
/// changed file is read again; when its window names a model, that model
/// replaces the entry, and when its window holds no assistant line (a long
/// tool result landed after the last turn) the entry keeps the model the
/// path last yielded, because the model a session runs on does not change
/// between one assistant line and the next without a new assistant line.
/// A path never seen, or one whose file cannot be read, yields nothing.
///
/// Confined to `TranscriptBill.queue` by its callers; the lock keeps a
/// caller on another queue correct, not fast.
public final class TranscriptModelCache: @unchecked Sendable {
    struct Entry: Equatable {
        var size: Int64
        var mtime: Int64
        var model: String?
    }

    private let lock = NIOLock()
    private var entries: [String: Entry] = [:]
    private let window: Int

    public init(window: Int = TranscriptModel.tailWindowBytes) {
        self.window = window
    }

    /// The model for every session that has a transcript, keyed as given.
    /// Entries for paths not in `joins` are dropped, so the cache holds one
    /// entry per live session and nothing for a session that ended.
    public func models<Key: Hashable>(for joins: [(key: Key, path: String)]) -> [Key: String] {
        let wanted = Set(joins.map(\.path))
        lock.withLock { entries = entries.filter { wanted.contains($0.key) } }
        var models: [Key: String] = [:]
        for join in joins {
            if let model = model(forTranscriptAt: join.path) { models[join.key] = model }
        }
        return models
    }

    /// The model for one transcript, or nil when it has none.
    public func model(forTranscriptAt path: String) -> String? {
        guard let (size, mtime) = Self.fingerprint(path) else {
            lock.withLock { _ = entries.removeValue(forKey: path) }
            return nil
        }
        let cached = lock.withLock { entries[path] }
        if let cached, cached.size == size, cached.mtime == mtime { return cached.model }
        let model: String?
        switch TranscriptModel.read(path: path, window: window) {
        case .model(let id):
            model = id
        case .none:
            model = cached?.model
        case .unreadable:
            lock.withLock { _ = entries.removeValue(forKey: path) }
            return nil
        }
        lock.withLock { entries[path] = Entry(size: size, mtime: mtime, model: model) }
        return model
    }

    /// For a test: the entry a path holds.
    func entry(for path: String) -> Entry? { lock.withLock { entries[path] } }

    /// Size and mtime in nanoseconds, or nil when the file cannot be stat'd.
    static func fingerprint(_ path: String) -> (Int64, Int64)? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        #if canImport(Darwin)
        let spec = status.st_mtimespec
        #else
        let spec = status.st_mtim
        #endif
        return (Int64(status.st_size), Int64(spec.tv_sec) * 1_000_000_000 + Int64(spec.tv_nsec))
    }
}
