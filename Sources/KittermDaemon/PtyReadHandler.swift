import NIOCore

/// Forwards PTY master reads from an `NIOPipeBootstrap` channel into `PtySession`.
final class PtyReadHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private weak var session: PtySession?

    init(session: PtySession) {
        self.session = session
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        session?.handleRead(&buffer)
    }

    func channelInactive(context: ChannelHandlerContext) {
        session?.readChannelClosed()
        context.fireChannelInactive()
    }
}
