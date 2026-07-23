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

    public static var recordingsDirectory: URL {
        stateDirectory.appendingPathComponent("recordings", isDirectory: true)
    }

    /// Timestamp of the previous session, for the `Last login:` banner.
    public static var lastLoginFile: URL {
        stateDirectory.appendingPathComponent("lastlogin")
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
