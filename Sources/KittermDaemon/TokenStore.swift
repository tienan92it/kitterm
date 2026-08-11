#if canImport(CryptoKit)
import CryptoKit
#else
// swift-crypto: same API, same SHA256 type, where the framework is absent.
import Crypto
#endif
import Foundation

/// What a presented token is allowed to do.
public enum TokenGrade: String, Sendable, Equatable {
    /// Everything the daemon offers (today's behavior).
    case full
    /// Watch-only: observe sessions and read the API, never type, never take
    /// control, never spawn a shell.
    case watch
}

/// A named, persistent access token. Only the SHA-256 of the token is stored —
/// the plaintext is shown once at creation and cannot be recovered (the
/// Zellij model: revocable, not retrievable).
public struct NamedToken: Sendable, Equatable {
    public let name: String
    /// Hex SHA-256 of the token plaintext.
    public let hash: String
    public let grade: TokenGrade
    public let created: Date

    public init(name: String, hash: String, grade: TokenGrade, created: Date) {
        self.name = name
        self.hash = hash
        self.grade = grade
        self.created = created
    }
}

/// Persistent named tokens in `~/.kitterm/tokens.json`, managed by
/// `kitterm token create|list|revoke` and consulted by `AccessPolicy` on
/// every non-loopback request.
public enum TokenStore {
    public static let maxNameLength = 64
    private static let nameAllowed = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maxNameLength && name.allSatisfy(nameAllowed.contains)
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh token: distinct prefix so it is recognizable in URLs and logs.
    public static func generate(grade: TokenGrade) -> String {
        let hex = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return (grade == .watch ? "ktw_" : "ktk_") + hex
    }

    public static func load(from url: URL = DaemonPaths.tokensFile) -> [NamedToken] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["tokens"] as? [[String: Any]]
        else {
            warn("expected {\"tokens\": [...]} — file ignored")
            return []
        }
        var seen = Set<String>()
        var tokens: [NamedToken] = []
        for entry in entries {
            guard let name = entry["name"] as? String, isValidName(name),
                  let hash = entry["hash"] as? String, hash.count == 64,
                  let grade = (entry["grade"] as? String).flatMap(TokenGrade.init(rawValue:)),
                  seen.insert(name).inserted
            else {
                warn("malformed or duplicate entry — skipped")
                continue
            }
            let created = (entry["created"] as? Double).map(Date.init(timeIntervalSince1970:))
            tokens.append(NamedToken(name: name, hash: hash, grade: grade, created: created ?? .distantPast))
        }
        return tokens
    }

    public static func save(_ tokens: [NamedToken], to url: URL = DaemonPaths.tokensFile) throws {
        let entries: [[String: Any]] = tokens.map { token in
            [
                "name": token.name,
                "hash": token.hash,
                "grade": token.grade.rawValue,
                "created": token.created.timeIntervalSince1970,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["tokens": entries],
            options: [.prettyPrinted, .sortedKeys]
        )
        try DaemonPaths.ensureStateDirectory()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("kitterm: tokens.json: \(message)\n".utf8))
    }
}

/// Request-path view of the token file: verifies a presented token against the
/// stored hashes, reloading only when the file's mtime changes — one `stat`
/// per check, a parse only after `kitterm token create|revoke` touched it, so
/// revocation applies without a daemon restart.
///
/// Loop-confined like `ControlHandoff`: only ever touched from the single
/// event-loop thread (`AccessPolicy.decide` call sites), hence
/// `@unchecked Sendable` with no lock.
public final class CachedTokenStore: @unchecked Sendable {
    private let url: URL
    private var loadedAt: Date?
    private var tokens: [NamedToken] = []

    public init(url: URL = DaemonPaths.tokensFile) {
        self.url = url
    }

    /// The grade of a presented token, or nil if it matches nothing.
    public func verify(_ presented: String) -> TokenGrade? {
        reloadIfChanged()
        guard !tokens.isEmpty else { return nil }
        let hash = TokenStore.hash(presented)
        return tokens.first { $0.hash == hash }?.grade
    }

    private func reloadIfChanged() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
            as? Date
        guard mtime != loadedAt else { return }
        loadedAt = mtime
        tokens = mtime == nil ? [] : TokenStore.load(from: url)
    }
}
