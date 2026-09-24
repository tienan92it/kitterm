import Foundation
import NIOConcurrencyHelpers

/// One log line per public name a loopback peer used under `--lan` that no
/// `--trusted-host` matched.
///
/// A misspelt `--trusted-host` (`mac.tailnet.ts.nett`) is accepted, and the
/// request the proxy forwards with the real name then gets full access with
/// no token, exactly as if the flag were absent. The daemon has no source of
/// truth for its own public name, so it cannot refuse the flag; what it can
/// do is stop the failure from being silent. The first request per name
/// writes one line to `server.log`; a repeat is not logged, and past
/// `maxNames` distinct names nothing more is, so a scan cannot fill the log.
final class UnmatchedHostLog: @unchecked Sendable {
    static let maxNames = 32

    private let trustedHosts: [String]
    private let sink: @Sendable (String) -> Void
    private let lock = NIOLock()
    private var seen: Set<String> = []

    init(
        trustedHosts: Set<String>,
        sink: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        self.trustedHosts = trustedHosts.sorted()
        self.sink = sink
    }

    /// The line for `host`, or nil when it was already reported or the cap
    /// is reached. Pure but for the seen set, so a test reads the words.
    func line(for host: String) -> String? {
        let name = AccessPolicy.stripPort(host).lowercased()
        let first: Bool = lock.withLock {
            guard seen.count < Self.maxNames, !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
        guard first else { return nil }
        let trusted = trustedHosts.isEmpty ? "none" : trustedHosts.joined(separator: ", ")
        return "warning: a loopback peer named Host \"\(name)\", which matches no --trusted-host "
            + "(\(trusted)); if a proxy forwarded it, that proxy is not a boundary and its "
            + "callers get full access with no token\n"
    }

    func report(_ host: String) {
        if let line = line(for: host) { sink(line) }
    }
}
