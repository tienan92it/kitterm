import Foundation
import KittermProtocol

/// One command derived from a session's shell-integration marks: its output
/// byte range in the session log, exit code, timings, and (if the shell
/// reported it) command line. The agent-facing answer to "what did command N
/// print, and how did it exit?".
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
    /// When the command started producing output, and when it finished. Present
    /// so a caller can put a real duration on a span it owns without kitterm
    /// emitting traces of its own.
    public let startedAt: Date
    public let endedAt: Date?

    public var durationMs: Int? {
        guard let endedAt else { return nil }
        return Int(endedAt.timeIntervalSince(startedAt) * 1000)
    }
}

public enum SessionCommands {
    /// Pair each output-start mark (`preExec`, OSC 133;C) with the following
    /// `commandEnd` (D). A start with no end is the currently-running command.
    /// Output is `[startOffset, endOffset)` — the bytes the command printed,
    /// excluding the echoed command line.
    ///
    /// Offsets come from `OscMarkScanner`, which reads the marks straight out
    /// of the stream, so they are exact byte positions rather than a client's
    /// frame-granular count — a one-line `echo` pairs as precisely as a build
    /// log does.
    public static func pair(from marks: [SessionMark]) -> [SessionCommand] {
        var commands: [SessionCommand] = []
        var pending: (offset: UInt64, command: String?, at: Date)?

        func flushRunning() {
            guard let start = pending else { return }
            commands.append(
                SessionCommand(
                    index: commands.count + 1,
                    command: start.command,
                    exit: nil,
                    startOffset: start.offset,
                    endOffset: nil,
                    running: true,
                    startedAt: start.at,
                    endedAt: nil
                )
            )
            pending = nil
        }

        for mark in marks {
            switch mark.kind {
            case .preExec:
                // Two starts with no end between them have two very different
                // causes, and they need opposite handling.
                //
                // If both name a command and the names differ, they really are
                // two commands and the first never reported an end: close it as
                // running rather than lose it.
                //
                // If they agree — or one is silent — it is one command
                // announced twice, which happens whenever a shell carries two
                // integrations (its own plus kitterm's snippet). Collapsing
                // those matters because a phantom command is permanently
                // "running": anything waiting on that index would wait forever,
                // and an index nothing can close is worse than no index.
                if let previous = pending,
                   let existing = previous.command,
                   let incoming = mark.command,
                   existing != incoming {
                    flushRunning()
                    pending = (mark.offset, mark.command, mark.at)
                } else if let previous = pending {
                    // Same command, seen again: take the later start (the
                    // output we will actually see begins there) and keep
                    // whichever announcement carried the text.
                    pending = (mark.offset, previous.command ?? mark.command, mark.at)
                } else {
                    pending = (mark.offset, mark.command, mark.at)
                }
            case .commandEnd:
                guard let start = pending else { break } // end with no start: skip
                commands.append(
                    SessionCommand(
                        index: commands.count + 1,
                        command: start.command,
                        exit: mark.exit,
                        startOffset: start.offset,
                        endOffset: mark.offset,
                        running: false,
                        startedAt: start.at,
                        endedAt: mark.at
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
