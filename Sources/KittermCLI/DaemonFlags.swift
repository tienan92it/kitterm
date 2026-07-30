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
            trustedHosts: KittermMain.parseTrustedHosts(array),
            tlsCert: KittermMain.parseOption("--tls-cert", array),
            tlsKey: KittermMain.parseOption("--tls-key", array),
            tlsPort: KittermMain.parseOption("--tls-port", array).flatMap(Int.init),
            sessionLinger: KittermMain.parseOption("--session-linger", array).flatMap(Int.init)
        )
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
        for host in trustedHosts.sorted() {
            args.append(contentsOf: ["--trusted-host", host])
        }
        if let tlsCert { args.append(contentsOf: ["--tls-cert", tlsCert]) }
        if let tlsKey { args.append(contentsOf: ["--tls-key", tlsKey]) }
        if let tlsPort { args.append(contentsOf: ["--tls-port", "\(tlsPort)"]) }
        if let sessionLinger { args.append(contentsOf: ["--session-linger", "\(sessionLinger)"]) }
        return args
    }

    func daemonConfig(port: Int) throws -> DaemonConfig {
        DaemonConfig(
            host: KittermConstants.defaultHost,
            port: port,
            allowLAN: lan,
            recordSessions: record,
            retainLogs: retainLogs,
            agentControl: agentControl,
            trustedHosts: trustedHosts,
            tls: try tlsConfig(port: port),
            orchestratedLingerSeconds: sessionLinger
                ?? KittermConstants.orchestratedSessionLingerSeconds
        )
    }
}
