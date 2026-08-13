import Foundation
import KittermProtocol
import NIOCore

/// Tool calls an agent is waiting on a human to decide.
///
/// A Claude Code `PreToolUse` hook posts here over HTTP and the response body
/// carries the verdict, so the agent is genuinely blocked until someone answers
/// — from a phone, from the fleet view, from anywhere that holds a full token.
/// That is the whole point: every other harness makes the permission prompt
/// exist only inside the terminal it was asked in.
///
/// **Loop-confined by design**, like `ControlHandoff`: the daemon runs one
/// event-loop thread, every HTTP handler runs on it, so registering a request
/// and resolving it never interleave and this needs no lock.
/// `@unchecked Sendable` because it is captured by the connection-setup
/// closure; every actual access is on that one thread.
final class ApprovalStore: @unchecked Sendable {
    /// What a human decided. `nil` — no decision — is a real answer: it means
    /// the hold expired, and the agent falls back to asking in its own pane.
    enum Decision: Equatable {
        case allow(reason: String?)
        case deny(reason: String?)
    }

    /// A tool call waiting on an answer, as the fleet view sees it.
    struct Pending: Equatable {
        let id: String
        let sessionID: UUID?
        let toolName: String
        /// The tool's own arguments, as compact JSON. Capped: a Write's
        /// contents can be megabytes and nobody approves from a wall of text.
        let toolInput: String
        let createdAt: Date
    }

    private struct Entry {
        let pending: Pending
        let promise: EventLoopPromise<Decision?>
    }

    private var entries: [String: Entry] = [:]

    /// Bounded so a misconfigured hook — or an agent in a retry loop — cannot
    /// grow this without limit. Oldest first, since a stale prompt nobody
    /// answered is worth less than the one that just arrived.
    private let capacity: Int

    init(capacity: Int = KittermConstants.approvalCap) {
        self.capacity = capacity
    }

    /// Register a waiting tool call. The returned future completes with the
    /// decision, or with `nil` if the caller expires it first.
    func register(
        sessionID: UUID?,
        toolName: String,
        toolInput: String,
        on loop: EventLoop
    ) -> (id: String, decision: EventLoopFuture<Decision?>) {
        evictIfFull()
        let id = UUID().uuidString
        let promise = loop.makePromise(of: Decision?.self)
        entries[id] = Entry(
            pending: Pending(
                id: id,
                sessionID: sessionID,
                toolName: toolName,
                toolInput: String(toolInput.prefix(KittermConstants.approvalInputChars)),
                createdAt: Date()
            ),
            promise: promise
        )
        return (id, promise.futureResult)
    }

    /// Answer a waiting call. False when the id is unknown — already answered,
    /// already expired, or never existed; the caller reports 404 either way,
    /// because from outside those are the same thing.
    @discardableResult
    func resolve(id: String, decision: Decision) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.promise.succeed(decision)
        return true
    }

    /// Give up on a call: the hold timed out, or its connection went away.
    /// Completes with no decision, which is what makes the agent fall back to
    /// its own prompt rather than hang.
    func expire(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.promise.succeed(nil)
    }

    /// Everything still waiting, newest last.
    func snapshot() -> [Pending] {
        entries.values.map(\.pending).sorted { $0.createdAt < $1.createdAt }
    }

    var count: Int { entries.count }

    private func evictIfFull() {
        guard entries.count >= capacity else { return }
        let oldest = entries.values.min { $0.pending.createdAt < $1.pending.createdAt }
        if let oldest { expire(id: oldest.pending.id) }
    }
}
