import Foundation
import KittermProtocol

/// State derived from a session's shell-integration marks — the answer to
/// "is this shell working, idle, or waiting?" without the daemon parsing ANSI.
/// It is only as good as the marks the shell emits; a shell with no OSC 133
/// integration reports `.unknown`.
public enum SessionState: String, Sendable {
    /// A command is running (a preExec with no commandEnd after it).
    case running
    /// At a prompt, nothing running.
    case idle
    /// No marks yet — either a brand-new shell or one without integration.
    case unknown
}

public struct DerivedSessionState: Sendable {
    public let state: SessionState
    /// The most recent command line the shell reported (OSC 633;E), if any.
    public let lastCommand: String?
    /// The exit code of the most recently finished command, if any.
    public let lastExit: Int32?

    public static func derive(from marks: [SessionMark]) -> DerivedSessionState {
        guard !marks.isEmpty else {
            return DerivedSessionState(state: .unknown, lastCommand: nil, lastExit: nil)
        }

        var lastPreExecIndex: Int?
        var lastCommandEndIndex: Int?
        var lastCommand: String?
        var lastExit: Int32?

        for (index, mark) in marks.enumerated() {
            switch mark.kind {
            case .preExec:
                lastPreExecIndex = index
                if let command = mark.command { lastCommand = command }
            case .commandEnd:
                lastCommandEndIndex = index
                lastExit = mark.exit
            case .promptStart, .commandStart:
                break
            }
        }

        // A command is running when the newest preExec is more recent than the
        // newest commandEnd (or no command has finished yet).
        let running: Bool
        if let pre = lastPreExecIndex {
            running = (lastCommandEndIndex ?? -1) < pre
        } else {
            running = false
        }

        return DerivedSessionState(
            state: running ? .running : .idle,
            lastCommand: lastCommand,
            lastExit: lastExit
        )
    }
}
