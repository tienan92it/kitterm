import Foundation
import KittermProtocol
import NIOCore
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `…/commands/<n>/wait` is what makes kitterm an `execute()` backend, so the
/// waiter has to fire off the mark that closes a command — driven here through
/// the synthetic feed path so the assertions are exact instead of racing a real
/// shell.
final class CommandWaitTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var session: PtySession!

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: CommandWaitTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        session = try PtySession.spawn(cols: 80, rows: 24, cwd: NSTemporaryDirectory())
    }

    override func tearDownWithError() throws {
        session?.terminate()
        session = nil
        try? group.syncShutdownGracefully()
    }

    private func feed(_ text: String) {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        session.handleRead(&buffer)
    }

    private func osc(_ payload: String) -> String { "\u{1b}]\(payload)\u{07}" }

    /// The registered future, failing the test if the wait was refused or the
    /// command had already finished.
    private func waiter(
        _ outcome: PtySession.CommandWaitOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> EventLoopFuture<Void> {
        guard case .waiting(let future) = outcome else {
            XCTFail("expected a registered waiter, got \(outcome)", file: file, line: line)
            throw XCTSkip("no waiter")
        }
        return future
    }

    func testWaiterFiresWhenTheClosingMarkArrives() throws {
        let loop = group.next()
        feed(osc("633;E;make test") + osc("133;C") + "building…\n")

        let future = try waiter(session.awaitCommandEnd(index: 1, on: loop))

        let done = expectation(description: "waiter fired")
        future.whenComplete { _ in done.fulfill() }

        feed(osc("133;D;0"))
        wait(for: [done], timeout: 5)

        let cmd = try XCTUnwrap(session.commandsSnapshot().first)
        XCTAssertFalse(cmd.running)
        XCTAssertEqual(cmd.exit, 0)
        XCTAssertEqual(cmd.command, "make test")
    }

    func testAlreadyFinishedCommandRegistersNoWaiter() throws {
        feed(osc("133;C") + "out" + osc("133;D;3"))
        guard case .finished = session.awaitCommandEnd(index: 1, on: group.next()) else {
            return XCTFail("a finished command answers immediately, without a waiter")
        }
    }

    func testWaitingForACommandThatHasNotStartedYet() throws {
        let loop = group.next()
        // Legitimate: a caller writes input and waits on the command it created.
        let future = try waiter(session.awaitCommandEnd(index: 1, on: loop))
        let done = expectation(description: "waiter fired for a later command")
        future.whenComplete { _ in done.fulfill() }
        feed(osc("133;C") + "work" + osc("133;D;0"))
        wait(for: [done], timeout: 5)
    }

    func testOnlyTheMatchingWaiterFires() throws {
        let loop = group.next()
        feed(osc("133;C"))
        let first = try waiter(session.awaitCommandEnd(index: 1, on: loop))
        let second = try waiter(session.awaitCommandEnd(index: 2, on: loop))

        let firstDone = expectation(description: "command 1")
        first.whenComplete { _ in firstDone.fulfill() }
        var secondFired = false
        second.whenComplete { _ in secondFired = true }

        feed(osc("133;D;0"))
        wait(for: [firstDone], timeout: 5)
        XCTAssertFalse(secondFired, "command 2 has not run yet")
    }

    func testWaiterCapIsEnforced() throws {
        let loop = group.next()
        for _ in 0..<PtySession.maxCommandWaiters {
            _ = try waiter(session.awaitCommandEnd(index: 99, on: loop))
        }
        guard case .tooManyWaiters = session.awaitCommandEnd(index: 99, on: loop) else {
            return XCTFail("past the cap the caller must be turned away, not queued")
        }
    }

    /// A dead shell will never close anyone's command; waiters must be released
    /// so callers learn now rather than at their timeout.
    func testShellExitReleasesWaiters() throws {
        let loop = group.next()
        feed(osc("133;C"))
        let future = try waiter(session.awaitCommandEnd(index: 1, on: loop))
        let released = expectation(description: "waiter released on exit")
        future.whenComplete { _ in released.fulfill() }
        session.terminate()
        wait(for: [released], timeout: 10)
    }

    func testCancelRemovesAWaiterFromTheCap() throws {
        let loop = group.next()
        var futures: [EventLoopFuture<Void>] = []
        for _ in 0..<PtySession.maxCommandWaiters {
            futures.append(try waiter(session.awaitCommandEnd(index: 99, on: loop)))
        }
        guard case .tooManyWaiters = session.awaitCommandEnd(index: 99, on: loop) else {
            return XCTFail("the cap should be full")
        }
        session.cancelCommandWait(futures[0])
        _ = try waiter(
            session.awaitCommandEnd(index: 99, on: loop)
        )  // a timed-out waiter must free its slot
    }
}
