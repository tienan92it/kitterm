import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public struct DaemonConfig: Sendable {
    public var host: String
    public var port: Int

    public init(
        host: String = KittermConstants.defaultHost,
        port: Int = KittermConstants.defaultPort
    ) {
        self.host = host
        self.port = port
    }
}

public final class DaemonServer: @unchecked Sendable {
    private let config: DaemonConfig
    private let group: MultiThreadedEventLoopGroup
    private let registry = SessionRegistry()
    private var channel: Channel?

    public init(config: DaemonConfig = DaemonConfig()) {
        self.config = config
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public var boundPort: Int? {
        channel?.localAddress?.port
    }

    public func start() throws {
        let registry = self.registry
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: KittermConstants.maxInputBytes + 16,
            shouldUpgrade: { channel, head in
                let (host, origin) = LoopbackSecurity.hostAndOrigin(from: head.headers)
                if let reason = LoopbackSecurity.rejectionReason(
                    hostHeader: host,
                    originHeader: origin
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
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(WebSocketSessionHandler(registry: registry))
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Interactive echo is many tiny writes — never let Nagle delay them.
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPAPIHandler(registry: registry)
                let config = NIOHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader as any HTTPServerProtocolUpgrader],
                    completionHandler: { context in
                        _ = context.pipeline.removeHandler(httpHandler)
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: config
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }

        // Loopback-only bind — never 0.0.0.0 in MVP.
        let host = config.host
        precondition(
            host == "127.0.0.1" || host == "::1" || host == "localhost",
            "kitterm MVP binds loopback only"
        )

        do {
            channel = try bootstrap.bind(host: host, port: config.port).wait()
        } catch {
            throw DaemonError.bindFailed(
                host: host,
                port: config.port,
                reason: error.localizedDescription
            )
        }
        guard let channel else {
            throw DaemonError.bindFailed(host: host, port: config.port, reason: "no channel")
        }
        let port = channel.localAddress?.port ?? config.port
        FileHandle.standardError.write(
            Data("kitterm daemon listening on \(host):\(port)\n".utf8)
        )
    }

    public func waitUntilClosed() throws {
        try channel?.closeFuture.wait()
    }

    public func stop() throws {
        let grace = KittermConstants.serverStopGraceMs
        let loop = group.next()
        let done = loop.makePromise(of: Void.self)
        done.completeWithTask {
            await self.registry.terminateAll()
        }
        try? done.futureResult.wait()

        if let channel {
            try channel.close().wait()
        }
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

    let signals = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signals.setEventHandler {
        try? server.stop()
        exit(0)
    }
    signals.resume()
    signal(SIGTERM, SIG_IGN)

    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        try? server.stop()
        exit(0)
    }
    sigint.resume()
    signal(SIGINT, SIG_IGN)

    try server.waitUntilClosed()
}
