import Foundation
import KittermProtocol
import NIOCore
import NIOWebSocket

final class WebSocketSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let registry: SessionRegistry
    /// Loop-confined control-transfer coordinator, shared by all handlers.
    private let handoff: ControlHandoff
    private let reattachID: UUID?
    private let requestedCwd: String?
    /// Selects this pane's own history file; nil falls back to the shell default.
    private let histKey: String?
    /// Named session profile (`?profile=`): a fresh spawn runs the profile's
    /// connect command as initial input. Ignored on reattach — a live session
    /// already ran it.
    private let profileName: String?
    /// Orchestrator tags for a fresh spawn; ignored on reattach, where the
    /// session already carries whatever it was created with.
    private let labels: SessionLabels
    /// Client page has no screen state (reload / adopted link) — reattach
    /// replays the recent tail instead of only the detached bytes.
    private let freshClient: Bool
    /// The client's count of output bytes it already has (`?since=`); the
    /// daemon replays exactly the gap after it. Takes precedence over `fresh`.
    private let sinceOffset: UInt64?
    private let recordSessions: Bool
    private let retainLogs: Bool
    /// Watch-grade auth: this connection may only observe an existing session
    /// — never claim control, never take over, never spawn a shell.
    private let watchOnly: Bool
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
        handoff: ControlHandoff = ControlHandoff(),
        reattachID: UUID? = nil,
        requestedCwd: String? = nil,
        freshClient: Bool = false,
        histKey: String? = nil,
        profileName: String? = nil,
        labels: SessionLabels = SessionLabels(),
        sinceOffset: UInt64? = nil,
        recordSessions: Bool = false,
        retainLogs: Bool = false,
        watchOnly: Bool = false,
        eventLoopGroup: EventLoopGroup
    ) {
        self.registry = registry
        self.handoff = handoff
        self.reattachID = reattachID
        self.requestedCwd = requestedCwd
        self.freshClient = freshClient
        self.histKey = histKey
        self.profileName = profileName
        self.labels = labels
        self.sinceOffset = sinceOffset
        self.recordSessions = recordSessions
        self.retainLogs = retainLogs
        self.watchOnly = watchOnly
        self.eventLoopGroup = eventLoopGroup
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if watchOnly {
            // Watch grade: observe an existing session or nothing. This path
            // never claims control and never reaches spawnNew.
            guard let reattachID else {
                closePolicy(context: context, reason: "watch-only access needs a session link")
                return
            }
            let registry = self.registry
            let promise = context.eventLoop.makePromise(of: PtySession?.self)
            promise.completeWithTask { await registry.observe(reattachID) }
            promise.futureResult.whenSuccess { [weak self] session in
                guard let self, !self.closed else { return }
                guard let session else {
                    self.closePolicy(context: context, reason: "session unavailable")
                    return
                }
                self.adoptAsObserver(session: session, id: reattachID, context: context)
            }
            return
        }
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
        registerAsController(context: context)
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

        let replay = session.addObserver(observerID, handlers: observerHandlers(context: context))
        sendLogState(resync: true, snapshot: replay, context: context)
        if !replay.data.isEmpty {
            batcher.append(replay.data)
        }
        startHeartbeat(context: context)
        pendingClientFrames = []
    }

    private func spawnNew(context: ChannelHandlerContext) {
        // The query names a profile; the command comes only from the user's
        // profiles.json. An unknown name closes loudly rather than silently
        // spawning a plain shell the client believes is the profile.
        var profile: SessionProfile?
        if let profileName {
            guard let found = SessionProfiles.find(profileName) else {
                closePolicy(context: context, reason: "unknown profile: \(profileName)")
                return
            }
            profile = found
        }
        do {
            let session = try PtySession.spawn(
                cwd: Self.validatedCwd(requestedCwd) ?? Self.validatedCwd(profile?.cwd),
                histFile: Self.historyFile(for: histKey),
                profileName: profile?.name,
                labels: labels
            )
            // Queued as type-ahead: it flushes when the reader channel adopts
            // the PTY and the shell executes it at its first read — visible,
            // echoed, and in this pane's history like a typed command. Ahead
            // of any queued client frames, which are handled after wire().
            if let profile {
                try? session.write(Data((profile.command + "\n").utf8))
            }
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
            let reader = session.makeReader(group: eventLoopGroup, eventLoop: context.eventLoop)
            let setup = reader.flatMap { () -> EventLoopFuture<UUID?> in
                let idPromise = context.eventLoop.makePromise(of: UUID?.self)
                idPromise.completeWithTask { await registry.register(session) }
                return idPromise.futureResult
            }
            setup.whenFailure { [weak self, weak context] error in
                guard let self, let context else { return }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                FileHandle.standardError.write(Data("kitterm: \(reason)\n".utf8))
                self.closePolicy(context: context, reason: reason)
            }
            setup.whenSuccess { [weak self, weak context] registered in
                // Refused: the daemon is at its session ceiling. The shell was
                // spawned to make the check atomic, so it has to go back.
                guard let id = registered else {
                    session.terminate()
                    if let self, let context {
                        self.closePolicy(
                            context: context,
                            reason: """
                                too many sessions open \
                                (limit \(KittermConstants.maxConcurrentSessions)); \
                                close one or delete an idle session
                                """
                        )
                    }
                    return
                }
                guard let self, let context, !self.closed else {
                    Task { await registry.remove(id) }
                    return
                }
                self.sessionID = id
                if self.retainLogs {
                    session.attachLogStore { origin in
                        SessionLogStore(
                            directory: DaemonPaths.logsDirectory,
                            sessionID: id,
                            maxBytes: KittermConstants.retainedLogBytes,
                            origin: origin
                        )
                    }
                }
                self.sendSessionId(id, context: context)
                self.sendRole(.controller, context: context)
                self.sendMeta(context: context, session: session)
                self.wire(session: session, context: context)
                self.registerAsController(context: context)
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "pty spawn failed"
            FileHandle.standardError.write(Data("kitterm: \(reason)\n".utf8))
            closePolicy(context: context, reason: reason)
        }
    }

    private func wire(session: PtySession, context: ChannelHandlerContext) {
        applyWriteWatermarks(context: context, role: .controller)
        let batcher = OutputBatcher(eventLoop: context.eventLoop) { [weak self, weak context] buffer in
            guard let self, let context else { return }
            self.sendOutput(buffer, context: context)
        }
        self.batcher = batcher

        // Replay preference: an exact client offset beats the fresh-tail
        // heuristic beats the detach-point gap (old clients, startup).
        let replay: PtySession.ReplayRequest
        if let sinceOffset {
            replay = .sinceOffset(sinceOffset)
        } else if freshClient && reattachID != nil {
            replay = .tail(maxBytes: KittermConstants.sessionObserverReplayMaxBytes)
        } else {
            replay = .fromDetachPoint
        }
        let isTail = if case .tail = replay { true } else { false }
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
            replay: replay
        )
        // A tail replay lands on a screen that never saw the earlier bytes,
        // so it needs the same reset a pruned offset does.
        sendLogState(resync: snapshot.pruned || isTail, snapshot: snapshot, context: context)
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
        // Observers are read-only: their input never reaches the PTY. The one
        // frame an observer may send is requestControl — take over the session.
        // Watch-grade connections don't even get that: enforcement lives here,
        // not in the client's hidden button.
        guard role == .controller else {
            if !watchOnly, (try? ClientFrame.decode(data)) == .requestControl {
                takeControl(context: context)
            }
            return
        }
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
            case .mark:
                // Ignored: the daemon reads marks out of the PTY stream itself
                // (`OscMarkScanner`), so a session nobody is watching still has
                // an index. Accepting these too would double every mark for an
                // older client that is still reporting them, and the daemon's
                // own offsets are the more accurate of the two.
                break
            case .requestControl:
                break // controller already; only observers transfer (below)
            }
        } catch {
            // Ignore malformed frames; keep session alive.
        }
    }

    // MARK: - Control handoff
    //
    // The whole swap runs inside one event-loop tick: take the current
    // controller's step-down closure, run it (detach → observe, role frame),
    // then promote this connection (stop observing → attach with no replay,
    // role frame). Handlers and the PTY reader share the single event-loop
    // thread, so no output, input, or exit can interleave mid-swap — which is
    // what keeps this outside PtySession's documented deadlock territory: it
    // is only the existing detach/attach/addObserver/removeObserver calls in
    // a new order, never a new lock or a blocking wait.

    /// An observer becomes the controller (client opcode 5).
    private func takeControl(context: ChannelHandlerContext) {
        guard !closed, role == .observer, pty != nil, let sessionID else { return }
        // Nil when the previous controller already disconnected — the session
        // is detached and plain attach below is the normal adopt path.
        let stepDown = handoff.takeStepDown(sessionID)
        stepDown?()
        promoteToController(context: context)
    }

    /// This connection stops controlling and becomes a read-only mirror.
    /// Invoked synchronously (same tick) by the requester via `ControlHandoff`.
    private func stepDownToObserver(context: ChannelHandlerContext) {
        guard !closed, role == .controller, let pty else { return }
        role = .observer
        // A pause the old controller had in force must not outlive its rule.
        clientPaused = false
        ptyReadPaused = false
        pty.detach()
        // Discard the returned tail replay: this screen is already current.
        _ = pty.addObserver(observerID, handlers: observerHandlers(context: context))
        applyWriteWatermarks(context: context, role: .observer)
        sendRole(.observer, context: context)
    }

    private func promoteToController(context: ChannelHandlerContext) {
        guard !closed, role == .observer, let pty, let sessionID else { return }
        pty.removeObserver(observerID)
        role = .controller
        applyWriteWatermarks(context: context, role: .controller)
        // No replay: this connection observed every byte live, so it attaches
        // at the head. Nothing can land between reading logHead and attach —
        // the PTY reader runs on this same thread.
        let snapshot = pty.attach(
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
            replay: .sinceOffset(pty.logHead)
        )
        // Empty replay, but the frame still re-anchors the client's offset.
        sendLogState(resync: false, snapshot: snapshot, context: context)
        sendRole(.controller, context: context)
        registerAsController(context: context)
        // Attached/linger bookkeeping catches up asynchronously — but in
        // enqueue order, so a markDetached from a moments-earlier teardown
        // can never land on top of this claim.
        let registry = registry
        handoff.enqueueBookkeeping { await registry.claimControl(sessionID) }
        updateBackpressure(context: context)
    }

    private func registerAsController(context: ChannelHandlerContext) {
        guard let sessionID else { return }
        handoff.setController(sessionID) { [weak self, weak context] in
            guard let self, let context else { return }
            self.stepDownToObserver(context: context)
        }
    }

    private func observerHandlers(context: ChannelHandlerContext) -> PtySession.ObserverHandlers {
        PtySession.ObserverHandlers(
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

        // Registry calls go through the bookkeeping chain so they apply in
        // event-loop order — a takeover's claimControl moments later must not
        // be overtaken by this teardown's markDetached.
        let registry = registry
        if role == .observer {
            // Observers never own the session lifecycle.
            if let pty, let sessionID {
                pty.removeObserver(observerID)
                if !ptyExited {
                    handoff.enqueueBookkeeping { await registry.observerLeft(sessionID) }
                }
            }
        } else if let pty, let sessionID {
            handoff.clearController(sessionID)
            if ptyExited {
                pty.terminate()
                handoff.enqueueBookkeeping { await registry.sessionDidExit(sessionID) }
            } else {
                pty.detach(onExitWhileDetached: { _ in
                    Task { await registry.sessionDidExit(sessionID) }
                })
                handoff.enqueueBookkeeping { await registry.markDetached(sessionID) }
            }
        } else if let pty {
            // Never registered (spawn raced teardown) — kill it.
            pty.terminate()
        }
        pty = nil
        sessionID = nil
    }
}
