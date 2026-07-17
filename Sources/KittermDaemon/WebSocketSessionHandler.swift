import Foundation
import KittermProtocol
import NIOCore
import NIOWebSocket

final class WebSocketSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let registry: SessionRegistry
    private let reattachID: UUID?
    private var sessionID: UUID?
    private var pty: PtySession?
    private var batcher: OutputBatcher?
    /// Client frames that arrive before the PTY is wired (claim is async).
    private var pendingClientFrames: [Data] = []
    private var outboundBuffered = 0
    private var clientPaused = false
    private var ptyReadPaused = false
    private var ptyExited = false
    private var awaitingPong = false
    private var heartbeatTask: RepeatedTask?
    private var closed = false

    init(registry: SessionRegistry, reattachID: UUID? = nil) {
        self.registry = registry
        self.reattachID = reattachID
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(
            ChannelOptions.writeBufferWaterMark,
            value: ChannelOptions.Types.WriteBufferWaterMark(
                low: KittermConstants.wsOutboundResumeLowWaterBytes,
                high: KittermConstants.wsOutboundPauseHighWaterBytes
            )
        ).whenFailure { _ in }

        let claimPromise = context.eventLoop.makePromise(of: PtySession?.self)
        let registry = self.registry
        let reattachID = self.reattachID
        claimPromise.completeWithTask {
            guard let reattachID else { return nil }
            return await registry.claim(reattachID)
        }
        claimPromise.futureResult.whenSuccess { [weak self] claimed in
            guard let self, !self.closed else {
                // Channel died before the claim resolved — put the session back.
                if let claimed, let reattachID {
                    claimed.detach()
                    Task { await registry.markDetached(reattachID) }
                }
                return
            }
            if let claimed, let reattachID {
                self.adopt(session: claimed, id: reattachID, context: context)
            } else {
                self.spawnNew(context: context)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        teardown()
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        updateBackpressure(context: context)
        context.fireChannelWritabilityChanged()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            teardown()
            context.close(promise: nil)
        case .ping:
            var frameData = frame.data
            let maskingKey = frame.maskKey
            if let maskingKey {
                frameData.webSocketUnmask(maskingKey)
            }
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .pong:
            awaitingPong = false
        case .binary, .text:
            var payload = frame.unmaskedData
            guard let bytes = payload.readBytes(length: payload.readableBytes) else { return }
            let data = Data(bytes)
            if pty == nil {
                pendingClientFrames.append(data)
                return
            }
            handleClientPayload(data, context: context)
        default:
            break
        }
    }

    // MARK: - Session wiring

    private func adopt(session: PtySession, id: UUID, context: ChannelHandlerContext) {
        sessionID = id
        pty = session
        sendSessionId(id, context: context)
        sendMeta(context: context, session: session)
        wire(session: session, context: context)
    }

    private func spawnNew(context: ChannelHandlerContext) {
        do {
            let session = try PtySession.spawn()
            self.pty = session
            let idPromise = context.eventLoop.makePromise(of: UUID.self)
            idPromise.completeWithTask {
                await self.registry.register(session)
            }
            let registry = self.registry
            idPromise.futureResult.whenSuccess { [weak self, weak context] id in
                guard let self, let context, !self.closed else {
                    // Channel died before registration resolved — reap the entry.
                    Task { await registry.remove(id) }
                    return
                }
                self.sessionID = id
                self.sendSessionId(id, context: context)
            }
            sendMeta(context: context, session: session)
            wire(session: session, context: context)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "pty spawn failed"
            FileHandle.standardError.write(Data("kitterm: \(reason)\n".utf8))
            closePolicy(context: context, reason: reason)
        }
    }

    private func wire(session: PtySession, context: ChannelHandlerContext) {
        let batcher = OutputBatcher(eventLoop: context.eventLoop) { [weak self, weak context] buffer in
            guard let self, let context else { return }
            self.sendOutput(buffer, context: context)
        }
        self.batcher = batcher

        session.attach(
            onOutput: { [weak self, weak context] data in
                guard let context else { return }
                context.eventLoop.execute {
                    self?.batcher?.append(data)
                }
            },
            onExit: { [weak self, weak context] code in
                guard let context else { return }
                context.eventLoop.execute {
                    self?.handlePtyExit(code, context: context)
                }
            }
        )

        startHeartbeat(context: context)

        let queued = pendingClientFrames
        pendingClientFrames = []
        for data in queued {
            handleClientPayload(data, context: context)
        }
    }

    private func handleClientPayload(_ data: Data, context: ChannelHandlerContext) {
        // Oversized frames are dropped (not session-killing). Clients should chunk pastes.
        guard data.count <= KittermConstants.maxInputBytes + 1 else {
            return
        }
        do {
            let frame = try ClientFrame.decode(data)
            switch frame {
            case .input(let bytes):
                try pty?.write(bytes)
            case .resize(let cols, let rows):
                try pty?.resize(cols: cols, rows: rows)
            case .pause:
                clientPaused = true
                pty?.pauseReading()
                ptyReadPaused = true
            case .resume:
                clientPaused = false
                updateBackpressure(context: context)
            }
        } catch {
            // Ignore malformed frames; keep session alive.
        }
    }

    // MARK: - Outbound

    private func sendSessionId(_ id: UUID, context: ChannelHandlerContext) {
        if let encoded = try? ServerFrame.sessionId(id.uuidString).encode() {
            writeBinary(encoded, context: context)
        }
    }

    private func sendMeta(context: ChannelHandlerContext, session: PtySession) {
        let meta = SessionMeta(
            shell: session.shellPath,
            pid: session.pid,
            cwd: session.initialCwd
        )
        if let encoded = try? ServerFrame.sessionMeta(meta).encode() {
            writeBinary(encoded, context: context)
        }
        if let encoded = try? ServerFrame.cwd(session.initialCwd).encode() {
            writeBinary(encoded, context: context)
        }
        let shellName = URL(fileURLWithPath: session.shellPath).lastPathComponent
        if let encoded = try? ServerFrame.title(shellName).encode() {
            writeBinary(encoded, context: context)
        }
    }

    private func sendOutput(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        guard !closed else { return }
        var payload = context.channel.allocator.buffer(capacity: 1 + buffer.readableBytes)
        payload.writeInteger(ServerOpcode.output.rawValue, as: UInt8.self)
        var copy = buffer
        payload.writeBuffer(&copy)
        outboundBuffered += payload.readableBytes
        if outboundBuffered >= KittermConstants.wsBackpressureThresholdBytes {
            closeBackpressure(context: context)
            return
        }
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: payload)
        context.writeAndFlush(wrapOutboundOut(frame)).whenComplete { [weak self] _ in
            guard let self else { return }
            context.eventLoop.execute {
                self.outboundBuffered = max(0, self.outboundBuffered - payload.readableBytes)
                self.updateBackpressure(context: context)
            }
        }
        updateBackpressure(context: context)
    }

    private func writeBinary(_ data: Data, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }

    private func updateBackpressure(context: ChannelHandlerContext) {
        guard !clientPaused else { return }
        let shouldPause =
            !context.channel.isWritable
            || outboundBuffered >= KittermConstants.wsOutboundPauseHighWaterBytes
        if shouldPause, !ptyReadPaused {
            pty?.pauseReading()
            ptyReadPaused = true
        } else if !shouldPause, ptyReadPaused,
                  outboundBuffered <= KittermConstants.wsOutboundResumeLowWaterBytes {
            pty?.resumeReading()
            ptyReadPaused = false
        }
    }

    private func startHeartbeat(context: ChannelHandlerContext) {
        heartbeatTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .milliseconds(Int64(KittermConstants.wsHeartbeatIntervalMs)),
            delay: .milliseconds(Int64(KittermConstants.wsHeartbeatIntervalMs))
        ) { [weak self, weak context] _ in
            guard let self, let context, !self.closed else { return }
            if self.awaitingPong {
                self.teardown()
                context.close(promise: nil)
                return
            }
            self.awaitingPong = true
            let ping = WebSocketFrame(
                fin: true,
                opcode: .ping,
                data: context.channel.allocator.buffer(capacity: 0)
            )
            context.writeAndFlush(self.wrapOutboundOut(ping), promise: nil)
        }
    }

    // MARK: - Teardown

    private func handlePtyExit(_ code: Int32, context: ChannelHandlerContext) {
        ptyExited = true
        batcher?.flushNow()
        if let encoded = try? ServerFrame.exit(code).encode() {
            writeBinary(encoded, context: context)
        }
        teardown()
        context.close(promise: nil)
    }

    private func closePolicy(context: ChannelHandlerContext, reason: String) {
        var buffer = context.channel.allocator.buffer(capacity: 2 + reason.utf8.count)
        buffer.writeInteger(UInt16(1008), endianness: .big, as: UInt16.self)
        buffer.writeString(reason)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame)).whenComplete { _ in
            context.close(promise: nil)
        }
        teardown()
    }

    private func closeBackpressure(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.writeInteger(UInt16(4429), endianness: .big, as: UInt16.self)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame)).whenComplete { _ in
            context.close(promise: nil)
        }
        teardown()
    }

    /// Connection is gone. If the shell still runs, detach it — the client may
    /// reattach (sleep/wake, reload). The registry reaps it after the linger
    /// window. Only an exited shell is terminated immediately.
    private func teardown() {
        guard !closed else { return }
        closed = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        batcher?.close()
        batcher = nil
        pendingClientFrames = []

        let registry = registry
        if let pty, let sessionID {
            if ptyExited {
                pty.terminate()
                Task { await registry.remove(sessionID) }
            } else {
                pty.detach(onExitWhileDetached: { _ in
                    Task { await registry.remove(sessionID) }
                })
                Task { await registry.markDetached(sessionID) }
            }
        } else if let pty {
            // Never registered (spawn raced teardown) — kill it.
            pty.terminate()
        }
        pty = nil
        sessionID = nil
    }
}
