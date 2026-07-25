import Foundation
import KittermProtocol

/// One command derived from a session's shell-integration marks: its output
/// byte range in the session log, exit code, and (if the shell reported it)
/// command line. The agent-facing answer to "what did command N print, and how
/// did it exit?" — built from marks the client already reports, without the
/// daemon parsing ANSI.
public struct SessionCommand: Sendable {
    /// 1-based position among the commands currently retained.
    public let index: Int
    /// Command line from OSC 633;E, if the shell reported one.
    public let command: String?
    /// Exit code; nil while the command is still running.
    public let exit: Int32?
    /// Absolute session-log offset where the command's output begins (OSC 133;C).
    public let startOffset: UInt64
    /// Offset where output ends (OSC 133;D); nil while running.
    public let endOffset: UInt64?
    public let running: Bool
}

public enum SessionCommands {
    /// Pair each output-start mark (`preExec`, OSC 133;C) with the following
    /// `commandEnd` (D). A start with no end is the currently-running command.
    /// Output is `[startOffset, endOffset)` — the bytes the command printed,
    /// excluding the echoed command line.
    ///
    /// Offsets are the client's receive-side byte count, so a command whose
    /// entire output batches into one WebSocket frame with its start/end marks
    /// collapses to a zero-length range. In practice that is only tiny, instant
    /// commands (`echo`, `ls`); substantial output — the build/test logs an
    /// agent actually wants — spans multiple frames and pairs precisely.
    public static func pair(from marks: [SessionMark]) -> [SessionCommand] {
        var commands: [SessionCommand] = []
        var pending: (offset: UInt64, command: String?)?

        func flushRunning() {
            guard let start = pending else { return }
            commands.append(
                SessionCommand(
                    index: commands.count + 1,
                    command: start.command,
                    exit: nil,
                    startOffset: start.offset,
                    endOffset: nil,
                    running: true
                )
            )
            pending = nil
        }

        for mark in marks {
            switch mark.kind {
            case .preExec:
                // Two starts with no end between them shouldn't happen, but if
                // they do, close the first as running rather than lose it.
                flushRunning()
                pending = (mark.offset, mark.command)
            case .commandEnd:
                guard let start = pending else { break } // end with no start: skip
                commands.append(
                    SessionCommand(
                        index: commands.count + 1,
                        command: start.command,
                        exit: mark.exit,
                        startOffset: start.offset,
                        endOffset: mark.offset,
                        running: false
                    )
                )
                pending = nil
            case .promptStart, .commandStart:
                break
            }
        }
        // A trailing start is the command running right now.
        flushRunning()
        return commands
    }
}
