import Foundation

/// Shared defaults and flow-control thresholds for kitterm.
/// Numbers inspired by localterm behavior; reimplemented independently.
public enum KittermConstants: Sendable {
    public static let defaultPort: Int = 3418
    public static let defaultHost: String = "127.0.0.1"
    public static let defaultCols: UInt16 = 120
    public static let defaultRows: UInt16 = 32
    public static let defaultShellFallback: String = "/bin/sh"

    public static let termType: String = "xterm-256color"
    public static let colortermValue: String = "truecolor"

    /// macOS `ls` color defaults when the parent environment does not set them.
    public static let clicolorDefault: String = "1"
    public static let lscolorsDefault: String = "exfxcxdxbxegedabagacad"

    public static let maxInputBytes: Int = 64 * 1024
    public static let maxOutputBytes: Int = 1 * 1024 * 1024
    public static let maxTitleLength: Int = 4 * 1024
    public static let maxCols: UInt16 = 1000
    public static let maxRows: UInt16 = 1000
    public static let maxConcurrentSessions: Int = 64

    public static let outputBatchWindowMs: Int = 2
    public static let outputBatchMaxBytes: Int = 64 * 1024

    public static let wsOutboundPauseHighWaterBytes: Int = 4 * 1024 * 1024
    public static let wsOutboundResumeLowWaterBytes: Int = 1 * 1024 * 1024
    public static let wsOutboundDrainPollMs: Int = 50
    public static let wsBackpressureThresholdBytes: Int = 64 * 1024 * 1024

    public static let wsHeartbeatIntervalMs: Int = 20_000
    public static let wsHeartbeatTimeoutMs: Int = 60_000

    /// Detached sessions (transient disconnect: sleep/wake, network blip) are
    /// kept alive this long awaiting reattach, then reaped. Uses a suspending
    /// clock so machine sleep does not consume the window.
    public static let sessionDetachLingerSeconds: Int = 300
    /// Per-session ring of recent output with absolute stream offsets; serves
    /// reattach gap-replay, observer catch-up, and tail replay. Sized to
    /// rebuild a full 10k-line client scrollback with escape overhead.
    public static let sessionLogBytes: Int = 4 * 1024 * 1024
    /// Rolling tail of recent output replayed to newly joining observers.
    public static let sessionObserverReplayMaxBytes: Int = 128 * 1024
    /// Longest OSC 633;E command line carried in a mark frame.
    public static let maxMarkCommandBytes: Int = 2048
    /// Cap on a single command-output response (`/api/.../commands/<n>/output`);
    /// larger output returns its tail so a flood can't serialize megabytes on
    /// the event loop.
    public static let apiCommandOutputMaxBytes: Int = 256 * 1024
    /// Shell-integration marks kept per session (FIFO beyond the cap).
    public static let sessionMarkCap: Int = 1000

    public static let serverStopGraceMs: Int = 1_500

    public static let stateDirectoryName: String = ".kitterm"
    public static let pidFileName: String = "pid"
    public static let portFileName: String = "port"
    public static let logFileName: String = "server.log"

    /// Env vars stripped from the PTY child so TUIs don't probe a foreign terminal identity.
    public static let ptyEnvDenylist: Set<String> = [
        "KITTERM_DAEMON_CHILD",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "TERM_SESSION_ID",
        "ITERM_SESSION_ID",
        "ITERM_PROFILE",
        "KITTY_WINDOW_ID",
        "KITTY_PID",
        "WT_SESSION",
        "WT_PROFILE_ID",
        "GHOSTTY_RESOURCES_DIR",
        "GHOSTTY_BIN_DIR",
        "VSCODE_INJECTION",
        "VSCODE_GIT_IPC_HANDLE",
        "LOCALTERM_DAEMON_CHILD",
    ]

    /// Ceiling on one session's retained output on disk (`--retain-logs`).
    public static let retainedLogBytes = 64 * 1024 * 1024

    /// Long-poll window for `…/commands/<n>/wait` when the caller names none,
    /// and the ceiling it may ask for.
    public static let commandWaitDefaultSeconds = 30
    public static let commandWaitMaxSeconds = 300

    /// Detach window for sessions a program created (they carry labels). An
    /// orchestrator restart must not cost you your in-flight nodes.
    public static let orchestratedSessionLingerSeconds = 3600
    /// Ceiling for `--session-linger`; a day of holding an unattached shell is
    /// already generous.
    public static let maxSessionLingerSeconds = 86_400

    /// Largest file that can be dropped into a session. Sized for what a coding
    /// agent is actually given as context — screenshots, logs, CSVs, a PDF —
    /// not media. The body is buffered before it is written, so this is also
    /// the memory one upload can cost.
    public static let maxDropBytes: Int = 16 * 1024 * 1024
    /// Files one session may hold, so a drop target cannot fill a disk.
    public static let maxDropsPerSession: Int = 100
    public static let maxDropNameLength: Int = 120
    /// Entries returned for one directory. Node_modules should not be able to
    /// turn a listing into a megabyte of JSON.
    public static let maxDirectoryEntries: Int = 1000

    public static let loopbackHosts: Set<String> = [
        "127.0.0.1",
        "localhost",
        "kitterm.localhost",
        "::1",
        "[::1]",
        "0:0:0:0:0:0:0:1",
        "[0:0:0:0:0:0:0:1]",
    ]
}
