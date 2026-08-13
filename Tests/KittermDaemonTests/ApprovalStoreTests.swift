import Foundation
import KittermProtocol
import NIOCore
import NIOEmbedded
import XCTest

@testable import KittermDaemon

/// The store is what makes an agent wait for a human. Its whole contract is
/// that exactly one answer reaches the waiting hook, and that *some* answer
/// always does — a hook that never gets a response is a wedged agent.
final class ApprovalStoreTests: XCTestCase {
    private var loop: EmbeddedEventLoop!
    private var store: ApprovalStore!

    override func setUp() {
        super.setUp()
        loop = EmbeddedEventLoop()
        store = ApprovalStore()
    }

    override func tearDown() {
        // Anything still pending would leak its promise past the test.
        for pending in store.snapshot() { store.expire(id: pending.id) }
        try? loop.syncShutdownGracefully()
        super.tearDown()
    }

    private func register(tool: String = "Bash") -> (String, EventLoopFuture<ApprovalStore.Decision?>) {
        let result = store.register(
            sessionID: UUID(), toolName: tool, toolInput: #"{"command":"ls"}"#, on: loop
        )
        return (result.id, result.decision)
    }

    func testAllowReachesTheWaitingHook() throws {
        let (id, decision) = register()
        XCTAssertEqual(store.count, 1)

        XCTAssertTrue(store.resolve(id: id, decision: .allow(reason: "looks fine")))

        XCTAssertEqual(try decision.wait(), ApprovalStore.Decision.allow(reason: "looks fine"))
        XCTAssertEqual(store.count, 0, "answering must retire the entry")
    }

    func testDenyCarriesItsReason() throws {
        let (id, decision) = register()
        store.resolve(id: id, decision: .deny(reason: "not on main"))
        XCTAssertEqual(try decision.wait(), ApprovalStore.Decision.deny(reason: "not on main"))
    }

    /// The fallback that keeps an unattended agent moving: no answer is itself
    /// an answer, and the hook gets it rather than hanging.
    func testExpiringCompletesWithNoDecision() throws {
        let (id, decision) = register()
        store.expire(id: id)
        XCTAssertNil(try decision.wait())
        XCTAssertEqual(store.count, 0)
    }

    /// Two taps on Allow, or a decision racing its own timeout. The second must
    /// not complete an already-completed promise, which would trap.
    func testSecondAnswerIsRefused() throws {
        let (id, decision) = register()
        XCTAssertTrue(store.resolve(id: id, decision: .allow(reason: nil)))
        XCTAssertFalse(store.resolve(id: id, decision: .deny(reason: nil)))
        store.expire(id: id)  // must also be a no-op
        XCTAssertEqual(try decision.wait(), ApprovalStore.Decision.allow(reason: nil))
    }

    func testUnknownIdIsRefusedRatherThanCrashing() {
        XCTAssertFalse(store.resolve(id: "not-a-real-id", decision: .allow(reason: nil)))
        store.expire(id: "not-a-real-id")
    }

    func testSnapshotReportsWhatIsWaiting() {
        let (id, _) = register(tool: "Write")
        let pending = store.snapshot()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].id, id)
        XCTAssertEqual(pending[0].toolName, "Write")
        XCTAssertEqual(pending[0].toolInput, #"{"command":"ls"}"#)
    }

    /// A Write's contents run to megabytes; the approval screen keeps a
    /// readable prefix rather than the whole thing.
    func testOversizedToolInputIsTruncated() {
        let huge = String(repeating: "x", count: KittermConstants.approvalInputChars * 2)
        _ = store.register(sessionID: nil, toolName: "Write", toolInput: huge, on: loop)
        XCTAssertEqual(
            store.snapshot()[0].toolInput.count, KittermConstants.approvalInputChars
        )
    }

    /// A misconfigured hook, or an agent retrying in a loop, must not grow this
    /// without bound — and the entry it drops still gets an answer.
    func testCapacityEvictsTheOldestAndAnswersIt() throws {
        let small = ApprovalStore(capacity: 2)
        let first = small.register(sessionID: nil, toolName: "A", toolInput: "{}", on: loop)
        _ = small.register(sessionID: nil, toolName: "B", toolInput: "{}", on: loop)
        _ = small.register(sessionID: nil, toolName: "C", toolInput: "{}", on: loop)

        XCTAssertNil(try first.decision.wait(), "the evicted hook must not hang")
        XCTAssertEqual(small.count, 2)
        XCTAssertEqual(small.snapshot().map(\.toolName), ["B", "C"])
        for pending in small.snapshot() { small.expire(id: pending.id) }
    }

    // MARK: - the shape Claude Code actually reads

    func testHookResponseForAllow() throws {
        let json = try decode(HTTPAPIHandler.hookResponse(for: .allow(reason: "ok")))
        let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(specific["permissionDecision"] as? String, "allow")
        XCTAssertEqual(specific["permissionDecisionReason"] as? String, "ok")
    }

    func testHookResponseForDenyWithoutReason() throws {
        let json = try decode(HTTPAPIHandler.hookResponse(for: .deny(reason: nil)))
        let specific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertNil(specific["permissionDecisionReason"])
    }

    /// No decision must be an empty object, not a denial: the agent then runs
    /// its own permission flow instead of failing a tool nobody rejected.
    func testHookResponseForNoDecisionIsEmpty() throws {
        XCTAssertTrue(try decode(HTTPAPIHandler.hookResponse(for: nil)).isEmpty)
    }

    private func decode(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }
}
