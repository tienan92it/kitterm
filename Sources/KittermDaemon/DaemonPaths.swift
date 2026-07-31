import Foundation
import KittermProtocol

public enum DaemonPaths: Sendable {
    public static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(KittermConstants.stateDirectoryName, isDirectory: true)
    }

    public static var pidFile: URL {
        stateDirectory.appendingPathComponent(KittermConstants.pidFileName)
    }

    public static var portFile: URL {
        stateDirectory.appendingPathComponent(KittermConstants.portFileName)
    }

    public static var logFile: URL {
        stateDirectory.appendingPathComponent(KittermConstants.logFileName)
    }

    public static var tokenFile: URL {
        stateDirectory.appendingPathComponent("token")
    }

    /// Ephemeral watch-only token for the current `--lan` run.
    public static var watchTokenFile: URL {
        stateDirectory.appendingPathComponent("token-watch")
    }

    /// Named persistent tokens (`kitterm token …`), hashes only.
    public static var tokensFile: URL {
        stateDirectory.appendingPathComponent("tokens.json")
    }

    public static var recordingsDirectory: URL {
        stateDirectory.appendingPathComponent("recordings", isDirectory: true)
    }

    /// Timestamp of the previous session, for the `Last login:` banner.
    public static var lastLoginFile: URL {
        stateDirectory.appendingPathComponent("lastlogin")
    }

    /// User-authored session profiles (named connect commands).
    public static var profilesFile: URL {
        stateDirectory.appendingPathComponent("profiles.json")
    }

    /// Retained session output (`--retain-logs`), one file per session.
    public static var logsDirectory: URL {
        stateDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// Per-pane shell history files, keyed by the client's durable pane key.
    public static var historyDirectory: URL {
        stateDirectory.appendingPathComponent("history", isDirectory: true)
    }

    public static func ensureStateDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
    }
}
