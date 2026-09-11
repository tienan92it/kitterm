import Foundation
import KittermProtocol

public enum DaemonPaths: Sendable {
    /// Whether the state directory has been moved.
    ///
    /// Also the signal that the daemon being managed is *not* the installed
    /// one, which matters beyond where files land: the launchd job has a fixed
    /// label, so booting it out from a scratch daemon's `stop` would kill
    /// whatever the user was actually working in.
    public static var isStateDirectoryOverridden: Bool {
        guard let override = ProcessInfo.processInfo.environment["KITTERM_STATE_DIR"] else {
            return false
        }
        return !override.isEmpty
    }

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
        if isStateDirectoryOverridden,
           let override = ProcessInfo.processInfo.environment["KITTERM_STATE_DIR"] {
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

    /// Registered projects (`kitterm project add|list|remove`), read by the
    /// daemon to resolve each session's project (`ProjectStore`).
    public static var projectsFile: URL {
        stateDirectory.appendingPathComponent("projects.json")
    }

    /// Retained session output (`--retain-logs`), one file per session.
    public static var logsDirectory: URL {
        stateDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// Per-pane shell history files, keyed by the client's durable pane key.
    public static var historyDirectory: URL {
        stateDirectory.appendingPathComponent("history", isDirectory: true)
    }

    /// Archived sessions: the evidence of a finished session, kept after its
    /// shell is gone. One directory per archived session id.
    public static var archiveDirectory: URL {
        stateDirectory.appendingPathComponent("archive", isDirectory: true)
    }

    /// Names and labels of live sessions, so a pane respawned after a daemon
    /// restart keeps them (`RespawnHintStore`).
    public static var respawnHintsFile: URL {
        stateDirectory.appendingPathComponent("respawn.json")
    }

    /// How the last run of the daemon ended, or nothing where its ending
    /// should be when the kernel killed it (`LastRun`). Written by the run it
    /// describes; read by the next one.
    public static var lastRunFile: URL {
        stateDirectory.appendingPathComponent("last-run.json")
    }

    /// Web Push subscriptions (`PushSubscriptionStore`): one entry per
    /// browser endpoint, `0600`, reloaded by every run because the browser's
    /// subscription outlives a restart and a live upgrade.
    public static var pushSubscriptionsFile: URL {
        stateDirectory.appendingPathComponent("push.json")
    }

    /// The daemon's VAPID key pair (`VAPIDKeys`), `0600`, in its own file
    /// because it is a daemon secret and `push.json` holds only what the
    /// browser handed the page. Generated once; every phone's subscription
    /// is bound to its public half.
    public static var vapidKeyFile: URL {
        stateDirectory.appendingPathComponent("vapid.json")
    }

    /// Where a daemon writes its state for the process that replaces it in
    /// place (`POST /api/upgrade/takeover`, `serve --takeover`). Deleted by
    /// the successor once it has adopted everything.
    public static var takeoverDirectory: URL {
        stateDirectory.appendingPathComponent("takeover", isDirectory: true)
    }

    /// The web bundle the running daemon pinned at start-up. Written for the
    /// installer, which stages each release's bundle in its own directory and
    /// must not delete the one a live daemon is still serving.
    public static var webRootFile: URL {
        stateDirectory.appendingPathComponent("web-root")
    }

    /// Creates the state directory owner-only. It holds tokens and shell
    /// output, so a directory the umask left world-readable would let
    /// another local user list what is there. An existing directory keeps
    /// its mode.
    public static func ensureStateDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
