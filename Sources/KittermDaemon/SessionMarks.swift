import Foundation
import KittermProtocol

/// One shell-integration mark, positioned in the session log by offset.
///
/// The client's emulator parses OSC 133/633 and reports marks over the wire;
/// the daemon just indexes them. Offsets are the client's receive-side count,
/// so they can overshoot the true parse position by up to one frame — they
/// are monotonic and stream-consistent, which is all an index needs.
public struct SessionMark: Sendable {
    public let offset: UInt64
    public let kind: MarkKind
    /// Exit code, on `.commandEnd` marks that carried one.
    public let exit: Int32?
    /// Command line from OSC 633;E, when the shell reports it.
    public let command: String?
    public let at: Date

    public init(offset: UInt64, kind: MarkKind, exit: Int32?, command: String?, at: Date = Date()) {
        self.offset = offset
        self.kind = kind
        self.exit = exit
        self.command = command
        self.at = at
    }
}

/// Bounded FIFO of a session's marks. Owned by `PtySession` and mutated only
/// under its `stateLock`; not internally synchronized.
struct SessionMarkStore {
    private(set) var marks: [SessionMark] = []
    private let cap: Int

    init(cap: Int = KittermConstants.sessionMarkCap) {
        self.cap = cap
    }

    mutating func append(_ mark: SessionMark) {
        marks.append(mark)
        if marks.count > cap {
            // O(cap) on tiny structs at human command rates — fine.
            marks.removeFirst(marks.count - cap)
        }
    }
}
