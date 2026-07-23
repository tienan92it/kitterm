import Darwin
import Foundation
import KittermProtocol
import NIOConcurrencyHelpers
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
/// PTY I/O is driven by an `NIOPipeBootstrap` channel on the daemon event loop,
/// in both directions — NIO retries partial writes that the non-blocking master
/// fd cannot take at once. The master fd itself is kept for `ioctl` and close.
public final class PtySession: @unchecked Sendable {
    public let pid: pid_t
    public let shellPath: String
    public let initialCwd: String
    public private(set) var cols: UInt16
    public private(set) var rows: UInt16

    private let masterFD: Int32
    /// The single domain for every mutable field below. Rules, in order:
    ///
    /// 1. Never invoke a client callback while holding it — snapshot the
    ///    handlers, release, then call. Callbacks re-enter this class
    ///    (`write`, `pauseReading`, …) and the lock is not recursive.
    /// 2. Never block on the event loop while holding it. `terminate` used to
    ///    `wait()` on a channel close here while `write()` entered the lock
    ///    *from* the loop, which deadlocked the daemon.
    ///
    /// Channel methods (`setOption`, `close`) are thread-safe in NIO and hop to
    /// the loop themselves, so they need neither the lock nor a manual hop.
    private let stateLock = NIOLock()
    private var readChannel: Channel?
    private weak var eventLoop: EventLoop?
    private var readingPaused = false
    private var terminated = false
    private var exitNotified = false

    /// While no client is attached (startup gap, transient disconnect),
    /// output accumulates here, bounded by pausing PTY reads at the cap.
    private var detachedBuffer = Data()
    /// Input written before the reader channel exists, flushed on adoption.
    private var pendingInput = Data()
    private var attached = false
    private var onOutput: ((Data) -> Void)?
    private var onExit: ((Int32) -> Void)?
    /// Live cwd tracking: a low-frequency poll of the shell's own directory via
    /// `proc_pidinfo`, so the client learns `cd`s even when the shell emits no
    /// OSC 7 (a bare macOS zsh does not). Diff-gated to one frame per change.
    private var onCwd: ((String) -> Void)?
    private var lastPolledCwd: String?
    private var cwdTask: RepeatedTask?

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
        cwd: String? = nil,
        histFile: String? = nil
    ) throws -> PtySession {
        let shell = resolvedShell()
        let startCwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        // A per-pane HISTFILE lets up-arrow survive a restart with this pane's
        // own commands; seed it once from the shell's global history.
        if let histFile {
            seedHistoryFile(histFile, shell: shell)
        }
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

        // Written to the slave before the shell starts, so it is already in the
        // pty buffer when the first prompt arrives and cannot interleave with
        // it. Going in through the pty (rather than synthesising a frame) means
        // recording, the replay tail, and observers all pick it up unchanged.
        if let banner = LastLogin.banner(forSlave: slave) {
            _ = banner.withCString { ptr in
                Darwin.write(slave, ptr, strlen(ptr))
            }
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

        let envPairs = buildChildEnvironment(histFile: histFile)
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
        let alreadyReading: Bool = stateLock.withLock {
            guard readChannel == nil, !terminated else { return true }
            self.eventLoop = eventLoop
            return false
        }
        guard !alreadyReading else {
            return eventLoop.makeSucceededFuture(())
        }

        let readFD = Darwin.dup(masterFD)
        guard readFD >= 0 else {
            return eventLoop.makeFailedFuture(PtyError.forkFailed(errno: errno))
        }

        let session = self
        return NIOPipeBootstrap(group: group)
            .channelOption(ChannelOptions.autoRead, value: true)
            .channelInitializer { channel in
                channel.pipeline.addHandler(PtyReadHandler(session: session))
            }
            .takingOwnershipOfDescriptor(inputOutput: readFD)
            .map { channel in
                // `terminate()` may have run while the bootstrap was in flight;
                // adopting the channel then would leak it past shutdown.
                let queued: Data? = self.stateLock.withLock { () -> Data? in
                    guard !self.terminated else { return nil }
                    self.readChannel = channel
                    let pending = self.pendingInput
                    self.pendingInput = Data()
                    return pending
                }
                guard let queued else {
                    channel.close(promise: nil)
                    return
                }
                // Input that arrived before the channel existed goes out first,
                // ahead of anything written after adoption.
                if !queued.isEmpty { self.writeToChannel(channel, queued) }
            }
    }

    /// Called on the event loop by `PtyReadHandler`.
    func handleRead(_ buffer: inout ByteBuffer) {
        guard buffer.readableBytes > 0 else { return }
        let chunk = Data(buffer: buffer)

        // Snapshot under the lock, then call out with it released: the output
        // handlers below re-enter this class.
        let dispatch: (recorder: SessionRecorder?,
                       observers: [(Data) -> Void],
                       controller: ((Data) -> Void)?,
                       pause: Bool)? = stateLock.withLock {
            guard !terminated, !readingPaused else { return nil }
            appendRecentOutputLocked(chunk)
            let observerOutputs = observers.values.map(\.onOutput)
            if attached, let onOutput {
                return (recorder, observerOutputs, onOutput, false)
            }
            detachedBuffer.append(chunk)
            let overflow = detachedBuffer.count >= KittermConstants.sessionDetachBufferMaxBytes
            if overflow { readingPaused = true }
            return (recorder, observerOutputs, nil, overflow)
        }
        guard let dispatch else { return }

        dispatch.recorder?.recordOutput(chunk)
        for observer in dispatch.observers {
            observer(chunk)
        }
        dispatch.controller?(chunk)
        if dispatch.pause {
            setChannelAutoRead(false)
        }
    }

    func readChannelClosed() {
        stateLock.withLock { readChannel = nil }
    }

    /// Send input to the shell.
    ///
    /// Writes go through the reader channel rather than straight to the master
    /// fd. The fd is non-blocking, so a large paste fills the PTY buffer and
    /// returns `EAGAIN` part-way; the old direct loop dropped the remainder,
    /// silently truncating input. NIO keeps the unwritten tail and drains it
    /// when the fd is writable again.
    ///
    /// Ordering follows the caller. In the daemon that is a single controller
    /// on one event loop, so input stays in sequence.
    public func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let flush: (channel: Channel, bytes: Data)? = try stateLock.withLock {
            guard !terminated else { throw PtyError.closed }
            pendingInput.append(data)
            // No reader yet: hold the bytes until the channel is adopted. The
            // daemon always calls `makeReader` before wiring a client, so this
            // is the startup gap only.
            guard let channel = readChannel else { return nil }
            let bytes = pendingInput
            pendingInput = Data()
            return (channel, bytes)
        }
        guard let flush else { return }
        writeToChannel(flush.channel, flush.bytes)
    }

    /// Called with the lock released — `writeAndFlush` runs the pipeline inline
    /// when already on the event loop.
    private func writeToChannel(_ channel: Channel, _ bytes: Data) {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func resize(cols: UInt16, rows: UInt16) throws {
        let c = min(max(cols, 1), KittermConstants.maxCols)
        let r = min(max(rows, 1), KittermConstants.maxRows)
        let notify: (recorder: SessionRecorder?, resizes: [(UInt16, UInt16) -> Void]) =
            try stateLock.withLock {
                guard !terminated else { throw PtyError.closed }
                var win = winsize(ws_row: r, ws_col: c, ws_xpixel: 0, ws_ypixel: 0)
                guard ioctl(masterFD, TIOCSWINSZ, &win) == 0 else {
                    throw PtyError.ioctlFailed
                }
                self.cols = c
                self.rows = r
                return (recorder, observers.values.map(\.onResize))
            }
        notify.recorder?.recordResize(cols: c, rows: r)
        for handler in notify.resizes {
            handler(c, r)
        }
    }

    public var isRunning: Bool {
        stateLock.withLock { !terminated }
    }

    public var observerCount: Int {
        stateLock.withLock { observers.count }
    }

    public func addObserver(_ id: UUID, handlers: ObserverHandlers) -> Data {
        stateLock.withLock {
            observers[id] = handlers
            return recentOutput
        }
    }

    public func removeObserver(_ id: UUID) {
        stateLock.withLock { _ = observers.removeValue(forKey: id) }
    }

    func attachRecorder(_ recorder: SessionRecorder) {
        stateLock.withLock { self.recorder = recorder }
    }

    public func attach(
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void,
        onCwd: ((String) -> Void)? = nil,
        replayRecentTail: Bool = false
    ) {
        let resumed: (replay: Data?, wasPaused: Bool) = stateLock.withLock {
            self.onOutput = onOutput
            self.onExit = onExit
            self.onCwd = onCwd
            attached = true
            let pending: Data?
            if replayRecentTail {
                detachedBuffer = Data()
                pending = recentOutput.isEmpty ? nil : recentOutput
            } else if !detachedBuffer.isEmpty {
                pending = detachedBuffer
                detachedBuffer = Data()
            } else {
                pending = nil
            }
            let wasPaused = readingPaused
            readingPaused = false
            return (pending, wasPaused)
        }
        if let replay = resumed.replay { onOutput(replay) }
        if resumed.wasPaused { setChannelAutoRead(true) }
        if onCwd != nil { startCwdPolling() }
    }

    public func detach(onExitWhileDetached: ((Int32) -> Void)? = nil) {
        stopCwdPolling()
        let wasPaused = stateLock.withLock { () -> Bool in
            attached = false
            onOutput = nil
            onExit = onExitWhileDetached
            onCwd = nil
            let paused = readingPaused
            readingPaused = false
            return paused
        }
        if wasPaused { setChannelAutoRead(true) }
    }

    // MARK: - Live cwd polling

    /// Cadence for the cwd poll. 2s is imperceptible for "restore where I was"
    /// while keeping the syscall rate negligible on the shared event loop.
    private static let cwdPollInterval = TimeAmount.seconds(2)

    /// Read the shell process's own working directory. `proc_pidinfo` is a fast
    /// kernel-state read (microseconds), not blocking I/O; returns nil for a
    /// reaped pid or any failure so the caller never throws.
    static func currentDirectory(ofPID pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard rc == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            let cString = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            let path = String(cString: cString)
            return path.isEmpty ? nil : path
        }
    }

    private func startCwdPolling() {
        let alive = stateLock.withLock { !terminated }
        guard alive, let eventLoop, cwdTask == nil else { return }
        lastPolledCwd = initialCwd
        cwdTask = eventLoop.scheduleRepeatedTask(
            initialDelay: Self.cwdPollInterval,
            delay: Self.cwdPollInterval
        ) { [weak self] _ in
            self?.pollCwd()
        }
    }

    private func stopCwdPolling() {
        cwdTask?.cancel()
        cwdTask = nil
    }

    private func pollCwd() {
        guard let path = Self.currentDirectory(ofPID: pid), path != lastPolledCwd else {
            return
        }
        lastPolledCwd = path
        let callback = stateLock.withLock { onCwd }
        callback?(path)
    }

    public func pauseReading() {
        let changed = stateLock.withLock { () -> Bool in
            guard !readingPaused else { return false }
            readingPaused = true
            return true
        }
        if changed { setChannelAutoRead(false) }
    }

    public func resumeReading() {
        let changed = stateLock.withLock { () -> Bool in
            guard readingPaused else { return false }
            readingPaused = false
            return true
        }
        if changed { setChannelAutoRead(true) }
    }

    /// Channel options are thread-safe and hop to the loop internally, so this
    /// is called with the lock released.
    private func setChannelAutoRead(_ enabled: Bool) {
        let channel = stateLock.withLock { readChannel }
        channel?.setOption(ChannelOptions.autoRead, value: enabled).whenFailure { _ in }
    }

    private func appendRecentOutputLocked(_ chunk: Data) {
        recentOutput.append(chunk)
        let cap = KittermConstants.sessionObserverReplayMaxBytes
        if recentOutput.count > cap {
            recentOutput = Data(recentOutput.suffix(cap))
        }
    }

    public func terminate() {
        stopCwdPolling()
        // Everything that can block — closing the channel, signalling the child
        // — happens after the lock is released. Waiting on the event loop while
        // holding it deadlocks against `write()`, which the loop itself calls.
        let shutdown: (channel: Channel?, recorder: SessionRecorder?)? = stateLock.withLock {
            guard !terminated else { return nil }
            terminated = true
            let channel = readChannel
            let recorder = self.recorder
            self.readChannel = nil
            self.recorder = nil
            // The shell is going away; undelivered input has nowhere to go.
            pendingInput = Data()
            _ = Darwin.close(masterFD)
            return (channel, recorder)
        }
        guard let shutdown else { return }

        shutdown.recorder?.close()
        // Thread-safe and non-blocking: NIO hops to the loop itself.
        shutdown.channel?.close(promise: nil)
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
            // Deliver on the event loop so exit cannot overtake output that is
            // still queued there; fall back to direct delivery pre-reader.
            let loop = self.stateLock.withLock { self.eventLoop }
            if let loop {
                loop.execute { self.deliverExit(code) }
            } else {
                self.deliverExit(code)
            }
        }
    }

    private func deliverExit(_ code: Int32) {
        let handlers: (controller: ((Int32) -> Void)?, observers: [(Int32) -> Void])? =
            stateLock.withLock {
                guard !exitNotified else { return nil }
                exitNotified = true
                return (onExit, observers.values.map(\.onExit))
            }
        guard let handlers else { return }
        handlers.controller?(code)
        for observerExit in handlers.observers {
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

    private static func buildChildEnvironment(histFile: String? = nil) -> [String] {
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
        // zsh and bash both honour HISTFILE; fish keeps its own db and ignores it.
        if let histFile {
            env["HISTFILE"] = histFile
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Copy the shell's global history into a fresh per-pane file so up-arrow
    /// still shows prior commands. Only on first creation — a restored pane's
    /// file already holds its own accumulated history.
    static func seedHistoryFile(_ path: String, shell: String) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !fm.fileExists(atPath: path) else { return }

        let home = fm.homeDirectoryForCurrentUser
        let globalName = shell.hasSuffix("bash") ? ".bash_history" : ".zsh_history"
        let global = home.appendingPathComponent(globalName)
        if fm.fileExists(atPath: global.path) {
            try? fm.copyItem(at: global, to: URL(fileURLWithPath: path))
        } else {
            fm.createFile(atPath: path, contents: nil)
        }
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
