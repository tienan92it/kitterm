import Foundation

/// Where this build was installed, and which version it is.
///
/// The split between *running* and *on disk* is the whole point of this file.
/// `kitterm upgrade` deliberately swaps the installed files under a live daemon
/// without stopping it — stopping it would close every PTY master fd and kill
/// every pane. So between an upgrade and the next daemon start, the version on
/// disk is ahead of the code actually serving. Reporting the on-disk version as
/// the running one would make `kitterm version` and the settings panel lie about
/// which code is answering.
public enum InstallLayout: Sendable {
    /// The install prefix for a binary, or nil for a dev/unknown layout.
    /// Installed layout is always `<prefix>/lib/kitterm/kitterm`.
    public static func prefix(forExecutable path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard
            url.deletingLastPathComponent().lastPathComponent == "kitterm",
            url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "lib"
        else {
            return nil
        }
        return url
            .deletingLastPathComponent()  // lib/kitterm
            .deletingLastPathComponent()  // lib
            .deletingLastPathComponent()  // prefix
    }

    public static func versionFile(inPrefix prefix: URL) -> URL {
        prefix.appendingPathComponent("share/kitterm/VERSION")
    }

    /// The version recorded on disk *right now*. A deferred upgrade moves this
    /// ahead of the running process; callers that mean "the code answering this
    /// request" want `BuildVersion.running` instead.
    public static func versionOnDisk(executablePath: String) -> String? {
        guard let prefix = prefix(forExecutable: executablePath) else {
            return nil
        }
        let file = versionFile(inPrefix: prefix)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The version of the code in this process.
public enum BuildVersion: Sendable {
    /// Read once and frozen. `DaemonServer` forces this during start-up, before
    /// an upgrade can swap the file underneath — a lazy first read after an
    /// upgrade would otherwise pick up the new version while running old code.
    public static let running: String =
        InstallLayout.versionOnDisk(executablePath: CommandLine.arguments[0]) ?? "dev"

    /// What a restart would pick up. Equal to `running` unless a deferred
    /// upgrade has staged a newer build.
    public static func onDisk() -> String {
        InstallLayout.versionOnDisk(executablePath: CommandLine.arguments[0]) ?? running
    }

    public static var updatePending: Bool {
        onDisk() != running
    }
}
