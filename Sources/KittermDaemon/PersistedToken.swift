import Foundation
import KittermProtocol

/// The daemon's LAN and watch tokens, kept across restarts.
///
/// These used to be minted fresh on every start, which quietly revoked every
/// share link the moment the daemon came back — including for a routine
/// `kitterm restart` or an upgrade. That is the wrong default for a tool whose
/// point is reaching a machine you are not sitting at: the restart happens, and
/// the link in your phone stops working while you are away from the Mac that
/// could print you a new one.
///
/// So a token is generated once and then reused, and rotating is something you
/// ask for. A file is only trusted if it looks like a token this daemon wrote
/// and only its owner can read it — anything else is replaced rather than
/// squinted at, because a token is a credential and a damaged one should fail
/// closed rather than persist.
enum PersistedToken {
    /// Tokens are hex, optionally behind a grade prefix (`ktw_`).
    static func looksLikeToken(_ value: String) -> Bool {
        let body = value.hasPrefix("ktw_") || value.hasPrefix("ktk_")
            ? String(value.dropFirst(4))
            : value
        guard body.count >= 32, body.count <= 128 else { return false }
        return body.allSatisfy { $0.isHexDigit }
    }

    /// Whether the file is readable by its owner alone. A token that the rest
    /// of the machine can read is not one worth keeping.
    static func isOwnerOnly(_ url: URL) -> Bool {
        guard let perms = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        else {
            return false
        }
        return perms.int16Value & 0o077 == 0
    }

    /// The token stored at `url`, or nil if there isn't a usable one.
    static func read(from url: URL) -> String? {
        guard isOwnerOnly(url),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return looksLikeToken(value) ? value : nil
    }

    /// Write a token, owner-readable only.
    static func write(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// The token to serve with: the stored one when it is usable, otherwise a
    /// fresh one, written back. `rotate` forces a new one regardless.
    @discardableResult
    static func loadOrCreate(
        at url: URL,
        rotate: Bool = false,
        generate: () -> String
    ) throws -> String {
        if !rotate, let existing = read(from: url) {
            // Re-assert the mode: a file that became group-readable since it
            // was written would have been rejected above, but this also
            // repairs one whose mode drifted while still being owner-only.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return existing
        }
        let fresh = generate()
        try write(fresh, to: url)
        return fresh
    }
}
