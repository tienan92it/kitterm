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
