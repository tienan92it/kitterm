import Foundation

/// What a coding agent last reported about itself through a Claude Code hook.
/// Timestamped evidence, not a state machine: the daemon records what the hook
/// said and when, and `MergedSessionState` weighs it against the shell marks
/// at read time. A session with no hooks records nothing and keeps exactly the
/// mark-only behaviour.
///
/// Stored on the `PtySession` itself (beside `name` and `lastOutputAt`), so
/// its lifetime is the session's: reaped with it, never evicted from a shared
/// table while the session is still alive.
public enum AgentReport: String, Sendable {
    /// A `PreToolUse` event — the agent is doing something. This is the edge
    /// that clears a stale `needs-input` once the human has answered and the
    /// agent runs its next tool.
    case working
    /// A `Notification` event — the agent wants the human (a permission
    /// prompt, or "waiting for your input").
    case needsInput = "needs-input"
    /// A `Stop` event — the agent finished its turn.
    case completed
}

public struct AgentStatus: Sendable, Equatable {
    public let report: AgentReport
    /// The `message` the hook carried, if any (the text a human reads).
    public let message: String?
    public let at: Date

    public init(report: AgentReport, message: String?, at: Date = Date()) {
        self.report = report
        self.message = message
        self.at = at
    }
}
