import Foundation
import KittermProtocol

public enum DaemonPaths: Sendable {
    /// Where the pid, port, token and web-root markers live.
    ///
    /// `KITTERM_STATE_DIR` moves the whole set. Without it there is no way to
    /// run a second daemon without stepping on the first: the home directory
    /// comes from the passwd entry, so overriding `HOME` does not redirect it,
    /// and a throwaway daemon silently rewrites the pid and port of the one you
    /// are working in — after which `kitterm stop` targets the wrong process.
    ///
    /// A relative path resolves against the current directory, which is what a
    /// test harness usually wants.
    public static var stateDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KITTERM_STATE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
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

    /// Files dropped into a session from the browser, one directory each.
    public static var dropsDirectory: URL {
        stateDirectory.appendingPathComponent("drops", isDirectory: true)
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

    /// The web bundle the running daemon pinned at start-up. Written for the
    /// installer, which stages each release's bundle in its own directory and
    /// must not delete the one a live daemon is still serving.
    public static var webRootFile: URL {
        stateDirectory.appendingPathComponent("web-root")
    }

    public static func ensureStateDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
    }
}
