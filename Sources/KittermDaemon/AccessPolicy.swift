import Foundation
import NIOCore
import NIOHTTP1

/// Who may talk to the daemon.
///
/// Loopback peers are always trusted (same-user model, as today). With
/// `--lan`, non-loopback peers must present the start-time token — once via
/// `?token=…`, afterwards via the cookie the daemon sets.
public struct AccessPolicy: Sendable {
    public let lanEnabled: Bool
    public let token: String?

    public static let loopbackOnly = AccessPolicy(lanEnabled: false, token: nil)

    public static func lan(token: String) -> AccessPolicy {
        AccessPolicy(lanEnabled: true, token: token)
    }

    public enum Decision: Equatable, Sendable {
        case allow
        /// Authorized via `?token=…` — the response should set the auth cookie.
        case allowSettingCookie
        case reject(String)
    }

    public static let cookieName = "kitterm_token"

    public func decide(
        remote: SocketAddress?,
        headers: HTTPHeaders,
        uri: String
    ) -> Decision {
        let (host, origin) = LoopbackSecurity.hostAndOrigin(from: headers)

        if Self.isLoopback(remote) {
            // Loopback keeps today's Host/Origin rules unless LAN mode is on
            // (then the page may legitimately be served under the LAN IP).
            if !lanEnabled,
               let reason = LoopbackSecurity.rejectionReason(
                   hostHeader: host,
                   originHeader: origin
               ) {
                return .reject(reason)
            }
            return .allow
        }

        guard lanEnabled, let token else {
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
        if Self.cookieToken(headers) == token {
            return .allow
        }
        if Self.queryToken(uri) == token {
            return .allowSettingCookie
        }
        return .reject("missing or invalid token")
    }

    public var setCookieHeaderValue: String? {
        guard let token else { return nil }
        return "\(Self.cookieName)=\(token); Path=/; HttpOnly; SameSite=Strict"
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
