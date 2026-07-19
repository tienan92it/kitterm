import Darwin
import Foundation
import KittermProtocol

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
public final class PtySession: @unchecked Sendable {
    public let pid: pid_t
    public let shellPath: String
    public let initialCwd: String
    public private(set) var cols: UInt16
    public private(set) var rows: UInt16

    private let masterFD: Int32
    private let syncQueue = DispatchQueue(label: "kitterm.pty.sync")
    private var readSource: DispatchSourceRead?
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
            // Parent keeps master; always close slave here.
            _ = Darwin.close(slave)
        }

        // New session so the helper can acquire a controlling terminal.
        // CLOEXEC_DEFAULT: children must not inherit daemon FDs (notably the
        // listening socket — it would keep the port bound after daemon exit).
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

        // helper <cwd> <shellPath> <argv0>
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

        // Non-blocking master for DispatchSource reads.
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
        session.startReader()
        session.startExitWatcher()
        return session
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
            for (_, observer) in observers {
                observer.onResize(c, r)
            }
        }
    }

    public var isRunning: Bool {
        syncQueue.sync { !terminated }
    }

    public var observerCount: Int {
        syncQueue.sync { observers.count }
    }

    /// Join as a read-only mirror. Returns the recent-output tail for replay.
    public func addObserver(_ id: UUID, handlers: ObserverHandlers) -> Data {
        syncQueue.sync {
            observers[id] = handlers
            return recentOutput
        }
    }

    public func removeObserver(_ id: UUID) {
        syncQueue.sync {
            observers.removeValue(forKey: id)
        }
    }

    func attachRecorder(_ recorder: SessionRecorder) {
        syncQueue.sync {
            self.recorder = recorder
        }
    }

    /// Wire a client to this session and stream live output.
    ///
    /// Replay: a client that kept its screen (same-page reconnect) gets exactly
    /// the bytes missed while detached. A fresh page (reload, adopted session
    /// link) has no screen state, so it gets the recent-output tail instead —
    /// otherwise an idle shell shows nothing until the user presses Enter.
    public func attach(
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void,
        replayRecentTail: Bool = false
    ) {
        syncQueue.sync {
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
            resumeReadingLocked()
        }
    }

    /// Disconnect the client but keep the shell alive; output buffers until
    /// the next `attach` (bounded — reads pause at the cap).
    public func detach(onExitWhileDetached: ((Int32) -> Void)? = nil) {
        syncQueue.sync {
            attached = false
            onOutput = nil
            onExit = onExitWhileDetached
            // A client-requested pause must not outlive the client.
            resumeReadingLocked()
        }
    }

    public func pauseReading() {
        syncQueue.sync { pauseReadingLocked() }
    }

    public func resumeReading() {
        syncQueue.sync { resumeReadingLocked() }
    }

    private func pauseReadingLocked() {
        guard !readingPaused, let source = readSource else { return }
        readingPaused = true
        source.suspend()
    }

    private func resumeReadingLocked() {
        guard readingPaused, let source = readSource else { return }
        readingPaused = false
        source.resume()
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
            if let source = readSource {
                if readingPaused {
                    source.resume()
                }
                source.cancel()
                readSource = nil
            }
            _ = Darwin.close(masterFD)
            // Kill the whole session process group (shell + kubectl children).
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

    private func startReader() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: syncQueue)
        source.setEventHandler { [weak self] in
            self?.drainAvailable()
        }
        readSource = source
        source.resume()
    }

    private func drainAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !terminated {
            let n = Darwin.read(masterFD, &buffer, buffer.count)
            if n > 0 {
                let chunk = Data(buffer[0..<Int(n)])
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
                        pauseReadingLocked()
                        return
                    }
                }
                continue
            }
            if n == 0 {
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return
            }
            return
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
            // Deliver on the session queue — the daemon's main thread blocks
            // in closeFuture.wait() and never services the main queue, so
            // DispatchQueue.main would silently drop this.
            guard let self else { return }
            self.syncQueue.async {
                guard !self.exitNotified else { return }
                self.exitNotified = true
                let handler = self.onExit
                let observerExits = self.observers.values.map { $0.onExit }
                handler?(code)
                for observerExit in observerExits {
                    observerExit(code)
                }
            }
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
