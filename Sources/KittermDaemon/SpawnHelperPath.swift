import Foundation

enum SpawnHelperPath {
    /// Resolve `kitterm-spawn-helper` next to the running `kitterm` binary (or PATH).
    static func resolve() throws -> String {
        let name = "kitterm-spawn-helper"
        let fm = FileManager.default

        let arg0 = CommandLine.arguments[0]
        let execURL: URL
        if arg0.hasPrefix("/") {
            execURL = URL(fileURLWithPath: arg0)
        } else if arg0.contains("/") {
            execURL = URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent(arg0)
                .standardizedFileURL
        } else if let found = findOnPath(name: arg0) {
            execURL = URL(fileURLWithPath: found)
        } else {
            execURL = URL(fileURLWithPath: arg0)
        }

        let sibling = execURL.deletingLastPathComponent().appendingPathComponent(name).path
        if fm.isExecutableFile(atPath: sibling) {
            return sibling
        }

        if let onPath = findOnPath(name: name) {
            return onPath
        }

        throw PtyError.forkFailed(errno: ENOENT)
    }

    private static func findOnPath(name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
