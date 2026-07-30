import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

public struct DaemonConfig: Sendable {
    public var host: String
    public var port: Int
    /// Bind all interfaces and require the token for non-loopback clients.
    public var allowLAN: Bool
    /// Record every session to `~/.kitterm/recordings/*.cast` (asciinema v2).
    public var recordSessions: Bool
    /// Enable the write route (`POST /api/sessions/<id>/input`). Off by default:
    /// it lets any policy-admitted caller drive a shell as the invoking user.
    public var agentControl: Bool
    /// Public names this daemon answers to when fronted by a reverse proxy or
    /// reached over an overlay network (`--trusted-host`). Requests naming one
    /// are treated as remote: they must present a token.
    public var trustedHosts: Set<String>
    /// User-supplied certificate for an encrypted external listener. When set,
    /// the plain listener stays on loopback whatever `allowLAN` says: turning
    /// TLS on removes plaintext from the network instead of adding a door.
    public var tls: TLSConfig?
    /// Detach window for sessions a program created (see `SessionRegistry`).
    public var orchestratedLingerSeconds: Int

    public init(
        host: String = KittermConstants.defaultHost,
        port: Int = KittermConstants.defaultPort,
        allowLAN: Bool = false,
        recordSessions: Bool = false,
        agentControl: Bool = false,
        trustedHosts: Set<String> = [],
        tls: TLSConfig? = nil,
        orchestratedLingerSeconds: Int = KittermConstants.orchestratedSessionLingerSeconds
    ) {
        self.host = host
        self.port = port
        self.allowLAN = allowLAN
        self.recordSessions = recordSessions
        self.agentControl = agentControl
        self.trustedHosts = trustedHosts
        self.tls = tls
        self.orchestratedLingerSeconds = orchestratedLingerSeconds
    }
}

public final class DaemonServer: @unchecked Sendable {
    private let config: DaemonConfig
    private let group: MultiThreadedEventLoopGroup
    private let registry: SessionRegistry
    /// The plain listener, always present; the TLS listener when configured.
    private var channels: [Channel] = []

    public init(config: DaemonConfig = DaemonConfig()) {
        self.config = config
        self.registry = SessionRegistry(
            orchestratedLingerSeconds: config.orchestratedLingerSeconds
        )
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public var boundPort: Int? {
        channels.first?.localAddress?.port
    }

    public func start() throws {
        let registry = self.registry
        // One coordinator for all connections; only ever touched on the
        // single event-loop thread.
        let handoff = ControlHandoff()
        // Anything reachable from off-machine — an external bind, or a proxy
        // presenting a public name — needs the token pair.
        let policy: AccessPolicy
        if config.allowLAN || !config.trustedHosts.isEmpty {
            let token = AccessPolicy.generateToken()
            let watchToken = TokenStore.generate(grade: .watch)
            try DaemonPaths.ensureStateDirectory()
            for (value, file) in [(token, DaemonPaths.tokenFile), (watchToken, DaemonPaths.watchTokenFile)] {
                try value.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: file.path
                )
            }
            let named = CachedTokenStore()
            policy = config.allowLAN
                ? .lan(
                    token: token,
                    watchToken: watchToken,
                    namedTokens: named,
                    trustedHosts: config.trustedHosts
                )
                : .proxied(
                    token: token,
                    watchToken: watchToken,
                    namedTokens: named,
                    trustedHosts: config.trustedHosts
                )
        } else {
            try? FileManager.default.removeItem(at: DaemonPaths.tokenFile)
            try? FileManager.default.removeItem(at: DaemonPaths.watchTokenFile)
            policy = .loopbackOnly
        }

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: KittermConstants.maxInputBytes + 16,
            shouldUpgrade: { channel, head in
                if case .reject(let reason) = policy.decide(
                    remote: channel.remoteAddress,
                    headers: head.headers,
                    uri: head.uri
                ) {
                    return channel.eventLoop.makeFailedFuture(
                        DaemonError.rejected(reason)
                    )
                }
                guard head.uri == "/ws" || head.uri.hasPrefix("/ws?") else {
                    return channel.eventLoop.makeFailedFuture(
                        DaemonError.rejected("not a websocket path")
                    )
                }
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { [config, group] channel, head in
                // shouldUpgrade already admitted this request; re-derive the
                // grade so a watch token gets a watch-only connection.
                let watchOnly: Bool
                switch policy.decide(
                    remote: channel.remoteAddress,
                    headers: head.headers,
                    uri: head.uri
                ) {
                case .allow(let grade), .allowSettingCookie(let grade, cookie: _):
                    watchOnly = grade == .watch
                case .reject:
                    watchOnly = true // unreachable; fail closed
                }
                let reattachID = Self.reattachSessionID(fromRequestURI: head.uri)
                let requestedCwd = Self.queryValue("cwd", fromRequestURI: head.uri)
                let freshClient = Self.queryValue("fresh", fromRequestURI: head.uri) == "1"
                let histKey = Self.queryValue("hist", fromRequestURI: head.uri)
                let profileName = Self.queryValue("profile", fromRequestURI: head.uri)
                let labels = SessionLabels.parse(Self.queryValue("label", fromRequestURI: head.uri))
                let sinceOffset = Self.queryValue("since", fromRequestURI: head.uri)
                    .flatMap(UInt64.init)
                return channel.pipeline.addHandler(
                    WebSocketSessionHandler(
                        registry: registry,
                        handoff: handoff,
                        reattachID: reattachID,
                        requestedCwd: requestedCwd,
                        freshClient: freshClient,
                        histKey: histKey,
                        profileName: profileName,
                        labels: labels,
                        sinceOffset: sinceOffset,
                        recordSessions: config.recordSessions,
                        watchOnly: watchOnly,
                        eventLoopGroup: group
                    )
                )
            }
        )

        // One bootstrap shape for both listeners; only the optional TLS
        // handler differs, so the loopback pipeline is byte-for-byte what it
        // was before TLS existed.
        func makeBootstrap(sslContext: NIOSSLContext?) -> ServerBootstrap {
            ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                // Interactive echo is many tiny writes — never let Nagle delay them.
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { [config] channel in
                    let httpHandler = HTTPAPIHandler(
                        registry: registry,
                        policy: policy,
                        port: config.port,
                        agentControl: config.agentControl,
                        connectionIsTLS: sslContext != nil,
                        tlsPort: config.tls?.port
                    )
                    let upgradeConfig = NIOHTTPServerUpgradeConfiguration(
                        upgraders: [upgrader as any HTTPServerProtocolUpgrader],
                        completionHandler: { context in
                            _ = context.pipeline.removeHandler(httpHandler)
                        }
                    )
                    let tlsFirst: EventLoopFuture<Void>
                    if let sslContext {
                        tlsFirst = channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext))
                    } else {
                        tlsFirst = channel.eventLoop.makeSucceededVoidFuture()
                    }
                    return tlsFirst.flatMap {
                        channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
                    }.flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
                }
        }

        // Loopback by default. `--lan` widens the plain listener — but not
        // when TLS is configured, because then the encrypted listener is the
        // way in and plaintext should never leave the machine.
        let plainHost = (config.allowLAN && config.tls == nil) ? "0.0.0.0" : config.host
        precondition(
            (config.allowLAN && config.tls == nil)
                || plainHost == "127.0.0.1" || plainHost == "::1" || plainHost == "localhost",
            "kitterm binds loopback unless --lan is set"
        )

        // Load and validate certificates before binding anything: a bad path
        // should fail the launch, not the first connection.
        let sslContext = try config.tls?.makeSSLContext()

        let plain: Channel
        do {
            plain = try makeBootstrap(sslContext: nil).bind(host: plainHost, port: config.port).wait()
        } catch {
            throw DaemonError.bindFailed(
                host: plainHost,
                port: config.port,
                reason: error.localizedDescription
            )
        }
        channels.append(plain)
        FileHandle.standardError.write(
            Data("kitterm daemon listening on \(plainHost):\(plain.localAddress?.port ?? config.port)\n".utf8)
        )

        if let tls = config.tls, let sslContext {
            do {
                let secure = try makeBootstrap(sslContext: sslContext)
                    .bind(host: "0.0.0.0", port: tls.port).wait()
                channels.append(secure)
                FileHandle.standardError.write(
                    Data("kitterm daemon listening on 0.0.0.0:\(tls.port) (TLS)\n".utf8)
                )
            } catch {
                // Close the plain listener so a half-started daemon never
                // lingers holding the port.
                try? plain.close().wait()
                channels.removeAll()
                throw DaemonError.bindFailed(
                    host: "0.0.0.0",
                    port: tls.port,
                    reason: error.localizedDescription
                )
            }
        }
    }

    public func waitUntilClosed() throws {
        try channels.first?.closeFuture.wait()
    }

    /// Extracts `?session=<uuid>` from the WS request URI (reattach request).
    static func reattachSessionID(fromRequestURI uri: String) -> UUID? {
        guard let raw = queryValue("session", fromRequestURI: uri) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    static func queryValue(_ name: String, fromRequestURI uri: String) -> String? {
        guard let components = URLComponents(string: uri),
              let value = components.queryItems?.first(where: { $0.name == name })?.value,
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    public func stop() throws {
        let grace = KittermConstants.serverStopGraceMs
        let loop = group.next()
        let done = loop.makePromise(of: Void.self)
        done.completeWithTask {
            await self.registry.terminateAll()
        }
        try? done.futureResult.wait()

        for channel in channels {
            try? channel.close().wait()
        }
        channels.removeAll()
        try group.syncShutdownGracefully()
        // Bound wait so CLI stop never hangs forever.
        Thread.sleep(forTimeInterval: Double(grace) / 1000.0 / 10.0)
    }
}

public enum DaemonError: Error, LocalizedError {
    case bindFailed(host: String, port: Int, reason: String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .bindFailed(let host, let port, let reason):
            return "failed to bind \(host):\(port) — \(reason)"
        case .rejected(let reason):
            return reason
        }
    }
}

/// Run the daemon in-process (used by `kitterm serve`).
public func runDaemon(config: DaemonConfig) throws {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGHUP, SIG_IGN)

    let server = DaemonServer(config: config)
    try server.start()

    // Not the main queue: this thread parks in `waitUntilClosed()` and never
    // drains it, so a `.main` source would never fire — the daemon would
    // ignore SIGTERM (it is SIG_IGN'd below) and every `kitterm stop` would
    // fall through to the SIGKILL fallback, skipping `terminateAll()` and so
    // the SIGHUP that makes zsh flush each pane's history. A dedicated queue
    // is serviced by libdispatch's own threads. (Doubly required on Linux,
    // where the main queue only runs under `dispatchMain()`.)
    let signalQueue = DispatchQueue(label: "kitterm.signals")
    var sources: [DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT] {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
        source.setEventHandler {
            try? server.stop()
            exit(0)
        }
        source.resume()
        sources.append(source)
        // Ignore the default disposition only once the source is live.
        signal(signalNumber, SIG_IGN)
    }
    // The sources must outlive this call — a released source stops delivering.
    try withExtendedLifetime(sources) {
        try server.waitUntilClosed()
    }
}
