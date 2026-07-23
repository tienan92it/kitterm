import Foundation
import KittermProtocol
import NIOCore
import NIOWebSocket

final class WebSocketSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let registry: SessionRegistry
    private let reattachID: UUID?
    private let requestedCwd: String?
    /// Selects this pane's own history file; nil falls back to the shell default.
    private let histKey: String?
    /// Client page has no screen state (reload / adopted link) — reattach
    /// replays the recent tail instead of only the detached bytes.
    private let freshClient: Bool
    /// The client's count of output bytes it already has (`?since=`); the
    /// daemon replays exactly the gap after it. Takes precedence over `fresh`.
    private let sinceOffset: UInt64?
    private let recordSessions: Bool
    private let eventLoopGroup: EventLoopGroup
    private var sessionID: UUID?
    private var pty: PtySession?
    private var batcher: OutputBatcher?
    private var role: SessionRole = .controller
    /// Identity of this connection in the session's observer list.
    private let observerID = UUID()
    /// Client frames that arrive before the PTY is wired (claim is async).
    private var pendingClientFrames: [Data] = []
    private var clientPaused = false
    private var ptyReadPaused = false
    private var ptyExited = false
    private var awaitingPong = false
    private var heartbeatTask: RepeatedTask?
    private var closed = false

    init(
        registry: SessionRegistry,
        reattachID: UUID? = nil,
        requestedCwd: String? = nil,
        freshClient: Bool = false,
        histKey: String? = nil,
        sinceOffset: UInt64? = nil,
        recordSessions: Bool = false,
        eventLoopGroup: EventLoopGroup
    ) {
        self.registry = registry
        self.reattachID = reattachID
        self.requestedCwd = requestedCwd
        self.freshClient = freshClient
        self.histKey = histKey
        self.sinceOffset = sinceOffset
        self.recordSessions = recordSessions
        self.eventLoopGroup = eventLoopGroup
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let claimPromise = context.eventLoop.makePromise(of: SessionRegistry.SessionResolution.self)
        let registry = self.registry
        let reattachID = self.reattachID
        claimPromise.completeWithTask {
            guard let reattachID else { return .notFound }
            return await registry.resolve(reattachID)
        }
        claimPromise.futureResult.whenSuccess { [weak self] resolution in
            guard let self, !self.closed else {
                // Channel died before the claim resolved — put the session back.
                if case .controller(let session) = resolution, let reattachID {
                    session.detach()
                    Task { await registry.markDetached(reattachID) }
                }
                return
            }
            switch resolution {
            case .controller(let session):
                self.adopt(session: session, id: self.reattachID!, context: context)
            case .observer(let session):
                self.adoptAsObserver(session: session, id: self.reattachID!, context: context)
            case .notFound:
                self.spawnNew(context: context)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        teardown()
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if role == .observer, !context.channel.isWritable {
            closeBackpressure(context: context)
            return
        }
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
        applyWriteWatermarks(context: context, role: .controller)
        sendSessionId(id, context: context)
        sendRole(.controller, context: context)
        sendMeta(context: context, session: session)
        wire(session: session, context: context)
    }

    /// Read-only mirror: replay the recent tail, then stream live output.
    private func adoptAsObserver(session: PtySession, id: UUID, context: ChannelHandlerContext) {
        role = .observer
        sessionID = id
        pty = session
        applyWriteWatermarks(context: context, role: .observer)
        sendSessionId(id, context: context)
        sendRole(.observer, context: context)
        sendMeta(context: context, session: session)
        if let encoded = try? ServerFrame.resize(cols: session.cols, rows: session.rows).encode() {
            writeBinary(encoded, context: context)
        }

        let batcher = OutputBatcher(eventLoop: context.eventLoop) { [weak self, weak context] buffer in
            guard let self, let context else { return }
            self.sendOutput(buffer, context: context)
        }
        self.batcher = batcher

        let replay = session.addObserver(
            observerID,
            handlers: PtySession.ObserverHandlers(
                onOutput: { [weak self] data in
                    self?.batcher?.append(data)
                },
                onExit: { [weak self, weak context] code in
                    guard let context else { return }
                    self?.handlePtyExit(code, context: context)
                },
                onResize: { [weak self, weak context] cols, rows in
                    guard let self, let context, !self.closed else { return }
                    if let encoded = try? ServerFrame.resize(cols: cols, rows: rows).encode() {
                        self.writeBinary(encoded, context: context)
                    }
                }
            )
        )
        sendLogState(resync: true, snapshot: replay, context: context)
        if !replay.data.isEmpty {
            batcher.append(replay.data)
        }
        startHeartbeat(context: context)
        pendingClientFrames = []
    }

    private func spawnNew(context: ChannelHandlerContext) {
        do {
            let session = try PtySession.spawn(
                cwd: Self.validatedCwd(requestedCwd),
                histFile: Self.historyFile(for: histKey)
            )
            self.pty = session
            if recordSessions,
               let recorder = SessionRecorder(
                   directory: DaemonPaths.recordingsDirectory,
                   cols: session.cols,
                   rows: session.rows,
                   shell: session.shellPath
               ) {
                session.attachRecorder(recorder)
            }
            let registry = self.registry
            let setup = session.makeReader(group: eventLoopGroup, eventLoop: context.eventLoop).flatMap { () -> EventLoopFuture<UUID> in
                let idPromise = context.eventLoop.makePromise(of: UUID.self)
                idPromise.completeWithTask {
                    await registry.register(session)
                }
                return idPromise.futureResult
            }
            setup.whenFailure { [weak self, weak context] error in
                guard let self, let context else { return }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                FileHandle.standardError.write(Data("kitterm: \(reason)\n".utf8))
                self.closePolicy(context: context, reason: reason)
            }
            setup.whenSuccess { [weak self, weak context] id in
                guard let self, let context, !self.closed else {
                    Task { await registry.remove(id) }
                    return
                }
                self.sessionID = id
                self.sendSessionId(id, context: context)
                self.sendRole(.controller, context: context)
                self.sendMeta(context: context, session: session)
                self.wire(session: session, context: context, freshlySpawned: true)
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "pty spawn failed"
            FileHandle.standardError.write(Data("kitterm: \(reason)\n".utf8))
            closePolicy(context: context, reason: reason)
        }
    }

    private func wire(
        session: PtySession,
        context: ChannelHandlerContext,
        freshlySpawned: Bool = false
    ) {
        applyWriteWatermarks(context: context, role: .controller)
        let batcher = OutputBatcher(eventLoop: context.eventLoop) { [weak self, weak context] buffer in
            guard let self, let context else { return }
            self.sendOutput(buffer, context: context)
        }
        self.batcher = batcher

        let plan = Self.resolveReplay(
            freshlySpawned: freshlySpawned,
            reattaching: reattachID != nil,
            sinceOffset: sinceOffset,
            freshClient: freshClient
        )
        let isTail = if case .tail = plan.request { true } else { false }
        let snapshot = session.attach(
            onOutput: { [weak self] data in
                self?.batcher?.append(data)
            },
            onExit: { [weak self, weak context] code in
                guard let context else { return }
                self?.handlePtyExit(code, context: context)
            },
            onCwd: { [weak self, weak context] cwd in
                guard let self, let context, let encoded = try? ServerFrame.cwd(cwd).encode() else {
                    return
                }
                self.writeBinary(encoded, context: context)
            },
            replay: plan.request
        )
        // A tail replay lands on a screen that never saw the earlier bytes, and
        // a fresh shell that replaced a missing session lands on the previous
        // shell's stale screen — both need the same reset a pruned offset does.
        sendLogState(
            resync: snapshot.pruned || isTail || plan.forceResync,
            snapshot: snapshot,
            context: context
        )
        if !snapshot.data.isEmpty {
            batcher.append(snapshot.data)
        }

        startHeartbeat(context: context)

        let queued = pendingClientFrames
        pendingClientFrames = []
        for data in queued {
            handleClientPayload(data, context: context)
        }
    }

    private func handleClientPayload(_ data: Data, context: ChannelHandlerContext) {
        // Observers are read-only: their input never reaches the PTY.
        guard role == .controller else { return }
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
            case .mark(let kind, let exit, let offset, let command):
                // Controller-only (guarded above); the client's emulator did
                // the ANSI parsing — the daemon just indexes the result.
                pty?.appendMark(
                    SessionMark(offset: offset, kind: kind, exit: exit, command: command)
                )
            }
        } catch {
            // Ignore malformed frames; keep session alive.
        }
    }

    /// How a newly wired controller's screen is rebuilt: which bytes to replay,
    /// and whether the client must clear its screen first.
    struct ReplayPlan: Equatable {
        let request: PtySession.ReplayRequest
        let forceResync: Bool
    }

    /// Choose the replay for a controller attach.
    ///
    /// The one case that must not fall through to the offset path is a fresh
    /// shell that was spawned because a requested session was gone (a daemon
    /// restart is the common trigger). The client's `since` offset names the
    /// previous, now-dead stream; replaying `[since, head)` of the *new* shell
    /// would splice a mid-stream slice of its startup onto the client's stale
    /// screen — which is what left input garbled after a restart. Such a spawn
    /// replays the new shell from the start and forces a resync so the client
    /// rebuilds its screen instead of appending to the old one.
    ///
    /// A fresh shell with no reattach request (a brand-new tab) keeps its prior
    /// behaviour: replay from the detach point (offset 0 for a new stream) with
    /// no forced resync, since its terminal is already empty.
    static func resolveReplay(
        freshlySpawned: Bool,
        reattaching: Bool,
        sinceOffset: UInt64?,
        freshClient: Bool
    ) -> ReplayPlan {
        if freshlySpawned {
            return ReplayPlan(request: .fromDetachPoint, forceResync: reattaching)
        }
        // Replay preference: an exact client offset beats the fresh-tail
        // heuristic beats the detach-point gap (old clients, startup).
        if let sinceOffset {
            return ReplayPlan(request: .sinceOffset(sinceOffset), forceResync: false)
        }
        if freshClient && reattaching {
            return ReplayPlan(
                request: .tail(maxBytes: KittermConstants.sessionObserverReplayMaxBytes),
                forceResync: false
            )
        }
        return ReplayPlan(request: .fromDetachPoint, forceResync: false)
    }

    /// Deep-link cwd (`/?cwd=…`): expand `~`, require an existing directory;
    /// anything else falls back to the default (home).
    static func validatedCwd(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if path == "~" {
            path = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        }
        guard path.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return resolved
    }

    /// Per-pane history file for `?hist=<key>`. The key is sanitized to a strict
    /// allowlist so it can never escape `~/.kitterm/history/`; anything invalid
    /// yields nil, and the shell falls back to its own default HISTFILE.
    static func historyFile(for key: String?) -> String? {
        guard let key, !key.isEmpty, key.count <= 128 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard key.allSatisfy(allowed.contains) else { return nil }
        return DaemonPaths.historyDirectory.appendingPathComponent(key).path
    }

    // MARK: - Outbound

    private func sendSessionId(_ id: UUID, context: ChannelHandlerContext) {
        if let encoded = try? ServerFrame.sessionId(id.uuidString).encode() {
            writeBinary(encoded, context: context)
        }
    }

    private func sendRole(_ role: SessionRole, context: ChannelHandlerContext) {
        if let encoded = try? ServerFrame.role(role).encode() {
            writeBinary(encoded, context: context)
        }
    }

    /// Announce the replay window before its bytes: the client learns its
    /// absolute offset, how many replay bytes follow, and whether its screen
    /// state is stale. Old clients drop the unknown opcode harmlessly.
    private func sendLogState(
        resync: Bool,
        snapshot: SessionLog.Snapshot,
        context: ChannelHandlerContext
    ) {
        if let encoded = try? ServerFrame.logState(
            resync: resync,
            offset: snapshot.start,
            replayLen: UInt64(snapshot.data.count)
        ).encode() {
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
        // No `title` frame: the shell name is already in `sessionMeta`, and the
        // client builds its tab title from the custom name plus the cwd. The
        // opcode stays in the protocol so older clients keep decoding.
    }

    private func sendOutput(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
        guard !closed else { return }
        var payload = context.channel.allocator.buffer(capacity: 1 + buffer.readableBytes)
        payload.writeInteger(ServerOpcode.output.rawValue, as: UInt8.self)
        var copy = buffer
        payload.writeBuffer(&copy)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: payload)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        updateBackpressure(context: context)
    }

    private func writeBinary(_ data: Data, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }

    private func updateBackpressure(context: ChannelHandlerContext) {
        // Observers never pause the shared PTY; slow ones are closed via writability.
        guard role == .controller else { return }
        guard !clientPaused else { return }
        if !context.channel.isWritable, !ptyReadPaused {
            pty?.pauseReading()
            ptyReadPaused = true
        } else if context.channel.isWritable, ptyReadPaused, !clientPaused {
            pty?.resumeReading()
            ptyReadPaused = false
        }
    }

    private func applyWriteWatermarks(context: ChannelHandlerContext, role: SessionRole) {
        let mark: ChannelOptions.Types.WriteBufferWaterMark
        switch role {
        case .controller:
            mark = ChannelOptions.Types.WriteBufferWaterMark(
                low: KittermConstants.wsOutboundResumeLowWaterBytes,
                high: KittermConstants.wsOutboundPauseHighWaterBytes
            )
        case .observer:
            mark = ChannelOptions.Types.WriteBufferWaterMark(
                low: KittermConstants.wsBackpressureThresholdBytes - (4 * 1024 * 1024),
                high: KittermConstants.wsBackpressureThresholdBytes
            )
        }
        context.channel.setOption(ChannelOptions.writeBufferWaterMark, value: mark).whenFailure { _ in }
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
        guard !closed else { return }
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
        if role == .observer {
            // Observers never own the session lifecycle.
            if let pty, let sessionID {
                pty.removeObserver(observerID)
                if !ptyExited {
                    Task { await registry.observerLeft(sessionID) }
                }
            }
        } else if let pty, let sessionID {
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
