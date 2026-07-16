import Foundation
import KittermProtocol

/// Reads the running daemon port from `~/.kitterm/port`.
enum DaemonPort {
    static func current(fallback: Int = KittermConstants.defaultPort) -> Int {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(KittermConstants.stateDirectoryName, isDirectory: true)
            .appendingPathComponent(KittermConstants.portFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0, port <= 65_535
        else {
            return fallback
        }
        return port
    }

    static func webSocketURL(port: Int? = nil) -> URL {
        let resolved = port ?? current()
        return URL(string: "ws://\(KittermConstants.defaultHost):\(resolved)/ws")!
    }
}
