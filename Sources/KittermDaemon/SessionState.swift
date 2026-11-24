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
    /// When the newest state-bearing mark (a preExec or commandEnd) arrived,
    /// so a hook report can be weighed against it by age.
    public let lastMarkAt: Date?

    public init(state: SessionState, lastCommand: String?, lastExit: Int32?, lastMarkAt: Date? = nil) {
        self.state = state
        self.lastCommand = lastCommand
        self.lastExit = lastExit
        self.lastMarkAt = lastMarkAt
    }

    public static func derive(from marks: [SessionMark]) -> DerivedSessionState {
        guard !marks.isEmpty else {
            return DerivedSessionState(state: .unknown, lastCommand: nil, lastExit: nil)
        }

        var lastPreExecIndex: Int?
        var lastCommandEndIndex: Int?
        var lastCommand: String?
        var lastExit: Int32?
        var lastMarkAt: Date?

        for (index, mark) in marks.enumerated() {
            switch mark.kind {
            case .preExec:
                lastPreExecIndex = index
                lastMarkAt = mark.at
                if let command = mark.command { lastCommand = command }
            case .commandEnd:
                lastCommandEndIndex = index
                lastMarkAt = mark.at
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
            lastExit: lastExit,
            lastMarkAt: lastMarkAt
        )
    }
}

/// The crew vocabulary: what a foreman and a human both read at a glance.
///
/// Hook reports (`AgentStatus`) and a pending approval are timestamped
/// evidence, merged with the mark-derived state here at read time — never a
/// state machine the daemon advances. A session with no Claude Code hooks
/// records neither, so it collapses to exactly the mark-only `working`/`idle`/
/// `unknown` it always had.
public enum MergedSessionState: String, Sendable {
    case working
    case needsApproval = "needs-approval"
    case needsInput = "needs-input"
    case completed
    case failed
    case idle
    case exited
    case unknown

    /// Two hard facts come first: a dead shell is `exited` whatever it last
    /// said, and a blocked tool call is `needs-approval`. After that, **the
    /// newer of the two evidence sources wins** — the latest hook report or the
    /// latest state-bearing mark. That is what makes the primary case work: a
    /// crew shell running `claude` emits one preExec at the start and no
    /// commandEnd until claude exits, so its marks say "running" for hours;
    /// every hook report is newer, so `working` / `needs-input` / `completed`
    /// track the agent's actual turns. A human typing a command into the pane
    /// after a stale notification produces newer marks, which then win — a
    /// later exit code outranks an older `completed`. No hooks at all means
    /// marks alone, exactly as before.
    public static func merge(
        derived: DerivedSessionState,
        agent: AgentStatus?,
        pendingApproval: Bool,
        exited: Bool
    ) -> MergedSessionState {
        if exited { return .exited }
        if pendingApproval { return .needsApproval }
        if let agent, derived.lastMarkAt.map({ agent.at >= $0 }) ?? true {
            switch agent.report {
            case .needsInput: return .needsInput
            case .working: return .working
            case .completed: return .completed
            }
        }
        if derived.state == .running { return .working }
        if let exit = derived.lastExit, exit != 0 { return .failed }
        if derived.state == .idle { return .idle }
        return .unknown
    }
}
