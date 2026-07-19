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

    public static func ensureStateDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
    }
}
