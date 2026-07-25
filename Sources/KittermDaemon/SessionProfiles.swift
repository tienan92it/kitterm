import Foundation

/// A named way to start a session: a connect command run in a fresh login
/// shell ("ssh dev-vm", "docker exec -it agents bash"), optionally with a
/// starting directory. This is how kitterm becomes the control plane for
/// shells that live somewhere else — a VM, a container, another host — while
/// everything semantic (OSC 133 marks, notifications, cwd) still flows
/// in-band through the transport.
///
/// User-authored in `~/.kitterm/profiles.json`:
///
///     { "profiles": [
///       { "name": "vm", "command": "ssh dev-vm", "cwd": "~/Workspace" }
///     ] }
///
/// A URL or WS query only ever carries the profile *name*; the command comes
/// exclusively from this file, so a crafted link can pick a profile but never
/// inject a command.
public struct SessionProfile: Sendable, Equatable {
    public let name: String
    public let command: String
    public let cwd: String?

    public init(name: String, command: String, cwd: String? = nil) {
        self.name = name
        self.command = command
        self.cwd = cwd
    }
}

public enum SessionProfiles {
    public static let maxNameLength = 64
    /// The command is written into the PTY as typed input before the shell's
    /// first read; the kernel caps a canonical-mode input line (MAX_INPUT,
    /// 1024 on Darwin), so stay well under it.
    public static let maxCommandBytes = 512

    private static let nameAllowed = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maxNameLength && name.allSatisfy(nameAllowed.contains)
    }

    /// Single line, bounded, no NUL: the command is replayed as keystrokes, so
    /// an embedded newline would silently run a second command.
    public static func isValidCommand(_ command: String) -> Bool {
        !command.isEmpty
            && command.utf8.count <= maxCommandBytes
            && !command.contains { $0.isNewline || $0 == "\0" }
    }

    /// Parse the profiles file. Missing file → no profiles. A malformed file
    /// or entry is skipped with a stderr warning — a config typo must degrade
    /// to "profile not found", never take the daemon down.
    public static func load(from url: URL = DaemonPaths.profilesFile) -> [SessionProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["profiles"] as? [[String: Any]]
        else {
            warn("expected {\"profiles\": [...]} — file ignored")
            return []
        }

        var seen = Set<String>()
        var profiles: [SessionProfile] = []
        for entry in entries {
            guard let name = entry["name"] as? String,
                  let command = entry["command"] as? String
            else {
                warn("entry missing \"name\" or \"command\" — skipped")
                continue
            }
            guard isValidName(name) else {
                warn("invalid name \"\(name)\" (allowed: letters, digits, . _ -, ≤\(maxNameLength) chars) — skipped")
                continue
            }
            guard isValidCommand(command) else {
                warn("profile \"\(name)\": command must be one non-empty line ≤\(maxCommandBytes) bytes — skipped")
                continue
            }
            guard seen.insert(name).inserted else {
                warn("duplicate profile \"\(name)\" — first one wins")
                continue
            }
            profiles.append(
                SessionProfile(name: name, command: command, cwd: entry["cwd"] as? String)
            )
        }
        return profiles
    }

    public static func find(_ name: String, from url: URL = DaemonPaths.profilesFile) -> SessionProfile? {
        load(from: url).first { $0.name == name }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("kitterm: profiles.json: \(message)\n".utf8))
    }
}
