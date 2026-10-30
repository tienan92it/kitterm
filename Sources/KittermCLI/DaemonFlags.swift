import Foundation
import KittermDaemon
import KittermProtocol

/// The daemon options a user can pass to `start`, `restart`, `service
/// install`, and `serve`. Parsed once from argv and carried as one value, so
/// every path that launches or re-launches the daemon — spawning `serve`,
/// writing the LaunchAgent plist — reproduces the same configuration without
/// each growing another parameter.
struct DaemonFlags {
    var lan = false
    var record = false
    var agentControl = false
    var retainLogs = false
    /// Replace the stored tokens rather than reusing them, revoking any link
    /// already handed out.
    var rotateTokens = false
    /// Public names the daemon answers to behind a proxy / overlay network.
    var trustedHosts: Set<String> = []
    var tlsCert: String?
    var tlsKey: String?
    /// Defaults to `port + 1` when a certificate is supplied.
    var tlsPort: Int?
    /// Detach window for program-created (labelled) sessions, in seconds.
    var sessionLinger: Int?

    static func parse<S: Sequence>(_ args: S) -> DaemonFlags where S.Element == String {
        let array = Array(args)
        return DaemonFlags(
            lan: array.contains("--lan"),
            record: array.contains("--record"),
            agentControl: array.contains("--agent-control"),
            retainLogs: array.contains("--retain-logs"),
            rotateTokens: array.contains("--rotate-token"),
            trustedHosts: KittermMain.parseTrustedHosts(array),
            tlsCert: KittermMain.parseOption("--tls-cert", array),
            tlsKey: KittermMain.parseOption("--tls-key", array),
            tlsPort: KittermMain.parseOption("--tls-port", array).flatMap(Int.init),
            sessionLinger: KittermMain.parseOption("--session-linger", array).flatMap(Int.init)
        )
    }

    /// Reject a linger the daemon cannot honour: `Task.sleep` reads a negative
    /// window as "drop it now" and an enormous one as "never".
    func validatedSessionLinger() throws -> Int? {
        guard let sessionLinger else { return nil }
        guard sessionLinger >= 1, sessionLinger <= KittermConstants.maxSessionLingerSeconds else {
            throw CLIError.usage(
                """
                --session-linger must be between 1 and \
                \(KittermConstants.maxSessionLingerSeconds) seconds \
                (got \(sessionLinger))
                """
            )
        }
        return sessionLinger
    }

    /// The message `--lan` without `--trusted-host` is refused with. One
    /// string, so the tests and the docs quote the words the daemon prints.
    static let lanNeedsTrustedHost =
        "--lan must be given with --trusted-host <your public name>: "
        + "without it a proxy on loopback inherits full access with no token"

    /// Refuse `--lan` with no `--trusted-host`. With `--lan` the daemon skips
    /// the loopback `Host` check, so a reverse proxy that connects from
    /// loopback (`tailscale serve`) is read as the local human and gets full
    /// access with no token, and only a trusted host makes that request
    /// remote. Measured in `docs/goals/proxy-is-a-boundary/rounds/001.md`.
    /// The check sits here so `serve`, `start`, `service install` and a
    /// service `restart` refuse with the same words.
    func validatedTrustedHosts() throws -> Set<String> {
        if lan, trustedHosts.isEmpty {
            throw CLIError.usage(Self.lanNeedsTrustedHost)
        }
        return trustedHosts
    }

    /// Both halves or neither; the port defaults beside the plain one.
    func tlsConfig(port: Int) throws -> TLSConfig? {
        switch (tlsCert, tlsKey) {
        case (nil, nil):
            return nil
        case (let cert?, let key?):
            let securePort = tlsPort ?? port + 1
            guard securePort != port else {
                throw CLIError.usage(
                    "--tls-port must differ from --port (\(port)): the plain loopback listener keeps that one"
                )
            }
            return TLSConfig(certificatePath: cert, privateKeyPath: key, port: securePort)
        default:
            throw CLIError.usage("--tls-cert and --tls-key must be given together")
        }
    }

    /// argv fragment that reproduces these flags for a child `serve` process
    /// or a LaunchAgent plist. Sorted so the plist is stable across runs.
    var serveArguments: [String] {
        var args: [String] = []
        if lan { args.append("--lan") }
        if record { args.append("--record") }
        if agentControl { args.append("--agent-control") }
        if retainLogs { args.append("--retain-logs") }
        if rotateTokens { args.append("--rotate-token") }
        for host in trustedHosts.sorted() {
            args.append(contentsOf: ["--trusted-host", host])
        }
        if let tlsCert { args.append(contentsOf: ["--tls-cert", tlsCert]) }
        if let tlsKey { args.append(contentsOf: ["--tls-key", tlsKey]) }
        if let tlsPort { args.append(contentsOf: ["--tls-port", "\(tlsPort)"]) }
        if let sessionLinger { args.append(contentsOf: ["--session-linger", "\(sessionLinger)"]) }
        return args
    }

    /// Flags with no value, as `DaemonFlags.parse` reads them.
    private static let booleanFlagNames: Set<String> = [
        "--lan", "--record", "--agent-control", "--retain-logs", "--rotate-token",
    ]

    /// Flags that take a value, either `--name value` or `--name=value`, as
    /// `DaemonFlags.parse`, `KittermMain.parsePort`, and `parsePortFlag`
    /// read them.
    private static let valuedFlagNames: Set<String> = [
        "--port", "--trusted-host", "--tls-cert", "--tls-key", "--tls-port", "--session-linger",
    ]

    static let usage =
        "usage: kitterm start|restart|service install [--port PORT] [--lan] [--record] "
        + "[--agent-control] [--retain-logs] [--rotate-token] [--trusted-host NAME] "
        + "[--tls-cert FILE --tls-key FILE [--tls-port PORT]] [--session-linger SECONDS]"

    /// Reject any argument that is not a known flag or a known flag's value,
    /// before `start`, `restart`, or `service install` does anything else.
    ///
    /// This is the fix the incident needed: `DaemonFlags.parse` keeps the
    /// flags it knows and silently drops the rest, so `--help` (or any
    /// typo) fell through, and the command that was supposed to only print
    /// usage went on to rewrite the LaunchAgent plist with none of the
    /// daemon's real flags — `--agent-control` and `--retain-logs` were
    /// lost and every pane's program died (docs/goals/facts.md,
    /// 2026-10-30).
    ///
    /// `serve` never calls this: it is what launchd and a live takeover
    /// `exec`, and a daemon that refused to boot on a flag from an older
    /// plist would be worse than one that silently ignores it.
    static func validate<S: Sequence>(_ args: S) throws where S.Element == String {
        let array = Array(args)
        var index = 0
        while index < array.count {
            let arg = array[index]
            guard arg.hasPrefix("-") else {
                index += 1
                continue
            }
            let name = arg.contains("=") ? String(arg.split(separator: "=", maxSplits: 1)[0]) : arg
            if booleanFlagNames.contains(name), !arg.contains("=") {
                index += 1
                continue
            }
            if valuedFlagNames.contains(name) {
                if arg.contains("=") {
                    index += 1
                } else if index + 1 < array.count, !array[index + 1].hasPrefix("--") {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            throw CLIError.unknownOption("kitterm: unknown option \(arg)\n\(usage)")
        }
    }

    func daemonConfig(port: Int) throws -> DaemonConfig {
        DaemonConfig(
            host: KittermConstants.defaultHost,
            port: port,
            allowLAN: lan,
            recordSessions: record,
            retainLogs: retainLogs,
            agentControl: agentControl,
            trustedHosts: try validatedTrustedHosts(),
            tls: try tlsConfig(port: port),
            orchestratedLingerSeconds: try validatedSessionLinger()
                ?? KittermConstants.orchestratedSessionLingerSeconds,
            rotateTokens: rotateTokens
        )
    }
}
