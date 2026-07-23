import Foundation
import KittermProtocol

/// A fixed-capacity ring of session output with absolute stream offsets.
///
/// Every output byte a session ever produces flows through one of these.
/// `head` counts bytes since spawn and never restarts, so a client can name a
/// point in the stream ("I have everything before offset N") even after the
/// bytes behind it were pruned — reattach gap-replay, observer catch-up, and
/// tail replay are all `snapshot(from:)` with different starting offsets.
///
/// The storage is preallocated and appends copy only the incoming chunk
/// (two slices at the wrap seam), keeping the per-read cost O(chunk) on the
/// event loop. Mutated only under `PtySession.stateLock`; not internally
/// synchronized.
public struct SessionLog {
    public struct Snapshot {
        /// The replayable bytes, oldest first.
        public let data: Data
        /// Absolute stream offset of `data`'s first byte (`head` when empty).
        public let start: UInt64
        /// The requested offset was outside the retained range, so `data` is
        /// the full ring and the requester's screen state is stale.
        public let pruned: Bool
    }

    private var storage: [UInt8]
    private let capacity: Int
    /// Total bytes ever appended; offsets `[base, head)` are retained.
    public private(set) var head: UInt64 = 0
    /// Bytes currently retained (≤ capacity).
    private var retained = 0
    /// Next write position in `storage`.
    private var writeIndex = 0

    /// Absolute offset of the oldest retained byte.
    public var base: UInt64 { head - UInt64(retained) }

    public init(capacity: Int = KittermConstants.sessionLogBytes) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        head &+= UInt64(data.count)

        // A chunk at least as large as the ring: only its suffix survives.
        if data.count >= capacity {
            data.suffix(capacity).withUnsafeBytes { src in
                storage.withUnsafeMutableBytes { dst in
                    dst.copyMemory(from: src)
                }
            }
            writeIndex = 0
            retained = capacity
            return
        }

        let firstSlice = min(data.count, capacity - writeIndex)
        data.prefix(firstSlice).withUnsafeBytes { src in
            storage.withUnsafeMutableBytes { dst in
                dst.baseAddress!.advanced(by: writeIndex)
                    .copyMemory(from: src.baseAddress!, byteCount: firstSlice)
            }
        }
        let remainder = data.count - firstSlice
        if remainder > 0 {
            data.suffix(remainder).withUnsafeBytes { src in
                storage.withUnsafeMutableBytes { dst in
                    dst.baseAddress!
                        .copyMemory(from: src.baseAddress!, byteCount: remainder)
                }
            }
        }
        writeIndex = (writeIndex + data.count) % capacity
        retained = min(retained + data.count, capacity)
    }

    /// Bytes from `offset` to `head`. An offset outside `[base, head]` yields
    /// the full ring with `pruned == true` so the caller can tell the client
    /// to resync instead of appending to a stale screen.
    public func snapshot(from offset: UInt64) -> Snapshot {
        guard offset >= base, offset <= head else {
            return Snapshot(data: readRange(from: base), start: base, pruned: true)
        }
        return Snapshot(data: readRange(from: offset), start: offset, pruned: false)
    }

    /// The most recent `maxBytes` (or fewer) of retained output.
    public func tail(maxBytes: Int) -> Snapshot {
        let start = max(base, head - UInt64(min(maxBytes, retained)))
        return Snapshot(data: readRange(from: start), start: start, pruned: false)
    }

    /// Copy `[offset, head)` out of the ring; `offset` must be in `[base, head]`.
    private func readRange(from offset: UInt64) -> Data {
        let length = Int(head - offset)
        guard length > 0 else { return Data() }
        // Ring index of the requested offset, counting back from writeIndex.
        let back = length % capacity
        let startIndex = (writeIndex - back + capacity) % capacity
        let firstSlice = min(length, capacity - startIndex)
        var out = Data(capacity: length)
        storage.withUnsafeBytes { src in
            out.append(
                src.baseAddress!.advanced(by: startIndex)
                    .assumingMemoryBound(to: UInt8.self),
                count: firstSlice
            )
            if length > firstSlice {
                out.append(
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    count: length - firstSlice
                )
            }
        }
        return out
    }
}
