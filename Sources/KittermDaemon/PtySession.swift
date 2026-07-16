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

/// One login-shell PTY. Kill on session teardown (WS close).
///
/// Uses `openpty` + `posix_spawn` (not `forkpty`) so spawning stays safe inside the
/// multi-threaded NIO daemon process.
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

    public var onOutput: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

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

        // New session so the PTY can become the controlling terminal.
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID))

        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        if master != STDIN_FILENO && master != STDOUT_FILENO && master != STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, master)
        }
        if slave != STDIN_FILENO && slave != STDOUT_FILENO && slave != STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, slave)
        }
        // macOS extension — set child cwd without fork/chdir races.
        let chdirRC = startCwd.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        guard chdirRC == 0 else {
            _ = Darwin.close(master)
            throw PtyError.forkFailed(errno: chdirRC)
        }

        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let argv0 = "-" + shellName
        let argv0Ptr = strdup(argv0)
        defer { free(argv0Ptr) }
        var argv: [UnsafeMutablePointer<CChar>?] = [argv0Ptr, nil]

        let envPairs = buildChildEnvironment()
        var envPointers: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup($0) }
        envPointers.append(nil)
        defer {
            for ptr in envPointers where ptr != nil {
                free(ptr)
            }
        }

        var childPid: pid_t = 0
        let spawnRC = shell.withCString { path in
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
        }
    }

    public func pauseReading() {
        syncQueue.sync {
            guard !readingPaused, let source = readSource else { return }
            readingPaused = true
            source.suspend()
        }
    }

    public func resumeReading() {
        syncQueue.sync {
            guard readingPaused, let source = readSource else { return }
            readingPaused = false
            source.resume()
        }
    }

    public func terminate() {
        syncQueue.sync {
            guard !terminated else { return }
            terminated = true
            if let source = readSource {
                if readingPaused {
                    source.resume()
                }
                source.cancel()
                readSource = nil
            }
            _ = Darwin.close(masterFD)
            if kill(pid, 0) == 0 {
                kill(pid, SIGHUP)
                let child = pid
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if kill(child, 0) == 0 {
                        kill(child, SIGKILL)
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
                onOutput?(chunk)
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
            DispatchQueue.main.async {
                guard let self, !self.exitNotified else { return }
                self.exitNotified = true
                self.onExit?(code)
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
