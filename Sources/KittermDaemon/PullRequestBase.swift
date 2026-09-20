import Foundation
import NIOConcurrencyHelpers

/// Where a project's pull requests live, read off its `origin` remote
/// (`agent-dashboard` round 15). `GET /api/projects` carries the result as
/// `pullRequestBase`, `https://github.com/owner/repo/pull/`, so the fleet
/// view makes `PR #124` a link. A remote that is not on GitHub, or no
/// remote, yields nothing, and the page prints the number as plain text.
public enum PullRequestBase {
    /// The base for a GitHub remote URL in any form `git remote get-url`
    /// prints — `git@github.com:owner/repo.git`,
    /// `ssh://git@github.com/owner/repo.git`, `https://github.com/owner/repo`
    /// with or without `.git` — else nil.
    public static func parse(remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = trimmed.range(of: "github.com") else { return nil }
        // What precedes the host is a scheme or a user, `https://`,
        // `ssh://git@`, `git@`; what follows is `:` or `/` then the path.
        let before = trimmed[..<host.lowerBound]
        guard before.isEmpty || before.hasSuffix("@") || before.hasSuffix("://") else { return nil }
        let after = trimmed[host.upperBound...]
        guard let separator = after.first, separator == ":" || separator == "/" else { return nil }
        var path = after.dropFirst()
        if path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isNameCharacter) }) else { return nil }
        return "https://github.com/\(parts[0])/\(parts[1])/pull/"
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".")
    }
}

/// The `origin` remote of each project root, asked of `git` on `queue` and
/// kept `ttlSeconds` per root, so `GET /api/projects`, polled every two
/// seconds, runs one `git remote get-url origin` per project every five
/// minutes and never on the event loop.
public final class RemoteOrigins: @unchecked Sendable {
    public static let ttlSeconds: TimeInterval = 300
    static let queue = DispatchQueue(label: "kitterm.remotes", qos: .utility)

    private let git: RepositoryYield.Git
    private let lock = NIOLock()
    private var cache: [String: (at: Date, base: String?)] = [:]

    public init(git: @escaping RepositoryYield.Git = { RepositoryYield.run(args: $0) }) {
        self.git = git
    }

    /// The pull request base of `root`, or nil: no checkout, no `origin`,
    /// or a remote that is not on GitHub. Synchronous; the route calls it
    /// on `queue`. A miss is cached like a hit, so a plain directory costs
    /// one `git` per interval too.
    public func pullRequestBase(root: String, now: Date = Date()) -> String? {
        if let kept = lock.withLock({ cache[root] }), now.timeIntervalSince(kept.at) < Self.ttlSeconds {
            return kept.base
        }
        var base: String?
        if let result = git(["-C", root, "remote", "get-url", "origin"]), result.status == 0 {
            base = PullRequestBase.parse(remote: result.output)
        }
        lock.withLock { cache[root] = (now, base) }
        return base
    }

    /// The base per root for every `roots`, on the caller's thread.
    public func pullRequestBases(roots: [String], now: Date = Date()) -> [String: String] {
        var bases: [String: String] = [:]
        for root in Set(roots) {
            if let base = pullRequestBase(root: root, now: now) { bases[root] = base }
        }
        return bases
    }
}
