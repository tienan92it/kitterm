import Foundation
import KittermProtocol
import NIOHTTP1

public enum LoopbackSecurity: Sendable {
    /// Returns nil if allowed; otherwise a short reason for rejection.
    public static func rejectionReason(hostHeader: String?, originHeader: String?) -> String? {
        if let hostHeader, !isLoopbackAuthority(hostHeader) {
            return "non-loopback Host"
        }
        if let originHeader, !originHeader.isEmpty, !isLoopbackOrigin(originHeader) {
            return "non-loopback Origin"
        }
        return nil
    }

    public static func isLoopbackAuthority(_ hostHeader: String) -> Bool {
        let trimmed = hostHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Strip port: handle bracketed IPv6 `[::1]:3418` and `127.0.0.1:3418`.
        let host: String
        if trimmed.hasPrefix("[") {
            if let end = trimmed.firstIndex(of: "]") {
                host = String(trimmed[...end])
            } else {
                host = trimmed
            }
        } else if let colon = trimmed.lastIndex(of: ":"),
                  trimmed[trimmed.index(after: colon)...].allSatisfy(\.isNumber) {
            host = String(trimmed[..<colon])
        } else {
            host = trimmed
        }

        return KittermConstants.loopbackHosts.contains(host.lowercased())
            || KittermConstants.loopbackHosts.contains(host)
    }

    public static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host else {
            return false
        }
        let normalized: String
        if host.contains(":"), !host.hasPrefix("[") {
            normalized = "[\(host)]"
        } else {
            normalized = host
        }
        return KittermConstants.loopbackHosts.contains(normalized.lowercased())
            || KittermConstants.loopbackHosts.contains(normalized)
            || KittermConstants.loopbackHosts.contains(host.lowercased())
    }

    public static func hostAndOrigin(from headers: HTTPHeaders) -> (host: String?, origin: String?) {
        (headers["host"].first, headers["origin"].first)
    }
}
