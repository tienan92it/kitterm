import Foundation
import KittermProtocol
import NIOConcurrencyHelpers
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
    /// Spill each session's output to `~/.kitterm/logs/` so ranges older than
    /// the in-memory ring stay readable. Off by default: this is shell output
    /// on disk, the same reason `--record` is opt-in.
    public var retainLogs: Bool
    /// Mint fresh tokens instead of reusing the stored ones. Tokens persist so
    /// a share link survives a restart; this is how you revoke one.
    public var rotateTokens: Bool

    public init(
        host: String = KittermConstants.defaultHost,
        port: Int = KittermConstants.defaultPort,
        allowLAN: Bool = false,
        recordSessions: Bool = false,
        retainLogs: Bool = false,
        agentControl: Bool = false,
        trustedHosts: Set<String> = [],
        tls: TLSConfig? = nil,
        orchestratedLingerSeconds: Int = KittermConstants.orchestratedSessionLingerSeconds,
        rotateTokens: Bool = false
    ) {
        self.host = host
        self.port = port
        self.allowLAN = allowLAN
        self.recordSessions = recordSessions
        self.retainLogs = retainLogs
        self.agentControl = agentControl
        self.trustedHosts = trustedHosts
        self.tls = tls
        self.orchestratedLingerSeconds = orchestratedLingerSeconds
        self.rotateTokens = rotateTokens
    }
}

public final class DaemonServer: @unchecked Sendable {
    private let config: DaemonConfig
    private let group: MultiThreadedEventLoopGroup
    private let registry: SessionRegistry
    /// The daemon-wide control-plane event feed, shared by the registry (which
    /// appends lifecycle events from off-loop) and every HTTP handler.
    private let eventLog: EventLog
    /// The plain listener, always present; the TLS listener when configured.
    private var channels: [Channel] = []
    /// Every accepted connection, so a takeover can flush and close them
    /// all: NIO keeps no such list, and closing a listener leaves its
    /// children open. Loop-confined.
    private let connections = ConnectionTracker()
    /// Sessions handed over by the previous process, adopted in `start()`
    /// once there is a loop to read them on.
    private var adopted: [(session: PtySession, state: TakeoverState.SessionState)] = []
    /// The takeover request an API call recorded, read by `waitUntilClosed`.
    private let takeoverLock = NIOLock()
    private var takeoverRequest: TakeoverRequest?
    /// How this run will be remembered (`LastRun`). Nil outside the `serve`
    /// process: only `runDaemon` begins a run, so building a server in a test
    /// never rewrites the record of the daemon the developer is working in.
    private let lastRun: LastRunStore?
    /// The cadence that keeps `aliveAt` and `sessions` current.
    private var lastRunTask: RepeatedTask?

    /// The sessions and the feed of a quiesced server, so the same process
    /// can serve again from them when its `exec` returned
    /// (`docs/live-upgrade.md`, rung 2).
    public struct Carried: Sendable {
        let registry: SessionRegistry
        let eventLog: EventLog
    }

    /// `previous` is what the run before this one left behind
    /// (`LastRunStore.beginRun`), so `daemon.started` carries how it ended.
    /// Nil outside `runDaemon`: a server built in a test reports nothing.
    public init(
        config: DaemonConfig = DaemonConfig(),
        lastRun: LastRunStore? = nil,
        previous: LastRun? = nil
    ) {
        self.config = config
        self.lastRun = lastRun
        let eventLog = EventLog()
        // The first event of this epoch: a foreman whose cursor predates it
        // reads this before any session it can still find.
        eventLog.markStarted(version: BuildVersion.running, pid: getpid(), previous: previous)
        self.eventLog = eventLog
        self.registry = SessionRegistry(
            orchestratedLingerSeconds: config.orchestratedLingerSeconds,
            eventLog: eventLog,
            respawnHints: RespawnHintStore(file: DaemonPaths.respawnHintsFile)
        )
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// A server that continues the sessions and the feed of the process that
    /// wrote `state` (`serve --takeover`). The sessions are rebuilt around
    /// their inherited masters here and read from `start()`; `daemon.started`
    /// lands inside the carried epoch with `takeover` true.
    public init(
        config: DaemonConfig, adopting state: TakeoverState, from directory: URL,
        lastRun: LastRunStore? = nil, previous: LastRun? = nil
    ) {
        self.config = config
        self.lastRun = lastRun
        let eventLog = EventLog(restoring: state.eventLog)
        eventLog.markStarted(
            version: BuildVersion.running, pid: getpid(), takeover: true, previous: previous
        )
        self.eventLog = eventLog
        self.registry = SessionRegistry(
            orchestratedLingerSeconds: config.orchestratedLingerSeconds,
            eventLog: eventLog,
            respawnHints: RespawnHintStore(file: DaemonPaths.respawnHintsFile)
        )
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        for sessionState in state.sessions {
            let ring = (try? Data(contentsOf: state.ringFile(for: sessionState, in: directory))) ?? Data()
            let session = PtySession(adopting: sessionState, ring: ring)
            session.reattachFiles(from: sessionState)
            adopted.append((session, sessionState))
        }
    }

    /// A server over the sessions and the feed of one that was quiesced for
    /// an `exec` that returned. Nothing is rebuilt: the sessions get a new
    /// reader in `start()`, their clocks restart, and the feed records
    /// another `daemon.started` in the same epoch.
    public init(config: DaemonConfig, carrying carried: Carried, lastRun: LastRunStore? = nil) {
        self.config = config
        self.lastRun = lastRun
        self.eventLog = carried.eventLog
        self.registry = carried.registry
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        carried.eventLog.markStarted(version: BuildVersion.running, pid: getpid(), takeover: true)
    }

    public var boundPort: Int? {
        channels.first?.localAddress?.port
    }

    /// The daemon's own processes, for the rung-2 restart.
    public var carried: Carried {
        Carried(registry: registry, eventLog: eventLog)
    }

    /// A takeover an API call accepted: what to become.
    public struct TakeoverRequest: Sendable, Equatable {
        public let executable: String
    }

    /// How `waitUntilClosed` returned.
    public enum Exit: Sendable, Equatable {
        /// The listener closed; the daemon is stopping.
        case closed
        /// An accepted takeover; the caller quiesces and execs.
        case takeover(TakeoverRequest)
    }

    public func start() throws {
        let registry = self.registry
        let eventLog = self.eventLog
        // One coordinator for all connections; only ever touched on the
        // single event-loop thread.
        let handoff = ControlHandoff()
        // One store for the whole daemon: the hook that registers a pending
        // decision and the phone that answers it arrive on different
        // connections, so a per-connection store would never match them up.
        let approvals = ApprovalStore()
        // One spawn path for a browser tab and the HTTP route alike.
        let spawnService = SessionSpawnService(
            registry: registry,
            recordSessions: config.recordSessions,
            retainLogs: config.retainLogs
        )
        // The route validates the staged binary and, once its answer has
        // gone out, records the request and closes the listeners, which is
        // what wakes `waitUntilClosed` to do the rest.
        let takeover = TakeoverController(executable: TakeoverHandoff.targetExecutable()) { [weak self] request in
            guard let self else { return }
            self.takeoverLock.withLock { self.takeoverRequest = request }
            for channel in self.channels { channel.close(promise: nil) }
        }
        let connections = self.connections
        // Anything reachable from off-machine — an external bind, or a proxy
        // presenting a public name — needs the token pair.
        let policy: AccessPolicy
        if config.allowLAN || !config.trustedHosts.isEmpty {
            try DaemonPaths.ensureStateDirectory()
            // Kept across restarts, so a link already on a phone survives one.
            // `--rotate-token` is how you revoke.
            let token = try PersistedToken.loadOrCreate(
                at: DaemonPaths.tokenFile,
                rotate: config.rotateTokens,
                generate: AccessPolicy.generateToken
            )
            let watchToken = try PersistedToken.loadOrCreate(
                at: DaemonPaths.watchTokenFile,
                rotate: config.rotateTokens,
                generate: { TokenStore.generate(grade: .watch) }
            )
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
            upgradePipelineHandler: { channel, head in
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
                        spawnService: spawnService,
                        watchOnly: watchOnly
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
                // Interactive echo is many tiny writes — never let Nagle delay
                // them. This has to be a TCP-level option: `socketOption` sends
                // it to SOL_SOCKET, where the same number means SO_DEBUG, so
                // Nagle stayed on and Linux refused the privileged option and
                // closed the connection before its pipeline was ever built.
                .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { [config] channel in
                    let httpHandler = HTTPAPIHandler(
                        registry: registry,
                        policy: policy,
                        port: config.port,
                        agentControl: config.agentControl,
                        approvals: approvals,
                        spawnService: spawnService,
                        eventLog: eventLog,
                        connectionIsTLS: sslContext != nil,
                        tlsPort: config.tls?.port,
                        webSocketUpgrader: upgrader,
                        takeover: takeover
                    )
                    connections.track(channel)
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
                    let ready = tlsFirst.flatMap {
                        channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
                    }.flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
                    // A connection whose pipeline never assembles is closed by
                    // NIO with no response and nothing written anywhere, so it
                    // reaches the client as a bare reset. Say why.
                    ready.whenFailure { error in
                        FileHandle.standardError.write(
                            Data("kitterm: connection setup failed: \(error)\n".utf8)
                        )
                    }
                    return ready
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

        // Sessions from the previous process get their readers before the
        // port opens, so the first client to reconnect finds them whole.
        try attachCarriedSessions()

        let plain: Channel
        do {
            plain = try makeBootstrap(sslContext: nil).bind(host: plainHost, port: config.port).wait()
        } catch {
            throw DaemonError.bindFailed(
                host: plainHost,
                port: config.port,
                reason: Self.bindReason(error)
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
                    reason: Self.bindReason(error)
                )
            }
        }

        startLastRunRefresh()
    }

    /// Why a bind failed, in words. `IOError.localizedDescription` is the
    /// generic "operation couldn't be completed (NIOCore.IOError error 1)";
    /// its `description` names the errno, and "Address already in use" is
    /// the one a second daemon on a held port needs to read.
    private static func bindReason(_ error: Error) -> String {
        if let io = error as? IOError {
            return io.description
        }
        return error.localizedDescription
    }

    /// Keep `last-run.json` saying this run is alive, and how many sessions it
    /// holds (`LastRun`). The interval is 30 s, so the record is late by at
    /// most that when the kernel kills the run; nothing waits on the tick.
    ///
    /// The loop only starts the hop: reading the count takes the registry
    /// actor and the write takes the disk, both inside a `Task`, so neither
    /// runs on the event loop. No daemon-wide repeated task existed to hang
    /// this on — `PtySession`'s cwd poll stops when no controller is
    /// attached, and the WebSocket heartbeat is per connection, so both are
    /// gone exactly when an idle daemon is killed.
    private func startLastRunRefresh() {
        guard let lastRun, lastRunTask == nil else { return }
        let registry = self.registry
        lastRunTask = group.next().scheduleRepeatedTask(
            initialDelay: .seconds(Int64(KittermConstants.lastRunRefreshSeconds)),
            delay: .seconds(Int64(KittermConstants.lastRunRefreshSeconds))
        ) { _ in
            Task { lastRun.refresh(sessions: await registry.count) }
        }
    }

    /// Block until the listener closes: a stop, or an accepted takeover.
    public func waitUntilClosed() throws -> Exit {
        try channels.first?.closeFuture.wait()
        if let request = takeoverLock.withLock({ takeoverRequest }) {
            return .takeover(request)
        }
        return .closed
    }

    /// Give every carried session a reader on the loop, and every adopted
    /// one its place in the registry, detached, with exit reporting wired
    /// as for an API-spawned session (nothing else will hear its shell go).
    private func attachCarriedSessions() throws {
        let loop = group.next()
        let registry = self.registry
        let adopted = self.adopted
        self.adopted = []
        for (session, state) in adopted {
            let heldSince = state.heldSince.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            let done = loop.makePromise(of: Bool.self)
            done.completeWithTask { await registry.adopt(session, heldSince: heldSince) }
            guard try done.futureResult.wait() else {
                // Above the cap this build allows: the shell is on its own.
                session.terminate()
                continue
            }
            let id = session.sessionID
            session.detach(onExitWhileDetached: { [weak session] _ in
                session?.terminate()
                Task { await registry.sessionDidExit(id) }
            })
        }
        // Every session in the registry, adopted or carried in-process,
        // reads through a fresh channel. A terminated one declines.
        let detach = loop.makePromise(of: [PtySession].self)
        detach.completeWithTask {
            await registry.detachAll()
            return await registry.handoffSessions().map(\.session)
        }
        for session in try detach.futureResult.wait() {
            try session.makeReader(group: loop, eventLoop: loop).wait()
        }
    }

    /// Quiesce and write the takeover state (`docs/live-upgrade.md`): flush
    /// and close every connection, close each session's reader, drain the
    /// file queues, write `state.json` and the rings under `directory`, and
    /// shut the loop down. On return this process holds every master and
    /// nothing else that matters; `TakeoverHandoff.exec` is the next step,
    /// and `Carried` the way back if it returns. Off the event loop.
    public func prepareHandoff(into directory: URL) throws -> TakeoverState {
        let loop = group.next()
        lastRunTask?.cancel()
        lastRunTask = nil
        // Listeners first, so nothing new arrives while the rest drains.
        for channel in channels { try? channel.close().wait() }
        channels.removeAll()
        try loop.flatSubmit { self.connections.closeAll(on: loop) }.wait()

        let listed = loop.makePromise(of: [(session: PtySession, heldSince: Date?)].self)
        listed.completeWithTask { await self.registry.handoffSessions() }
        let sessions = try listed.futureResult.wait()
        for entry in sessions {
            try entry.session.releaseReader()?.wait()
        }

        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: TakeoverState.ringsDirectory(in: directory),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var states: [TakeoverState.SessionState] = []
        for entry in sessions {
            let ringFile = "\(entry.session.sessionID.uuidString).bin"
            let handoff = entry.session.handoffState(ringFile: ringFile, heldSince: entry.heldSince)
            try handoff.ring.write(
                to: TakeoverState.ringsDirectory(in: directory).appendingPathComponent(ringFile),
                options: .atomic
            )
            states.append(handoff.state)
        }
        let state = TakeoverState(
            writtenBy: BuildVersion.running,
            fds: states.compactMap(\.fd),
            eventLog: eventLog.handoffState(),
            sessions: states
        )
        try state.write(to: directory)
        // The state is on disk, so the successor will have these sessions.
        // Recording the end here, before the `exec`, is what keeps a live
        // upgrade from reading as a death: the successor finds an ending with
        // reason `takeover`, not a record that stops mid-run.
        lastRun?.end(reason: .takeover, sessions: sessions.count)
        try group.syncShutdownGracefully()
        return state
    }

    /// Extracts `?session=<uuid>` from the WS request URI (reattach request).
    static func reattachSessionID(fromRequestURI uri: String) -> UUID? {
        guard let raw = queryValue("session", fromRequestURI: uri) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    /// Every value given for a repeated parameter, in the order they appeared.
    ///
    /// `?path=a&path=b` is the only way to pass a list of paths: a path may
    /// contain any byte but NUL, so there is no character left to delimit them
    /// with that some real filename could not also contain.
    static func queryValues(_ name: String, fromRequestURI uri: String) -> [String] {
        guard let components = URLComponents(string: uri) else { return [] }
        return components.queryItems?
            .filter { $0.name == name }
            .compactMap { $0.value }
            .filter { !$0.isEmpty } ?? []
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
        lastRunTask?.cancel()
        lastRunTask = nil
        // Count before the shells go, so the record says what the run held,
        // and record the ending first: this path runs from the SIGTERM
        // handler, which calls `exit(0)` the moment it returns.
        let held = loop.makePromise(of: Int.self)
        held.completeWithTask { await self.registry.count }
        lastRun?.end(reason: .stopped, sessions: try? held.futureResult.wait())
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

/// Run the daemon in-process (used by `kitterm serve`). `takeover` says
/// where a predecessor left its state and where to leave one for a
/// successor; the default leaves live upgrade wired to the state directory
/// with no argv to relaunch with, which a takeover then reports as a failed
/// `exec` and serves on (rung 2).
///
/// `onListening` runs once, after the listeners are bound and before the
/// first `waitUntilClosed`. It is where `serve` claims `pid` and `port`: a
/// process that has not bound the port yet must not name itself as the
/// daemon, or a second `serve` that then loses the bind leaves the files
/// pointing at a dead process while the first daemon serves on.
public func runDaemon(
    config: DaemonConfig,
    takeover: TakeoverOptions = TakeoverOptions(
        stateDirectory: DaemonPaths.takeoverDirectory,
        relaunchArguments: Array(CommandLine.arguments.dropFirst())
    ),
    onListening: () -> Void = {}
) throws {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGHUP, SIG_IGN)

    // Freeze the running version and the web root now, while the files this
    // build shipped with are still the ones on disk. `kitterm upgrade` swaps
    // them under a live daemon on purpose, and both of these would otherwise
    // read as the *new* build while old code is still serving.
    _ = BuildVersion.running
    _ = StaticFileServer.cachedRoot
    // Tell the installer which bundle this daemon pinned, so a deferred upgrade
    // can prune old ones without pulling this daemon's UI out from under it.
    // Best-effort: a daemon that cannot write this still serves fine, the
    // installer just keeps one more directory than it needs to.
    if let root = StaticFileServer.cachedRoot {
        try? FileManager.default.createDirectory(
            at: DaemonPaths.stateDirectory,
            withIntermediateDirectories: true
        )
        try? root.path.write(to: DaemonPaths.webRootFile, atomically: true, encoding: .utf8)
    }

    // This run's record, and the previous run's, which `beginRun` hands back
    // because replacing the file is the moment it stops existing on disk. A
    // run the kernel killed left no `endedAt`; capability 2 reports that.
    let lastRun = LastRunStore(file: DaemonPaths.lastRunFile)
    let previousRun = lastRun.beginRun()
    // The first line of this run's log is what happened to the last one. It
    // goes out before the listener opens, so a start that then fails to bind
    // still leaves the reader the answer they came for.
    FileHandle.standardError.write(Data(PreviousRun.logLine(previousRun).utf8))

    let current = ServerBox(
        makeServer(config: config, takeover: takeover, lastRun: lastRun, previous: previousRun)
    )
    try current.server.start()
    onListening()

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
            try? current.server.stop()
            exit(0)
        }
        source.resume()
        sources.append(source)
        // Ignore the default disposition only once the source is live.
        signal(signalNumber, SIG_IGN)
    }
    // The sources must outlive this call — a released source stops delivering.
    try withExtendedLifetime(sources) {
        while true {
            switch try current.server.waitUntilClosed() {
            case .closed:
                return
            case .takeover(let request):
                // Quiesce, write the state, and become the staged binary.
                // `exec` keeps the pid and the children; only this code and
                // the sockets go. Returning from it is rung 2 of the failure
                // ladder: this process still holds every master, so it
                // serves again from what it just wrote.
                let directory = takeover.stateDirectory
                let state = try current.server.prepareHandoff(into: directory)
                let arguments = TakeoverHandoff.successorArguments(
                    from: takeover.relaunchArguments,
                    directory: directory
                )
                FileHandle.standardError.write(
                    Data("kitterm: takeover: exec \(request.executable) \(arguments.joined(separator: " "))\n".utf8)
                )
                TakeoverHandoff.prepareDescriptors(carrying: state.fds)
                let failure = TakeoverHandoff.exec(executable: request.executable, arguments: arguments)
                TakeoverHandoff.restoreDescriptors(carried: state.fds)
                FileHandle.standardError.write(
                    Data("kitterm: takeover: exec failed (\(String(cString: strerror(failure)))); serving on from this process\n".utf8)
                )
                try? FileManager.default.removeItem(at: directory)
                // `prepareHandoff` already recorded a `takeover` ending that
                // did not happen. This process serves on, so it is a new run
                // of the same pid and the record has to say so again.
                //
                // Nothing is reported about it. The record `beginRun` returns
                // here is the one this very process wrote a moment ago about
                // an ending it then did not have, so reporting it would tell
                // a reader the daemon handed over when it did not. The line
                // above about the failed `exec` is the true account.
                _ = lastRun.beginRun()
                let carried = current.server.carried
                current.server = DaemonServer(config: config, carrying: carried, lastRun: lastRun)
                try current.server.start()
            }
        }
    }
}

/// How `serve` is wired for a live upgrade: where a predecessor's state is,
/// where to write one for a successor, and the argv the successor gets.
public struct TakeoverOptions: Sendable {
    /// A directory the previous process wrote; adopt it before serving.
    public var adoptFrom: URL?
    /// Where this process writes its own state when it hands over.
    public var stateDirectory: URL
    /// This process's argv after argv[0]; the successor gets it back.
    public var relaunchArguments: [String]

    public init(adoptFrom: URL? = nil, stateDirectory: URL, relaunchArguments: [String]) {
        self.adoptFrom = adoptFrom
        self.stateDirectory = stateDirectory
        self.relaunchArguments = relaunchArguments
    }
}

/// The server currently answering, shared by the main loop and the signal
/// handlers, which must stop whichever one is live.
private final class ServerBox: @unchecked Sendable {
    var server: DaemonServer
    init(_ server: DaemonServer) { self.server = server }
}

/// A server that adopts the predecessor's state when there is one it can
/// read. The failure ladder's rung 3: a layout this build does not know, or
/// a file it cannot read, boots clean — the carried masters are closed so
/// the shells hang up rather than block forever on a buffer nobody drains,
/// and the outcome equals `upgrade --restart`.
private func makeServer(
    config: DaemonConfig, takeover: TakeoverOptions, lastRun: LastRunStore,
    previous: LastRun?
) -> DaemonServer {
    guard let directory = takeover.adoptFrom else {
        return DaemonServer(config: config, lastRun: lastRun, previous: previous)
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let state = try TakeoverState.load(from: directory)
        FileHandle.standardError.write(
            Data("kitterm: takeover: adopting \(state.sessions.count) session(s) from \(state.writtenBy)\n".utf8)
        )
        return DaemonServer(
            config: config, adopting: state, from: directory,
            lastRun: lastRun, previous: previous
        )
    } catch TakeoverState.LoadError.unsupportedFormat(let found, let fds) {
        FileHandle.standardError.write(
            Data("kitterm: takeover: state is format \(found), this build reads \(TakeoverState.currentFormatVersion); starting clean\n".utf8)
        )
        for fd in fds { _ = close(fd) }
    } catch {
        FileHandle.standardError.write(
            Data("kitterm: takeover: \(error.localizedDescription); starting clean\n".utf8)
        )
    }
    return DaemonServer(config: config, lastRun: lastRun, previous: previous)
}

/// Accepted connections, so a takeover can close them all. Loop-confined:
/// `track` runs in the child initializer and `closeAll` is submitted to
/// the loop.
final class ConnectionTracker: @unchecked Sendable {
    private var channels: [ObjectIdentifier: Channel] = [:]

    func track(_ channel: Channel) {
        let key = ObjectIdentifier(channel)
        channels[key] = channel
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.channels.removeValue(forKey: key)
        }
    }

    /// Flush what each WebSocket holds, then close every connection, and
    /// complete when they are all gone. Every close runs on the one loop,
    /// so no handler races the flush.
    func closeAll(on loop: EventLoop) -> EventLoopFuture<Void> {
        let open = Array(channels.values)
        for channel in open {
            if let handler = try? channel.pipeline.syncOperations.handler(type: WebSocketSessionHandler.self) {
                handler.flushOutput()
            }
            channel.close(promise: nil)
        }
        return EventLoopFuture.andAllComplete(open.map(\.closeFuture), on: loop)
    }
}

/// The route's side of a takeover: validates the binary, admits one request
/// at a time, and hands the accepted one to the server once the answer has
/// gone out. Shared by every connection's handler.
public final class TakeoverController: @unchecked Sendable {
    public let executable: String
    private let lock = NIOLock()
    private var accepted = false
    private let commit: @Sendable (DaemonServer.TakeoverRequest) -> Void

    init(executable: String, commit: @escaping @Sendable (DaemonServer.TakeoverRequest) -> Void) {
        self.executable = executable
        self.commit = commit
    }

    public enum Admission: Equatable, Sendable {
        case accepted(DaemonServer.TakeoverRequest)
        /// Another request already won; the daemon is on its way out.
        case inProgress
        /// The binary did not run; nothing changed.
        case invalidBinary(String)
    }

    /// Check the binary off the loop and claim the takeover. The claim comes
    /// after the check, so two callers cannot both pass, and a caller whose
    /// binary fails leaves the daemon exactly as it was.
    func admit(on loop: EventLoop) -> EventLoopFuture<Admission> {
        let promise = loop.makePromise(of: Admission.self)
        guard !lock.withLock({ accepted }) else {
            promise.succeed(.inProgress)
            return promise.futureResult
        }
        let executable = self.executable
        DispatchQueue.global(qos: .userInitiated).async {
            if let reason = TakeoverHandoff.validate(executable: executable) {
                promise.succeed(.invalidBinary(reason))
                return
            }
            let won: Bool = self.lock.withLock {
                guard !self.accepted else { return false }
                self.accepted = true
                return true
            }
            promise.succeed(won ? .accepted(DaemonServer.TakeoverRequest(executable: executable)) : .inProgress)
        }
        return promise.futureResult
    }

    /// The answer is on the wire; start the handoff.
    func begin(_ request: DaemonServer.TakeoverRequest) {
        commit(request)
    }
}
