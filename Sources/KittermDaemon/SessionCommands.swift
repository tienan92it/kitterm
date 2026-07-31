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
    ///
    /// `firstIndex` (from `SessionMarkStore.firstRetainedIndex`) is the number
    /// the oldest retained command carries, so numbering survives the window
    /// sliding instead of re-pointing a caller's saved index.
    public static func pair(
        from marks: [SessionMark],
        firstIndex: Int = 1
    ) -> [SessionCommand] {
        var commands: [SessionCommand] = []
        var pending: (offset: UInt64, command: String?, at: Date)?
        var nextIndex = firstIndex
        var sawStart = false

        func take() -> Int {
            defer { nextIndex += 1 }
            return nextIndex
        }

        func flushRunning() {
            guard let start = pending else { return }
            commands.append(
                SessionCommand(
                    index: take(),
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
                sawStart = true
                // Two starts with no end between them: different names mean two
                // real commands, so close the first as running. Matching (or
                // absent) names mean one command announced twice by a shell
                // carrying two integrations — collapse it, because a phantom
                // command stays "running" forever and nothing can close it.
                if let previous = pending,
                   let existing = previous.command,
                   let incoming = mark.command,
                   existing != incoming {
                    flushRunning()
                    pending = (mark.offset, mark.command, mark.at)
                } else if let previous = pending {
                    // Same command: take the later start, where the output we
                    // see actually begins, and keep whichever carried the text.
                    pending = (mark.offset, previous.command ?? mark.command, mark.at)
                } else {
                    pending = (mark.offset, mark.command, mark.at)
                }
            case .commandEnd:
                guard let start = pending else {
                    // An end with no start, before any start in this window,
                    // and only once something has aged out: that command's
                    // start was evicted, so it still owns its number. A shell
                    // also emits one of these at its first prompt, and that one
                    // must not consume a number — the first real command has to
                    // be index 1.
                    if !sawStart, firstIndex > 1 { _ = take() }
                    break
                }
                commands.append(
                    SessionCommand(
                        index: take(),
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
