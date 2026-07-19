import Darwin
import Foundation
import KittermProtocol
import NIOCore
import NIOPosix

public enum PtyError: Error, LocalizedError {
    case forkFailed(errno: Int32)
    case ioctlFailed
    case closed

    public var errorDescription: String? {
        switch self {
        case .forkFailed(let code):
            return "pty spawn failed errno=\(code) (\(String(cString: strerror(code))))"
        case .ioctlFailed: return "PTY ioctl failed"
        case .closed: return "PTY is closed"
        }
    }
}

/// One login-shell PTY with one controller and any number of observers.
///
/// Uses `openpty` + `posix_spawn` of `kitterm-spawn-helper` (not `forkpty`) so
/// spawning stays safe inside the multi-threaded NIO daemon. The helper acquires
/// a controlling TTY (`TIOCSCTTY`) so ISIG delivers SIGINT on Ctrl+C / VINTR.
///
/// PTY reads are driven by an `NIOPipeBootstrap` channel on the daemon event
/// loop; the master fd is kept for writes and `ioctl`.
public final class PtySession: @unchecked Sendable {
    public let pid: pid_t
    public let shellPath: String
    public let initialCwd: String
    public private(set) var cols: UInt16
    public private(set) var rows: UInt16

    private let masterFD: Int32
    private let syncQueue = DispatchQueue(label: "kitterm.pty.sync")
    private var readChannel: Channel?
    private weak var eventLoop: EventLoop?
    private var readingPaused = false
    private var terminated = false
    private var exitNotified = false

    /// While no client is attached (startup gap, transient disconnect),
    /// output accumulates here, bounded by pausing PTY reads at the cap.
    private var detachedBuffer = Data()
    private var attached = false
    private var onOutput: ((Data) -> Void)?
    private var onExit: ((Int32) -> Void)?

    public struct ObserverHandlers {
        let onOutput: (Data) -> Void
        let onExit: (Int32) -> Void
        let onResize: (UInt16, UInt16) -> Void

        public init(
            onOutput: @escaping (Data) -> Void,
            onExit: @escaping (Int32) -> Void,
            onResize: @escaping (UInt16, UInt16) -> Void
        ) {
            self.onOutput = onOutput
            self.onExit = onExit
            self.onResize = onResize
        }
    }

    /// Read-only mirrors of this session (observer mode).
    private var observers: [UUID: ObserverHandlers] = [:]
    /// Rolling tail of recent output, replayed to observers when they join.
    private var recentOutput = Data()
    /// Optional asciinema recorder (daemon `--record`).
    private var recorder: SessionRecorder?

    private init(
        pid: pid_t,
        masterFD: Int32,
        shellPath: String,
        initialCwd: String,
        cols: UInt16,
        rows: UInt16
    ) {
        self.pid = pid
        self.masterFD = masterFD
        self.shellPath = shellPath
        self.initialCwd = initialCwd
        self.cols = cols
        self.rows = rows
    }

    deinit {
        terminate()
    }

    public static func spawn(
        cols: UInt16 = KittermConstants.defaultCols,
        rows: UInt16 = KittermConstants.defaultRows,
        cwd: String? = nil
    ) throws -> PtySession {
        let shell = resolvedShell()
        let startCwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        var win = winsize(
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var master: Int32 = -1
        var slave: Int32 = -1
        errno = 0
        guard openpty(&master, &slave, nil, nil, &win) == 0, master >= 0, slave >= 0 else {
            throw PtyError.forkFailed(errno: errno)
        }

        var attrs: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attrs) == 0 else {
            _ = Darwin.close(master)
            _ = Darwin.close(slave)
            throw PtyError.forkFailed(errno: errno)
        }
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            posix_spawnattr_destroy(&attrs)
            _ = Darwin.close(master)
            _ = Darwin.close(slave)
            throw PtyError.forkFailed(errno: errno)
        }
        defer {
            posix_spawnattr_destroy(&attrs)
            posix_spawn_file_actions_destroy(&actions)
            _ = Darwin.close(slave)
        }

        posix_spawnattr_setflags(
            &attrs,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        if master != STDIN_FILENO && master != STDOUT_FILENO && master != STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, master)
        }
        if slave != STDIN_FILENO && slave != STDOUT_FILENO && slave != STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, slave)
        }

        let helperPath = try SpawnHelperPath.resolve()
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let argv0 = "-" + shellName

        func dupCString(_ string: String) -> UnsafeMutablePointer<CChar> {
            string.withCString { strdup($0)! }
        }
        let helperPtrs: [UnsafeMutablePointer<CChar>?] = [
            dupCString(helperPath),
            dupCString(startCwd),
            dupCString(shell),
            dupCString(argv0),
        ]
        defer {
            for ptr in helperPtrs where ptr != nil {
                free(ptr)
            }
        }
        var argv: [UnsafeMutablePointer<CChar>?] = helperPtrs
        argv.append(nil)

        let envPairs = buildChildEnvironment()
        var envPointers: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup($0) }
        envPointers.append(nil)
        defer {
            for ptr in envPointers where ptr != nil {
                free(ptr)
            }
        }

        var childPid: pid_t = 0
        let spawnRC = helperPath.withCString { path in
            posix_spawn(&childPid, path, &actions, &attrs, &argv, &envPointers)
        }
        guard spawnRC == 0, childPid > 0 else {
            _ = Darwin.close(master)
            throw PtyError.forkFailed(errno: spawnRC == 0 ? errno : spawnRC)
        }

        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let session = PtySession(
            pid: childPid,
            masterFD: master,
            shellPath: shell,
            initialCwd: startCwd,
            cols: cols,
            rows: rows
        )
        session.startExitWatcher()
        return session
    }

    /// Register the PTY master fd with the NIO event loop for reads.
    func makeReader(group: EventLoopGroup, eventLoop: EventLoop) -> EventLoopFuture<Void> {
        if eventLoop.inEventLoop {
            return makeReaderOnEventLoop(group: group, eventLoop: eventLoop)
        }
        return eventLoop.flatSubmit {
            self.makeReaderOnEventLoop(group: group, eventLoop: eventLoop)
        }
    }

    private func makeReaderOnEventLoop(group: EventLoopGroup, eventLoop: EventLoop) -> EventLoopFuture<Void> {
        eventLoop.preconditionInEventLoop()
        guard readChannel == nil, !terminated else {
            return eventLoop.makeSucceededFuture(())
        }

        let readFD = Darwin.dup(masterFD)
        guard readFD >= 0 else {
            return eventLoop.makeFailedFuture(PtyError.forkFailed(errno: errno))
        }

        self.eventLoop = eventLoop
        let session = self
        return NIOPipeBootstrap(group: group)
            .channelOption(ChannelOptions.autoRead, value: true)
            .channelInitializer { channel in
                channel.pipeline.addHandler(PtyReadHandler(session: session))
            }
            .takingOwnershipOfDescriptor(inputOutput: readFD)
            .map { channel in
                self.readChannel = channel
            }
    }

    /// Called on the event loop by `PtyReadHandler`.
    func handleRead(_ buffer: inout ByteBuffer) {
        guard let eventLoop, eventLoop.inEventLoop else { return }
        guard !terminated, !readingPaused else { return }
        guard buffer.readableBytes > 0 else { return }

        let chunk = Data(buffer: buffer)
        appendRecentOutputLocked(chunk)
        recorder?.recordOutput(chunk)
        for (_, observer) in observers {
            observer.onOutput(chunk)
        }
        if attached, let onOutput {
            onOutput(chunk)
        } else {
            detachedBuffer.append(chunk)
            if detachedBuffer.count >= KittermConstants.sessionDetachBufferMaxBytes {
                pauseReadingOnEventLoop()
            }
        }
    }

    func readChannelClosed() {
        guard let eventLoop else { return }
        eventLoop.execute {
            self.readChannel = nil
        }
    }

    public func write(_ data: Data) throws {
        try syncQueue.sync {
            guard !terminated else { throw PtyError.closed }
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < data.count {
                    let n = Darwin.write(masterFD, base.advanced(by: written), data.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN { return }
                        throw PtyError.closed
                    }
                    written += Int(n)
                }
            }
        }
    }

    public func resize(cols: UInt16, rows: UInt16) throws {
        let c = min(max(cols, 1), KittermConstants.maxCols)
        let r = min(max(rows, 1), KittermConstants.maxRows)
        try syncQueue.sync {
            guard !terminated else { throw PtyError.closed }
            var win = winsize(ws_row: r, ws_col: c, ws_xpixel: 0, ws_ypixel: 0)
            guard ioctl(masterFD, TIOCSWINSZ, &win) == 0 else {
                throw PtyError.ioctlFailed
            }
            self.cols = c
            self.rows = r
            recorder?.recordResize(cols: c, rows: r)
            let observerResizes = observers.values.map { ($0.onResize, c, r) }
            if let eventLoop {
                eventLoop.execute {
                    for (handler, cols, rows) in observerResizes {
                        handler(cols, rows)
                    }
                }
            } else {
                for (handler, cols, rows) in observerResizes {
                    handler(cols, rows)
                }
            }
        }
    }

    public var isRunning: Bool {
        syncQueue.sync { !terminated }
    }

    public var observerCount: Int {
        syncQueue.sync { observers.count }
    }

    public func addObserver(_ id: UUID, handlers: ObserverHandlers) -> Data {
        if let eventLoop {
            if eventLoop.inEventLoop {
                observers[id] = handlers
                return recentOutput
            }
            do {
                return try eventLoop.submit {
                    self.observers[id] = handlers
                    return self.recentOutput
                }.wait()
            } catch {
                return syncQueue.sync {
                    observers[id] = handlers
                    return recentOutput
                }
            }
        }
        return syncQueue.sync {
            observers[id] = handlers
            return recentOutput
        }
    }

    public func removeObserver(_ id: UUID) {
        if let eventLoop {
            eventLoop.execute {
                self.observers.removeValue(forKey: id)
            }
        } else {
            syncQueue.sync {
                observers.removeValue(forKey: id)
            }
        }
    }

    func attachRecorder(_ recorder: SessionRecorder) {
        if let eventLoop {
            eventLoop.execute {
                self.recorder = recorder
            }
        } else {
            syncQueue.sync {
                self.recorder = recorder
            }
        }
    }

    public func attach(
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void,
        replayRecentTail: Bool = false
    ) {
        if let eventLoop {
            eventLoop.execute {
                self.attachLocked(
                    onOutput: onOutput,
                    onExit: onExit,
                    replayRecentTail: replayRecentTail
                )
            }
        } else {
            syncQueue.sync {
                attachLocked(
                    onOutput: onOutput,
                    onExit: onExit,
                    replayRecentTail: replayRecentTail
                )
            }
        }
    }

    private func attachLocked(
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void,
        replayRecentTail: Bool
    ) {
        if let eventLoop {
            eventLoop.preconditionInEventLoop()
        }
        self.onOutput = onOutput
        self.onExit = onExit
        attached = true
        if replayRecentTail {
            detachedBuffer = Data()
            if !recentOutput.isEmpty {
                onOutput(recentOutput)
            }
        } else if !detachedBuffer.isEmpty {
            let replay = detachedBuffer
            detachedBuffer = Data()
            onOutput(replay)
        }
        resumeReadingOnEventLoop()
    }

    public func detach(onExitWhileDetached: ((Int32) -> Void)? = nil) {
        if let eventLoop {
            eventLoop.execute {
                self.detachLocked(onExitWhileDetached: onExitWhileDetached)
            }
        } else {
            syncQueue.sync {
                detachLocked(onExitWhileDetached: onExitWhileDetached)
            }
        }
    }

    private func detachLocked(onExitWhileDetached: ((Int32) -> Void)?) {
        if let eventLoop {
            eventLoop.preconditionInEventLoop()
        }
        attached = false
        onOutput = nil
        onExit = onExitWhileDetached
        resumeReadingOnEventLoop()
    }

    public func pauseReading() {
        if let eventLoop {
            eventLoop.execute {
                self.pauseReadingOnEventLoop()
            }
        } else {
            syncQueue.sync { pauseReadingOnEventLoop() }
        }
    }

    public func resumeReading() {
        if let eventLoop {
            eventLoop.execute {
                self.resumeReadingOnEventLoop()
            }
        } else {
            syncQueue.sync { resumeReadingOnEventLoop() }
        }
    }

    private func pauseReadingOnEventLoop() {
        if let eventLoop {
            eventLoop.preconditionInEventLoop()
        }
        guard !readingPaused else { return }
        readingPaused = true
        readChannel?.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
    }

    private func resumeReadingOnEventLoop() {
        if let eventLoop {
            eventLoop.preconditionInEventLoop()
        }
        guard readingPaused else { return }
        readingPaused = false
        readChannel?.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
    }

    private func appendRecentOutputLocked(_ chunk: Data) {
        recentOutput.append(chunk)
        let cap = KittermConstants.sessionObserverReplayMaxBytes
        if recentOutput.count > cap {
            recentOutput = Data(recentOutput.suffix(cap))
        }
    }

    public func terminate() {
        syncQueue.sync {
            guard !terminated else { return }
            terminated = true
            recorder?.close()
            recorder = nil
            if let channel = readChannel, let eventLoop {
                if eventLoop.inEventLoop {
                    channel.close(promise: nil)
                } else {
                    try? eventLoop.flatSubmit {
                        channel.close()
                    }.wait()
                }
            }
            readChannel = nil
            _ = Darwin.close(masterFD)
            if kill(pid, 0) == 0 {
                kill(-pid, SIGHUP)
                let child = pid
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if kill(child, 0) == 0 {
                        kill(-child, SIGKILL)
                    }
                }
            }
        }
    }

    private func startExitWatcher() {
        let watchedPid = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            let waited = waitpid(watchedPid, &status, 0)
            guard waited == watchedPid else { return }
            let code: Int32
            if _WSTATUS(status) == 0 {
                code = (status >> 8) & 0xff
            } else if (((status & 0x7f) + 1) >> 1) > 0 {
                code = 128 + (status & 0x7f)
            } else {
                code = -1
            }
            guard let self else { return }
            if let eventLoop = self.eventLoop {
                eventLoop.execute {
                    self.deliverExit(code)
                }
            } else {
                self.syncQueue.async {
                    self.deliverExit(code)
                }
            }
        }
    }

    private func deliverExit(_ code: Int32) {
        if let eventLoop {
            eventLoop.preconditionInEventLoop()
        }
        guard !exitNotified else { return }
        exitNotified = true
        let handler = onExit
        let observerExits = observers.values.map(\.onExit)
        handler?(code)
        for observerExit in observerExits {
            observerExit(code)
        }
    }

    private static func resolvedShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty,
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        for candidate in ["/bin/zsh", "/bin/bash", KittermConstants.defaultShellFallback] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return KittermConstants.defaultShellFallback
    }

    private static func buildChildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        for key in KittermConstants.ptyEnvDenylist {
            env.removeValue(forKey: key)
        }
        env["TERM"] = KittermConstants.termType
        env["COLORTERM"] = KittermConstants.colortermValue
        env["KITTERM_DAEMON_CHILD"] = "1"
        if env["CLICOLOR"] == nil {
            env["CLICOLOR"] = KittermConstants.clicolorDefault
        }
        if env["LSCOLORS"] == nil {
            env["LSCOLORS"] = KittermConstants.lscolorsDefault
        }
        return env.map { "\($0.key)=\($0.value)" }
    }
}

private func _WSTATUS(_ status: Int32) -> Int32 {
    status & 0x7f
}

private extension Data {
    init(buffer: ByteBuffer) {
        self = buffer.withUnsafeReadableBytes { raw in
            Data(raw)
        }
    }
}
