import Foundation
import KittermProtocol
import NIOCore
import NIOPosix
import XCTest

@testable import KittermDaemon

/// Concurrency and buffering behaviour of `PtySession`.
///
/// The session is driven synthetically via `handleRead` rather than by waiting
/// on real shell output: the buffering rules are what these tests are about,
/// and feeding them directly keeps the assertions exact instead of racing a
/// login shell's startup noise. One end-to-end test covers the real path.
///
/// Every test that could deadlock runs the suspect call on a background queue
/// behind an expectation, so a regression fails on a timeout instead of
/// hanging the whole suite.
final class PtySessionTests: XCTestCase {
    private var session: PtySession!

    override class func setUp() {
        super.setUp()

        // `SpawnHelperPath` resolves the helper next to the running binary or
        // on PATH. Under `swift test` the running binary is Xcode's `xctest`,
        // so neither finds it — but the helper is built next to our test
        // bundle.
        let buildDir = Bundle(for: PtySessionTests.self).bundleURL.deletingLastPathComponent()
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", buildDir.path + ":" + path, 1)

        // `resolvedShell()` honours $SHELL, and sessions spawn it as a *login*
        // shell. Left alone, every test would source the developer's personal
        // rc files: the end-to-end test took 22s on a machine with a heavy zsh
        // setup, and results would vary per machine. Pin a minimal shell so
        // startup is fast and identical everywhere.
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        session = try PtySession.spawn(cols: 80, rows: 24, cwd: NSTemporaryDirectory())
    }

    override func tearDown() {
        session?.terminate()
        session = nil
        super.tearDown()
    }

    private func feed(_ string: String) {
        feedSession(session, string)
    }

    private func feed(bytes count: Int) {
        var buffer = ByteBufferAllocator().buffer(capacity: count)
        buffer.writeBytes([UInt8](repeating: 0x61, count: count))
        session.handleRead(&buffer)
    }

    /// Run `body` off the test thread and fail if it does not return in time.
    /// A non-recursive lock held across a callback shows up here as a timeout.
    private func expectNoDeadlock(
        _ description: String,
        timeout: TimeInterval = 5,
        _ body: @escaping @Sendable () -> Void
    ) {
        let finished = expectation(description: description)
        DispatchQueue.global().async {
            body()
            finished.fulfill()
        }
        wait(for: [finished], timeout: timeout)
    }

    // MARK: - Lifecycle

    func testSpawnedSessionIsRunning() {
        XCTAssertTrue(session.isRunning)
        XCTAssertGreaterThan(session.pid, 0)
    }

    func testTerminateStopsTheSession() {
        session.terminate()
        XCTAssertFalse(session.isRunning)
    }

    func testTerminateIsIdempotent() {
        expectNoDeadlock("repeated terminate") { [session] in
            session?.terminate()
            session?.terminate()
            session?.terminate()
        }
        XCTAssertFalse(session.isRunning)
    }

    func testWriteAfterTerminateThrowsClosed() {
        session.terminate()
        XCTAssertThrowsError(try session.write(Data("ls\n".utf8))) { assertClosed($0) }
    }

    func testResizeAfterTerminateThrowsClosed() {
        session.terminate()
        XCTAssertThrowsError(try session.resize(cols: 100, rows: 40)) { assertClosed($0) }
    }

    /// `PtyError` is not `Equatable`, so match the case rather than add a
    /// conformance that only the tests would use.
    private func assertClosed(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let pty = error as? PtyError, case .closed = pty else {
            XCTFail("expected PtyError.closed, got \(error)", file: file, line: line)
            return
        }
    }

    func testHandleReadAfterTerminateDeliversNothing() {
        let received = Captured()
        session.attach(onOutput: received.append, onExit: { _ in })
        session.terminate()
        feed("ignored")
        XCTAssertTrue(received.data.isEmpty)
    }

    // MARK: - Attach / detach buffering

    func testAttachedOutputGoesStraightToTheController() {
        let received = Captured()
        session.attach(onOutput: received.append, onExit: { _ in })
        feed("hello")
        XCTAssertEqual(received.data, Data("hello".utf8))
    }

    func testDetachedOutputBuffersAndReplaysOnAttach() {
        feed("while-away")

        let received = Captured()
        session.attach(onOutput: received.append, onExit: { _ in })
        XCTAssertEqual(received.data, Data("while-away".utf8))
    }

    func testReplayIsDeliveredOnlyOnce() {
        feed("once")

        let first = Captured()
        session.attach(onOutput: first.append, onExit: { _ in })
        session.detach()

        let second = Captured()
        session.attach(onOutput: second.append, onExit: { _ in })
        XCTAssertEqual(first.data, Data("once".utf8))
        XCTAssertTrue(second.data.isEmpty, "the buffer was already drained by the first attach")
    }

    func testDetachBuffersOutputForTheNextController() {
        let first = Captured()
        session.attach(onOutput: first.append, onExit: { _ in })
        session.detach()
        feed("after-detach")
        XCTAssertTrue(first.data.isEmpty, "a detached controller must not keep receiving output")

        let second = Captured()
        session.attach(onOutput: second.append, onExit: { _ in })
        XCTAssertEqual(second.data, Data("after-detach".utf8))
    }

    /// A reattaching client asks for the rolling tail instead of the detached
    /// buffer, so it repaints the screen rather than replaying the gap twice.
    func testReplayRecentTailDeliversRecentOutputAndDropsTheDetachedBuffer() {
        feed("scrollback")

        let received = Captured()
        session.attach(
            onOutput: received.append,
            onExit: { _ in },
            replayRecentTail: true
        )
        XCTAssertEqual(received.data, Data("scrollback".utf8))

        // The detached buffer was discarded, not queued behind the tail.
        session.detach()
        let second = Captured()
        session.attach(onOutput: second.append, onExit: { _ in })
        XCTAssertTrue(second.data.isEmpty)
    }

    func testExitWhileDetachedGoesToTheDetachHandler() {
        session.attach(onOutput: { _ in }, onExit: { _ in })

        let exited = expectation(description: "exit while detached")
        session.detach(onExitWhileDetached: { _ in exited.fulfill() })
        session.terminate()
        wait(for: [exited], timeout: 10)
    }

    // MARK: - Flow control

    func testPausedReadsAreDroppedAndResumeRestoresDelivery() {
        let received = Captured()
        session.attach(onOutput: received.append, onExit: { _ in })

        session.pauseReading()
        feed("dropped")
        XCTAssertTrue(received.data.isEmpty)

        session.resumeReading()
        feed("delivered")
        XCTAssertEqual(received.data, Data("delivered".utf8))
    }

    func testPauseAndResumeAreIdempotent() {
        expectNoDeadlock("repeated pause/resume") { [session] in
            session?.pauseReading()
            session?.pauseReading()
            session?.resumeReading()
            session?.resumeReading()
        }

        let received = Captured()
        session.attach(onOutput: received.append, onExit: { _ in })
        feed("still-flowing")
        XCTAssertEqual(received.data, Data("still-flowing".utf8))
    }

    /// An unbounded detached buffer would let a runaway process grow the
    /// daemon's memory without limit, so reads pause at the cap.
    func testDetachedBufferOverflowPausesReadsUntilAttach() {
        let cap = KittermConstants.sessionDetachBufferMaxBytes
        let chunk = 64 * 1024
        var written = 0
        while written < cap {
            feed(bytes: chunk)
            written += chunk
        }

        // Reads are paused now, so this is dropped rather than buffered.
        feed(bytes: chunk)

        let received = Captured()
        session.attach(onOutput: received.append, onExit: { _ in })
        XCTAssertEqual(received.data.count, written, "attach replays exactly what was buffered")

        // Attaching resumed reads.
        received.reset()
        feed("flowing-again")
        XCTAssertEqual(received.data, Data("flowing-again".utf8))
    }

    // MARK: - Observers

    func testObserverCountTracksAddAndRemove() {
        let id = UUID()
        XCTAssertEqual(session.observerCount, 0)
        _ = session.addObserver(id, handlers: .noop)
        XCTAssertEqual(session.observerCount, 1)
        session.removeObserver(id)
        XCTAssertEqual(session.observerCount, 0)
    }

    func testObserverJoiningReceivesTheRecentTail() {
        feed("earlier-output")
        let replay = session.addObserver(UUID(), handlers: .noop)
        XCTAssertEqual(replay, Data("earlier-output".utf8))
    }

    func testObserversReceiveOutputAlongsideTheController() {
        let controller = Captured()
        let observed = Captured()
        session.attach(onOutput: controller.append, onExit: { _ in })
        _ = session.addObserver(UUID(), handlers: .capturing(observed.append))

        feed("shared")
        XCTAssertEqual(controller.data, Data("shared".utf8))
        XCTAssertEqual(observed.data, Data("shared".utf8))
    }

    func testObserversReceiveOutputWhileNoControllerIsAttached() {
        let observed = Captured()
        _ = session.addObserver(UUID(), handlers: .capturing(observed.append))
        feed("detached-but-observed")
        XCTAssertEqual(observed.data, Data("detached-but-observed".utf8))
    }

    func testRemovedObserverStopsReceivingOutput() {
        let id = UUID()
        let observed = Captured()
        _ = session.addObserver(id, handlers: .capturing(observed.append))
        session.removeObserver(id)
        feed("after-removal")
        XCTAssertTrue(observed.data.isEmpty)
    }

    // MARK: - Resize

    func testResizeUpdatesDimensionsAndNotifiesObservers() throws {
        let seen = CapturedResize()
        _ = session.addObserver(
            UUID(),
            handlers: PtySession.ObserverHandlers(
                onOutput: { _ in },
                onExit: { _ in },
                onResize: seen.record
            )
        )

        try session.resize(cols: 100, rows: 40)
        XCTAssertEqual(session.cols, 100)
        XCTAssertEqual(session.rows, 40)
        XCTAssertEqual(seen.cols, 100)
        XCTAssertEqual(seen.rows, 40)
    }

    func testResizeClampsToTheProtocolLimits() throws {
        try session.resize(cols: 0, rows: 0)
        XCTAssertEqual(session.cols, 1)
        XCTAssertEqual(session.rows, 1)

        try session.resize(cols: .max, rows: .max)
        XCTAssertEqual(session.cols, KittermConstants.maxCols)
        XCTAssertEqual(session.rows, KittermConstants.maxRows)
    }

    // MARK: - Reentrancy

    // Rule 1 of `stateLock`: callbacks run with the lock released. These
    // callbacks re-enter the session the way the WebSocket handler does; with
    // a non-recursive lock still held, each would deadlock.

    func testControllerCallbackCanReenterTheSession() {
        let observed = CapturedCount()
        session.attach(
            onOutput: { [session] _ in
                session?.pauseReading()
                session?.resumeReading()
                observed.value = session?.observerCount
            },
            onExit: { _ in }
        )

        expectNoDeadlock("reentrant controller callback") { [session] in
            if let session { feedSession(session, "trigger") }
        }
        XCTAssertEqual(observed.value, 0)
    }

    func testObserverCallbackCanReenterTheSession() {
        let running = CapturedFlag()
        _ = session.addObserver(
            UUID(),
            handlers: .capturing { [session] _ in running.value = session?.isRunning }
        )

        expectNoDeadlock("reentrant observer callback") { [session] in
            if let session { feedSession(session, "trigger") }
        }
        XCTAssertEqual(running.value, true)
    }

    func testResizeCallbackCanReenterTheSession() {
        let running = CapturedFlag()
        _ = session.addObserver(
            UUID(),
            handlers: PtySession.ObserverHandlers(
                onOutput: { _ in },
                onExit: { _ in },
                onResize: { [session] _, _ in running.value = session?.isRunning }
            )
        )

        expectNoDeadlock("reentrant resize callback") { [session] in
            try? session?.resize(cols: 90, rows: 30)
        }
        XCTAssertEqual(running.value, true)
    }

    /// The regression the refactor was written for: `terminate()` used to wait
    /// on channel close while holding the lock that `write()` takes from the
    /// event loop. Tearing the session down from inside a callback is exactly
    /// that shape.
    func testTerminateFromInsideAnOutputCallbackDoesNotDeadlock() {
        session.attach(onOutput: { [session] _ in session?.terminate() }, onExit: { _ in })

        expectNoDeadlock("terminate from callback") { [session] in
            if let session { feedSession(session, "trigger") }
        }
        XCTAssertFalse(session.isRunning)
    }

    func testConcurrentWritesAndTerminateDoNotDeadlock() {
        let done = expectation(description: "concurrent access")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async { [session] in
            for _ in 0..<200 {
                try? session?.write(Data("x".utf8))
                _ = session?.observerCount
            }
            done.fulfill()
        }
        DispatchQueue.global().async { [session] in
            for _ in 0..<200 {
                session?.pauseReading()
                session?.resumeReading()
            }
            session?.terminate()
            done.fulfill()
        }

        wait(for: [done], timeout: 10)
        XCTAssertFalse(session.isRunning)
    }

    // MARK: - End to end

    /// The synthetic tests above bypass the PTY itself; this one proves a real
    /// write reaches the shell, is *executed*, and the result comes back
    /// through the reader channel on the event loop.
    ///
    /// The marker is assembled by the shell from two halves rather than typed
    /// whole. A PTY echoes input back, so a marker written literally appears in
    /// the output even if the shell never runs — this test passed against a
    /// dead shell until the halves were split. Only real execution
    /// concatenates them.
    func testRealPtyRoundTrip() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let head = "KITTERM_ROUND"
        let tail = "TRIP_OK"
        let seen = expectation(description: "shell executed the command")
        let sink = MarkerSink(marker: head + tail) { seen.fulfill() }

        session.attach(onOutput: sink.append, onExit: { _ in })

        try session.makeReader(group: group, eventLoop: group.next()).wait()
        try session.write(Data("printf '%s%s\\n' \(head) \(tail)\n".utf8))

        wait(for: [seen], timeout: 30)
    }

    /// A paste larger than the PTY buffer makes the non-blocking master fd
    /// return `EAGAIN` part-way through. Writing straight to the fd dropped the
    /// remainder, silently truncating input.
    ///
    /// `head -c` exits only after reading exactly `payloadBytes`, so the marker
    /// it guards is printed only if every byte arrived. Dropped input leaves
    /// `head` waiting forever and the test times out.
    ///
    /// `stty -echo -icanon` keeps the line discipline out of it: canonical mode
    /// caps a single line at `MAX_CANON` and would truncate the payload at the
    /// tty layer regardless of what this code does.
    func testLargeWriteIsNotTruncatedByBackpressure() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let payloadBytes = 512 * 1024
        let head = "KITTERM_PASTE"
        let tail = "COMPLETE"
        let seen = expectation(description: "shell read every pasted byte")
        let sink = MarkerSink(marker: head + tail) { seen.fulfill() }

        session.attach(onOutput: sink.append, onExit: { _ in })
        try session.makeReader(group: group, eventLoop: group.next()).wait()

        try session.write(Data("stty -echo -icanon\n".utf8))
        try session.write(
            Data("head -c \(payloadBytes) > /dev/null && printf '%s%s\\n' \(head) \(tail)\n".utf8)
        )
        // One write far bigger than the PTY buffer, so it cannot land in a
        // single `write(2)`.
        try session.write(Data(repeating: UInt8(ascii: "a"), count: payloadBytes))

        wait(for: [seen], timeout: 30)
    }
}

/// Free function, not a method: the deadlock tests feed the session from a
/// `@Sendable` closure, which cannot capture the non-`Sendable` test case.
private func feedSession(_ session: PtySession, _ string: String) {
    var buffer = ByteBufferAllocator().buffer(capacity: string.utf8.count)
    buffer.writeString(string)
    session.handleRead(&buffer)
}

// MARK: - Capture helpers

/// Output arrives on the event loop for the end-to-end test and on the caller's
/// thread for the synthetic ones, so captures are lock-guarded reference types
/// rather than captured `var`s.
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(chunk)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage = Data()
    }
}

private final class CapturedResize: @unchecked Sendable {
    private let lock = NSLock()
    private var dimensions: (cols: UInt16, rows: UInt16)?

    var cols: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return dimensions?.cols
    }

    var rows: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return dimensions?.rows
    }

    func record(_ cols: UInt16, _ rows: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        dimensions = (cols, rows)
    }
}

private final class CapturedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int?

    var value: Int? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

private final class CapturedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?

    var value: Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

/// Accumulates PTY output until `marker` appears, then signals once. The shell
/// splits output across arbitrary reads, so the marker may straddle chunks.
private final class MarkerSink: @unchecked Sendable {
    private let lock = NSLock()
    private let marker: String
    private let onFound: () -> Void
    private var buffered = ""
    private var found = false

    init(marker: String, onFound: @escaping () -> Void) {
        self.marker = marker
        self.onFound = onFound
    }

    func append(_ chunk: Data) {
        lock.lock()
        buffered += String(decoding: chunk, as: UTF8.self)
        let shouldSignal = !found && buffered.contains(marker)
        if shouldSignal { found = true }
        lock.unlock()
        if shouldSignal { onFound() }
    }
}

extension PtySession.ObserverHandlers {
    static var noop: PtySession.ObserverHandlers {
        PtySession.ObserverHandlers(onOutput: { _ in }, onExit: { _ in }, onResize: { _, _ in })
    }

    static func capturing(
        _ onOutput: @escaping (Data) -> Void
    ) -> PtySession.ObserverHandlers {
        PtySession.ObserverHandlers(onOutput: onOutput, onExit: { _ in }, onResize: { _, _ in })
    }
}
