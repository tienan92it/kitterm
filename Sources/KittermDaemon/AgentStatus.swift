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

/// The join between a kitterm session and the Claude Code session that ran in
/// it: the `session_id` and `transcript_path` every hook payload carries.
/// Kept so a later reader can open the transcript's `cost-state` line and
/// bill the session; the daemon itself never opens the transcript.
///
/// Recorded from every hook, whichever arrives first (`PreToolUse` or
/// `Notification` in practice), and the latest wins: a session that runs
/// `claude` twice names the second run. `transcriptPath` is kept as the hook
/// gave it — absolute, under `~/.claude/projects/` — because the archive's
/// `cwd` and `shell` are already absolute paths on this machine, and a reader
/// opens it without expanding anything. It is a path, not the file: the
/// transcript can be deleted after the fact, and nothing here copies it.
public struct AgentJoin: Sendable, Equatable {
    /// Claude Code's own session id (the transcript's file name, and the
    /// `sessionId` on every line inside it).
    public let sessionID: String
    /// Where Claude Code writes that session's transcript, as given.
    public let transcriptPath: String

    public init(sessionID: String, transcriptPath: String) {
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
    }

    /// Bounds on what a hook may hand over. A payload is already capped as a
    /// whole; these keep one field from being most of it.
    public static let maxSessionIDLength = 128
    public static let maxTranscriptPathLength = 4096

    /// The join a hook payload carries, or nil when either field is missing,
    /// empty, or over its bound. Both fields or neither: a session id with
    /// no path cannot be billed and a path with no id cannot be named.
    public static func parse(_ event: [String: Any]?) -> AgentJoin? {
        guard let sessionID = event?["session_id"] as? String,
              let path = event?["transcript_path"] as? String,
              !sessionID.isEmpty, sessionID.count <= maxSessionIDLength,
              !path.isEmpty, path.count <= maxTranscriptPathLength
        else { return nil }
        return AgentJoin(sessionID: sessionID, transcriptPath: path)
    }
}
