import Foundation
import NIOCore
import NIOHTTP1

/// Who may talk to the daemon, and with what grade.
///
/// Loopback peers are always trusted with full access (same-user model). With
/// `--lan`, non-loopback peers must present a token — once via `?token=…`,
/// afterwards via the cookie the daemon sets. Three kinds of token exist:
/// the ephemeral control token (full), the ephemeral watch token (watch-only
/// share links), and named persistent tokens from `kitterm token …` whose
/// grade is stored beside their hash.
public struct AccessPolicy: @unchecked Sendable {
    public let lanEnabled: Bool
    /// Ephemeral full-access token for this `--lan` run.
    public let token: String?
    /// Ephemeral watch-only token for this `--lan` run.
    public let watchToken: String?
    /// Named persistent tokens; nil outside LAN mode. Loop-confined cache
    /// (hence `@unchecked Sendable` on the struct).
    let namedTokens: CachedTokenStore?
    /// Public names this daemon answers to (`--trusted-host`), for requests
    /// arriving through a reverse proxy or an overlay network. Lowercased,
    /// port-stripped.
    public let trustedHosts: Set<String>

    public static let loopbackOnly = AccessPolicy(
        lanEnabled: false, token: nil, watchToken: nil, namedTokens: nil, trustedHosts: []
    )

    public static func lan(
        token: String,
        watchToken: String? = nil,
        namedTokens: CachedTokenStore? = nil,
        trustedHosts: Set<String> = []
    ) -> AccessPolicy {
        AccessPolicy(
            lanEnabled: true,
            token: token,
            watchToken: watchToken,
            namedTokens: namedTokens,
            trustedHosts: Self.normalize(trustedHosts)
        )
    }

    /// Loopback-bound, but reachable under public names through a proxy: those
    /// requests are treated as remote and must present a token.
    public static func proxied(
        token: String,
        watchToken: String? = nil,
        namedTokens: CachedTokenStore? = nil,
        trustedHosts: Set<String>
    ) -> AccessPolicy {
        AccessPolicy(
            lanEnabled: false,
            token: token,
            watchToken: watchToken,
            namedTokens: namedTokens,
            trustedHosts: Self.normalize(trustedHosts)
        )
    }

    static func normalize(_ hosts: Set<String>) -> Set<String> {
        Set(hosts.map { stripPort($0).lowercased() })
    }

    public enum Decision: Equatable, Sendable {
        case allow(TokenGrade)
        /// Authorized via `?token=…` — the response should set the auth cookie
        /// to exactly the presented token, so a watch token can never ride a
        /// full-access cookie.
        case allowSettingCookie(TokenGrade, cookie: String)
        case reject(String)
    }

    public static let cookieName = "kitterm_token"

    public func decide(
        remote: SocketAddress?,
        headers: HTTPHeaders,
        uri: String
    ) -> Decision {
        let (host, origin) = LoopbackSecurity.hostAndOrigin(from: headers)
        // A request naming one of our public hosts came in from outside —
        // through a reverse proxy or an overlay network — even when the TCP
        // peer is the local proxy process. It gets no local trust: without
        // this, anyone who reaches the proxy would inherit loopback's
        // unauthenticated full access, and the proxy could not be a boundary.
        let viaTrustedHost = host.map(isTrustedHost) ?? false

        if Self.isLoopback(remote), !viaTrustedHost {
            // Loopback keeps today's Host/Origin rules unless LAN mode is on
            // (then the page may legitimately be served under the LAN IP).
            if !lanEnabled,
               let reason = LoopbackSecurity.rejectionReason(
                   hostHeader: host,
                   originHeader: origin
               ) {
                return .reject(reason)
            }
            return .allow(.full)
        }

        guard lanEnabled || viaTrustedHost else {
            return .reject("loopback only")
        }
        // Same-origin only: a present Origin must match the request Host.
        if let origin, !origin.isEmpty {
            guard let originHost = URL(string: origin)?.host,
                  let hostHeader = host,
                  Self.stripPort(hostHeader) == originHost
            else {
                return .reject("cross-origin")
            }
        }
        if let presented = Self.cookieToken(headers), let grade = grade(of: presented) {
            return .allow(grade)
        }
        if let presented = Self.queryToken(uri), let grade = grade(of: presented) {
            return .allowSettingCookie(grade, cookie: presented)
        }
        return .reject("missing or invalid token")
    }

    /// Does this `Host` header name one of our configured public hosts?
    func isTrustedHost(_ hostHeader: String) -> Bool {
        guard !trustedHosts.isEmpty else { return false }
        return trustedHosts.contains(Self.stripPort(hostHeader).lowercased())
    }

    /// What a presented token is worth: the run's control token, its watch
    /// token, or a named token's stored grade.
    func grade(of presented: String) -> TokenGrade? {
        if let token, presented == token { return .full }
        if let watchToken, presented == watchToken { return .watch }
        return namedTokens?.verify(presented)
    }

    /// `secure` is set for connections that reached us over TLS (directly or
    /// through a proxy that terminated it), so the browser will not send the
    /// cookie back over plaintext.
    public static func setCookieHeaderValue(for token: String, secure: Bool = false) -> String {
        "\(cookieName)=\(token); Path=/; HttpOnly; SameSite=Strict" + (secure ? "; Secure" : "")
    }

    static func isLoopback(_ address: SocketAddress?) -> Bool {
        switch address {
        case .unixDomainSocket:
            return true
        case .v4, .v6:
            guard let ip = address?.ipAddress else { return false }
            return ip == "::1" || ip.hasPrefix("127.") || ip.hasPrefix("::ffff:127.")
        default:
            return false
        }
    }

    static func cookieToken(_ headers: HTTPHeaders) -> String? {
        for header in headers["cookie"] {
            for pair in header.split(separator: ";") {
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\(cookieName)=") {
                    return String(trimmed.dropFirst(cookieName.count + 1))
                }
            }
        }
        return nil
    }

    static func queryToken(_ uri: String) -> String? {
        DaemonServer.queryValue("token", fromRequestURI: uri)
    }

    static func stripPort(_ hostHeader: String) -> String {
        let trimmed = hostHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            if let end = trimmed.firstIndex(of: "]") {
                return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            }
            return trimmed
        }
        if let colon = trimmed.lastIndex(of: ":"),
           trimmed[trimmed.index(after: colon)...].allSatisfy(\.isNumber) {
            return String(trimmed[..<colon])
        }
        return trimmed
    }

    public static func generateToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
