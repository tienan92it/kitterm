#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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
    /// Name of the session profile this shell was started from, if any.
    /// Metadata only (fleet view); the profile's command was injected as
    /// initial input by the spawner.
    public let profileName: String?
    /// Orchestrator tags (`?label=run:abc,node:build`). Their presence also
    /// means a program created this session, which the registry uses to decide
    /// how long to hold it after its client goes away.
    public let labels: SessionLabels
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
    /// How the shell exited, once it has. Readable after the shell is gone so a
    /// caller can see why a node stopped.
    private var shellExitCode: Int32?
    /// The last command a program submitted through the input route, used to
    /// name the next command when the shell does not report one itself.
    private var submittedCommand: String?

    /// Every output byte flows through this ring; reattach gap-replay,
    /// observer catch-up, and tail replay are all snapshots of it. Offsets
    /// never restart, so a detached shell keeps writing freely — old bytes
    /// rotate out instead of pausing reads at a cap.
    private var log = SessionLog()
    /// Stream offset of the last byte delivered to a controller (0 before the
    /// first adoption). Clients that cannot name their own offset replay the
    /// gap from here.
    private var detachOffset: UInt64 = 0
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
    /// Shell-integration marks, indexed from the output stream itself so a
    /// session nobody is watching is still legible (see `OscMarkScanner`).
    private var markStore = SessionMarkStore()
    /// Reads OSC 133/633 out of the PTY stream. Touched only from
    /// `handleRead`, i.e. only on the event loop, so it lives outside the lock.
    private var markScanner = OscMarkScanner()
    /// Callers blocked on "tell me when command N finishes", completed from
    /// `handleRead` as the closing mark is indexed.
    private var commandWaiters: [(index: Int, promise: EventLoopPromise<Void>)] = []
    /// Optional asciinema recorder (daemon `--record`).
    private var recorder: SessionRecorder?
    /// Optional disk spill (`--retain-logs`) so ranges older than the ring are
    /// still readable. Set once at attach time and never mutated after.
    private var logStore: SessionLogStore?

    private init(
        pid: pid_t,
        masterFD: Int32,
        shellPath: String,
        initialCwd: String,
        profileName: String?,
        labels: SessionLabels,
        cols: UInt16,
        rows: UInt16
    ) {
        self.pid = pid
        self.masterFD = masterFD
        self.shellPath = shellPath
        self.initialCwd = initialCwd
        self.profileName = profileName
        self.labels = labels
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
        histFile: String? = nil,
        profileName: String? = nil,
        labels: SessionLabels = SessionLabels()
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
        // openpty leaves the master inheritable. Darwin's spawn closes
        // everything undeclared, but Linux has no such flag — so without this
        // every later session would inherit the masters of the ones before it,
        // and could read their output.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        // Darwin hands these back as pointers, glibc as structs.
        #if canImport(Darwin)
        var attrs: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        #else
        var attrs = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        #endif
        guard posix_spawnattr_init(&attrs) == 0 else {
            _ = close(master)
            _ = close(slave)
            throw PtyError.forkFailed(errno: errno)
        }
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            posix_spawnattr_destroy(&attrs)
            _ = close(master)
            _ = close(slave)
            throw PtyError.forkFailed(errno: errno)
        }
        defer {
            posix_spawnattr_destroy(&attrs)
            posix_spawn_file_actions_destroy(&actions)
            _ = close(slave)
        }

        #if canImport(Darwin)
        posix_spawnattr_setflags(
            &attrs,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        #else
        // Neither flag exists here: the helper calls setsid() itself, and
        // there is no close-everything-by-default, which is why the master is
        // marked close-on-exec at creation instead.
        #endif

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
                systemWrite(slave, ptr, strlen(ptr))
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
            _ = close(master)
            throw PtyError.forkFailed(errno: spawnRC == 0 ? errno : spawnRC)
        }

        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let session = PtySession(
            pid: childPid,
            masterFD: master,
            shellPath: shell,
            initialCwd: startCwd,
            profileName: profileName,
            labels: labels,
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

        let readFD = dup(masterFD)
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

        // Read marks out of the stream before taking the lock. The scanner is
        // loop-confined (only this method feeds it, always on the event loop),
        // so it needs no lock, and scanning outside means the lock is held for
        // no longer than it was before marks were the daemon's business.
        //
        // `logHeadUnlocked` is exact here for the same reason the attach
        // snapshot is safe: the PTY reader and everything that appends to the
        // log share this one thread, so nothing can slip in between reading the
        // head and appending the chunk below.
        let markHits = markScanner.scan(chunk, baseOffset: logHeadUnlocked)

        // Snapshot under the lock, then call out with it released: the output
        // handlers below re-enter this class. Detached output only rotates the
        // log — reads never pause for it, so a long-running program keeps
        // making progress while no client is watching.
        var readyWaiters: [EventLoopPromise<Void>] = []
        let dispatch: (recorder: SessionRecorder?,
                       logStore: SessionLogStore?,
                       observers: [(Data) -> Void],
                       controller: ((Data) -> Void)?)? = stateLock.withLock {
            guard !terminated, !readingPaused else { return nil }
            log.append(chunk)
            for hit in markHits {
                // Only kitterm's own snippet and VS Code emit the command line
                // (OSC 633;E). A shell carrying someone else's OSC 133 — iTerm2,
                // Powerlevel10k — marks the command but never names it. When a
                // program submitted the command we already know the text, so
                // use it rather than leave the record anonymous.
                var command = hit.command
                if hit.kind == .preExec, command == nil, let submitted = submittedCommand {
                    command = submitted
                    submittedCommand = nil
                }
                markStore.append(
                    SessionMark(
                        offset: hit.offset,
                        kind: hit.kind,
                        exit: hit.exit,
                        command: command
                    )
                )
            }
            // Only a closing mark can satisfy a waiter, so the pairing pass is
            // skipped entirely for the prompt marks that make up most traffic.
            if markHits.contains(where: { $0.kind == .commandEnd }), !commandWaiters.isEmpty {
                let finished = Set(
                    SessionCommands.pair(
                        from: markStore.marks,
                        firstIndex: markStore.firstRetainedIndex
                    )
                        .filter { !$0.running }
                        .map(\.index)
                )
                commandWaiters.removeAll { waiter in
                    guard finished.contains(waiter.index) else { return false }
                    readyWaiters.append(waiter.promise)
                    return true
                }
            }
            let observerOutputs = observers.values.map(\.onOutput)
            let controller = attached ? onOutput : nil
            return (recorder, logStore, observerOutputs, controller)
        }
        // Outside the lock: these callbacks re-enter this class.
        for promise in readyWaiters { promise.succeed(()) }
        guard let dispatch else { return }

        dispatch.recorder?.recordOutput(chunk)
        dispatch.logStore?.append(chunk)
        for observer in dispatch.observers {
            observer(chunk)
        }
        dispatch.controller?(chunk)
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

    /// Absolute stream offset of the next output byte (the log head). A
    /// promoted observer attaches with `.sinceOffset(logHead)` — it has been
    /// receiving live output all along, so any replay would duplicate bytes.
    public var logHead: UInt64 {
        stateLock.withLock { log.head }
    }

    /// The log head read without the lock. Only correct on the event-loop
    /// thread, where nothing else can append; `handleRead` uses it to position
    /// marks it found before it takes the lock to append their bytes.
    private var logHeadUnlocked: UInt64 {
        log.head
    }

    public var observerCount: Int {
        stateLock.withLock { observers.count }
    }

    public func addObserver(_ id: UUID, handlers: ObserverHandlers) -> SessionLog.Snapshot {
        stateLock.withLock {
            observers[id] = handlers
            return log.tail(maxBytes: KittermConstants.sessionObserverReplayMaxBytes)
        }
    }

    public func removeObserver(_ id: UUID) {
        stateLock.withLock { _ = observers.removeValue(forKey: id) }
    }

    /// Bounded so a caller cannot pile up connections against one session.
    public static let maxCommandWaiters = 64

    /// What asking to wait on a command got you.
    public enum CommandWaitOutcome {
        /// Already finished — answer the caller now.
        case finished
        /// Registered; this completes when the closing mark is indexed.
        case waiting(EventLoopFuture<Void>)
        /// This session already has `maxCommandWaiters` callers blocked on it.
        case tooManyWaiters
    }

    /// Ask to be told when command `index` (1-based) has finished. Waiting on
    /// one that has not started is legitimate: a caller writes input and waits
    /// on the command it just created, and those race by nature.
    public func awaitCommandEnd(
        index: Int,
        on eventLoop: EventLoop
    ) -> CommandWaitOutcome {
        stateLock.withLock {
            let commands = SessionCommands.pair(
                from: markStore.marks,
                firstIndex: markStore.firstRetainedIndex
            )
            if let existing = commands.first(where: { $0.index == index }), !existing.running {
                return .finished
            }
            guard commandWaiters.count < Self.maxCommandWaiters else {
                return .tooManyWaiters
            }
            let promise = eventLoop.makePromise(of: Void.self)
            commandWaiters.append((index, promise))
            return .waiting(promise.futureResult)
        }
    }

    /// Drop a timed-out waiter so it stops counting against the cap. The
    /// promise is completed, not discarded — NIO traps an uncompleted one, and
    /// the caller has already answered, so its `whenComplete` is a no-op.
    public func cancelCommandWait(_ future: EventLoopFuture<Void>) {
        let removed = stateLock.withLock { () -> [EventLoopPromise<Void>] in
            var taken: [EventLoopPromise<Void>] = []
            commandWaiters.removeAll { waiter in
                guard waiter.promise.futureResult === future else { return false }
                taken.append(waiter.promise)
                return true
            }
            return taken
        }
        for promise in removed { promise.succeed(()) }
    }

    public func appendMark(_ mark: SessionMark) {
        stateLock.withLock { markStore.append(mark) }
    }

    public func marksSnapshot() -> [SessionMark] {
        stateLock.withLock { markStore.marks }
    }

    /// This session's commands, numbered stably. Prefer this to pairing
    /// `marksSnapshot()` by hand, which renumbers from 1 once the window slides.
    public func commandsSnapshot() -> [SessionCommand] {
        stateLock.withLock {
            SessionCommands.pair(
                from: markStore.marks,
                firstIndex: markStore.firstRetainedIndex
            )
        }
    }

    /// Oldest command still retained; anything below it has aged out.
    public var firstRetainedCommandIndex: Int {
        stateLock.withLock { markStore.firstRetainedIndex }
    }

    /// A command's captured output for the agent-facing API. `data` is the tail
    /// `maxBytes` of the requested range (older bytes are what an agent least
    /// needs when a command floods); `total` is the full range size and
    /// `truncated`/`pruned` say whether bytes were dropped for the cap or
    /// rotated out of the ring.
    public struct OutputRange: Sendable {
        public let data: Data
        public let start: UInt64
        public let total: Int
        public let truncated: Bool
        public let pruned: Bool
    }

    /// Output bytes in `[from, to)`, falling back to retained output on disk
    /// when the range has rotated out of the ring.
    ///
    /// Asynchronous because that fallback reads a file, which must not happen
    /// on the event loop; `completion` fires on the store's queue, so callers
    /// hop back to their own loop.
    public func outputRange(
        from: UInt64,
        to: UInt64,
        maxBytes: Int,
        completion: @escaping (OutputRange) -> Void
    ) {
        let ring = outputRange(from: from, to: to, maxBytes: maxBytes)
        let store = stateLock.withLock { logStore }
        guard ring.pruned, let store else { return completion(ring) }
        // The file does not begin at stream offset zero — the store attaches
        // after the shell has already printed — so `SessionLogStore` holds that
        // origin and translates. Ask it in stream offsets.
        let end = min(to, logHead)
        let start = end > UInt64(maxBytes) ? max(from, end - UInt64(maxBytes)) : from
        store.read(from: start, to: end) { data, actualStart in
            let total = Int(end - min(from, end))
            completion(
                OutputRange(
                    data: data,
                    start: actualStart,
                    total: total,
                    truncated: total > maxBytes,
                    // Only still pruned if even the file no longer has it.
                    pruned: actualStart > from
                )
            )
        }
    }

    /// Output bytes in `[from, to)` (pass a large `to` for a still-running
    /// command to read up to now), bounded to the tail `maxBytes`. Ring only —
    /// use the asynchronous overload to fall back to retained output. Read
    /// under the lock, like the other log accessors.
    public func outputRange(from: UInt64, to: UInt64, maxBytes: Int) -> OutputRange {
        stateLock.withLock {
            let end = min(to, log.head)
            let reqStart = min(from, end)
            let total = Int(end - reqStart)
            let pruned = from < log.base
            let boundedStart = total > maxBytes ? end - UInt64(maxBytes) : reqStart
            let snap = log.range(from: boundedStart, to: end)
            return OutputRange(
                data: snap.data,
                start: snap.start,
                total: total,
                truncated: total > maxBytes,
                pruned: pruned
            )
        }
    }

    func attachRecorder(_ recorder: SessionRecorder) {
        stateLock.withLock { self.recorder = recorder }
    }

    /// The store's first byte is whatever arrives next, so `make` is handed
    /// the current head to use as the file's origin.
    func attachLogStore(_ make: (UInt64) -> SessionLogStore?) {
        stateLock.withLock {
            if let store = make(log.head) { self.logStore = store }
        }
    }

    /// How a newly attaching controller wants missed output replayed.
    public enum ReplayRequest {
        /// Client counted its received bytes; replay everything after them.
        case sinceOffset(UInt64)
        /// Fresh page with no screen state; replay the recent tail only.
        case tail(maxBytes: Int)
        /// Client cannot name an offset (old client, or the startup gap
        /// before the first adoption); replay the gap since the last
        /// delivered byte.
        case fromDetachPoint
    }

    /// Returns the replay snapshot instead of delivering it through
    /// `onOutput`, so the caller can frame it (e.g. announce offsets) before
    /// any live bytes. Safe because the handler and the PTY reader share the
    /// daemon's single event-loop thread: no output can interleave between
    /// this returning and the caller sending the snapshot.
    @discardableResult
    public func attach(
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void,
        onCwd: ((String) -> Void)? = nil,
        replay: ReplayRequest = .fromDetachPoint
    ) -> SessionLog.Snapshot {
        let resumed: (snapshot: SessionLog.Snapshot, wasPaused: Bool) = stateLock.withLock {
            self.onOutput = onOutput
            self.onExit = onExit
            self.onCwd = onCwd
            attached = true
            let snapshot: SessionLog.Snapshot
            switch replay {
            case .sinceOffset(let offset):
                snapshot = log.snapshot(from: offset)
            case .tail(let maxBytes):
                snapshot = log.tail(maxBytes: maxBytes)
            case .fromDetachPoint:
                let gap = log.snapshot(from: detachOffset)
                if gap.pruned {
                    // Requesters on this path are old clients that ignore the
                    // resync flag and append the replay to their stale screen.
                    // A full-ring append would garble it for minutes; a small
                    // tail bounds the damage the same way a fresh page does.
                    let tail = log.tail(
                        maxBytes: KittermConstants.sessionObserverReplayMaxBytes
                    )
                    snapshot = SessionLog.Snapshot(
                        data: tail.data,
                        start: tail.start,
                        pruned: true
                    )
                } else {
                    snapshot = gap
                }
            }
            // Everything up to head is now the controller's; a re-attach
            // without an intervening detach must not replay it again.
            detachOffset = log.head
            let wasPaused = readingPaused
            readingPaused = false
            return (snapshot, wasPaused)
        }
        if resumed.wasPaused { setChannelAutoRead(true) }
        if onCwd != nil { startCwdPolling() }
        return resumed.snapshot
    }

    public func detach(onExitWhileDetached: ((Int32) -> Void)? = nil) {
        stopCwdPolling()
        let wasPaused = stateLock.withLock { () -> Bool in
            attached = false
            onOutput = nil
            onExit = onExitWhileDetached
            onCwd = nil
            // The controller saw everything up to here; the gap for the next
            // offset-less attach starts now.
            detachOffset = log.head
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

    /// The shell's working directory as last observed by the poll, for readers
    /// on other threads (the session-list API). Falls back to the spawn cwd
    /// before the first poll.
    public var currentCwd: String {
        stateLock.withLock { lastPolledCwd ?? initialCwd }
    }

    /// The shell's working directory right now, read from the kernel. The
    /// poll only runs while a controller is attached, so a detached session's
    /// `currentCwd` freezes at detach time — exactly the sessions the fleet
    /// view supervises. `proc_pidinfo` is a microsecond read, so the listing
    /// API asks the kernel directly and falls back to the last-known value.
    public var liveCwd: String {
        Self.currentDirectory(ofPID: pid) ?? currentCwd
    }

    private func startCwdPolling() {
        let alive = stateLock.withLock { () -> Bool in
            guard !terminated else { return false }
            // Seed only when nothing was ever polled: a reattach must not
            // regress a fresher value back to the spawn cwd.
            if lastPolledCwd == nil { lastPolledCwd = initialCwd }
            return true
        }
        guard alive, let eventLoop, cwdTask == nil else { return }
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
        guard let path = Self.currentDirectory(ofPID: pid) else { return }
        // Read, compare, and store the cwd under the lock so the session-list
        // API can read it from another thread; call the client callback with
        // the lock released, per the class invariant.
        let callback: ((String) -> Void)? = stateLock.withLock {
            guard path != lastPolledCwd else { return nil }
            lastPolledCwd = path
            return onCwd
        }
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

    public func terminate() {
        stopCwdPolling()
        // Everything that can block — closing the channel, signalling the child
        // — happens after the lock is released. Waiting on the event loop while
        // holding it deadlocks against `write()`, which the loop itself calls.
        typealias Shutdown = (channel: Channel?, recorder: SessionRecorder?, logStore: SessionLogStore?)
        let shutdown: Shutdown? = stateLock.withLock {
            guard !terminated else { return nil }
            terminated = true
            let channel = readChannel
            let recorder = self.recorder
            self.readChannel = nil
            self.recorder = nil
            // The shell is going away; undelivered input has nowhere to go.
            pendingInput = Data()
            _ = close(masterFD)
            return (channel, recorder, nil)
        }
        guard let shutdown else { return }

        // Answer blocked callers now. `deliverExit` does this too, but a
        // terminate may never reach it, and a dropped promise is a NIO leak.
        failCommandWaiters()
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

    /// Remember what a program asked the shell to run, so the command it
    /// creates can be named even when the shell does not report one.
    ///
    /// Only whole submissions count: a partial write, or a keystroke answering
    /// a prompt, is not a command. Multi-line input names the first command
    /// only — the shell reports the rest, or they stay anonymous.
    public func noteSubmittedCommand(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= KittermConstants.maxTitleLength else { return }
        stateLock.withLock { submittedCommand = trimmed }
    }

    /// Exit code, once the shell has exited.
    public var exitCode: Int32? {
        stateLock.withLock { shellExitCode }
    }

    /// Drop retained output. Separate from `terminate()` so a session can
    /// outlive its shell with its records intact; the registry calls this when
    /// it finally reaps the session.
    public func discardRetainedOutput() {
        let store = stateLock.withLock { () -> SessionLogStore? in
            let store = logStore
            logStore = nil
            return store
        }
        store?.close()
    }

    /// A dead shell finishes nobody's command; release waiters now rather than
    /// leaving them to time out.
    private func failCommandWaiters() {
        let promises = stateLock.withLock { () -> [EventLoopPromise<Void>] in
            let pending = commandWaiters.map(\.promise)
            commandWaiters.removeAll()
            return pending
        }
        for promise in promises { promise.succeed(()) }
    }

    private func deliverExit(_ code: Int32) {
        let handlers: (controller: ((Int32) -> Void)?, observers: [(Int32) -> Void])? =
            stateLock.withLock {
                guard !exitNotified else { return nil }
                exitNotified = true
                shellExitCode = code
                // A shell that dies mid-command never sends the mark closing
                // it, which would leave that command running forever and give
                // a waiter nothing to read. Close it with the shell's own exit.
                let open = SessionCommands.pair(
                    from: markStore.marks,
                    firstIndex: markStore.firstRetainedIndex
                ).last
                if open?.running == true {
                    markStore.append(
                        SessionMark(
                            offset: logHeadUnlocked,
                            kind: .commandEnd,
                            exit: code,
                            command: nil
                        )
                    )
                }
                return (onExit, observers.values.map(\.onExit))
            }
        guard let handlers else { return }
        failCommandWaiters()
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
