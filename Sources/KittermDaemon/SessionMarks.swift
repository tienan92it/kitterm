import Foundation
import KittermProtocol

/// One shell-integration mark, positioned in the session log by offset.
///
/// Found by `OscMarkScanner` as the bytes arrive, so the index exists whether
/// or not a client is watching. Offsets are exact positions in the log, and
/// they anchor to opposite ends of their own sequence by kind: a `preExec`
/// mark sits just after its sequence, where the command's output begins, and a
/// `commandEnd` mark sits where its sequence starts, where that output ended.
/// A command's output is therefore exactly the bytes between them.
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
    /// How many commands have aged out of the window entirely.
    ///
    /// Command numbers have to stay put for the lifetime of a session: a caller
    /// counts the commands, writes input, and waits on the index it computed,
    /// and `outputUrl` embeds that index in a link it may follow much later. If
    /// numbering restarted at 1 every time the window slid, an index would
    /// silently come to mean a different command — the wait would return
    /// another command's exit code rather than an error. So the store counts
    /// what it drops, and `SessionCommands.pair` numbers from there.
    ///
    /// Counted by `commandEnd`, because that is the mark a finished command
    /// consumes exactly once. Starts are not usable for this: a shell carrying
    /// two integrations emits two of them per command.
    private(set) var droppedCommands = 0
    private let cap: Int

    init(cap: Int = KittermConstants.sessionMarkCap) {
        self.cap = cap
    }

    /// Index the first still-retained command would carry (1-based).
    var firstRetainedIndex: Int { droppedCommands + 1 }

    mutating func append(_ mark: SessionMark) {
        marks.append(mark)
        if marks.count > cap {
            // O(cap) on tiny structs at human command rates — fine.
            let dropCount = marks.count - cap
            for dropped in marks[0..<dropCount] where dropped.kind == .commandEnd {
                droppedCommands += 1
            }
            marks.removeFirst(dropCount)
        }
    }
}
