import Foundation
import KittermProtocol

/// Tracks live PTY sessions. A session survives a transient WS disconnect
/// (sleep/wake, network blip): it is marked detached and reaped only if no
/// client reattaches within the linger window.
public actor SessionRegistry {
    /// How long a program-created session is held after its last client
    /// disconnects, so an orchestrator that restarts finds its nodes running.
    /// Bounded so a crash cannot leak shells forever.
    private let orchestratedLinger: Int

    public init(
        orchestratedLingerSeconds: Int = KittermConstants.orchestratedSessionLingerSeconds
    ) {
        self.orchestratedLinger = orchestratedLingerSeconds
    }

    private var sessions: [UUID: PtySession] = [:]
    private var attachedIDs: Set<UUID> = []
    private var lingerTasks: [UUID: Task<Void, Never>] = [:]

    public var count: Int {
        sessions.count
    }

    /// Admit a session, or return nil at `maxConcurrentSessions`. The check
    /// lives here because it is the only place it is atomic — counting and
    /// inserting as separate awaits lets concurrent opens slip past the cap.
    public func register(_ session: PtySession) -> UUID? {
        guard sessions.count < KittermConstants.maxConcurrentSessions else { return nil }
        let id = UUID()
        sessions[id] = session
        attachedIDs.insert(id)
        return id
    }

    /// Read-only lookup (API handlers); does not affect controller claims.
    public func session(_ id: UUID) -> PtySession? {
        sessions[id]
    }

    /// Watch-grade lookup: the session for observing, without ever claiming
    /// control. Cancels the linger clock — someone is watching.
    public func observe(_ id: UUID) -> PtySession? {
        guard let session = sessions[id], session.isRunning else { return nil }
        lingerTasks.removeValue(forKey: id)?.cancel()
        return session
    }

    /// A point-in-time view of one session for the listing API.
    public struct SessionSummary: Sendable {
        public let id: UUID
        public let shell: String
        public let cwd: String
        public let pid: Int32
        /// A controller is attached (vs. detached, awaiting reattach).
        public let attached: Bool
        public let observerCount: Int
        /// Session profile this shell was started from, if any.
        public let profile: String?
        /// Orchestrator tags, for attributing a session to a graph node.
        public let labels: [String: String]
        /// Shell-integration marks, newest last — the caller derives state.
        public let marks: [SessionMark]
        /// The shell has exited; the session is kept only so its records can
        /// still be read, and it cannot be attached to.
        public let exited: Bool
        /// How the shell exited, when it has.
        public let exitCode: Int32?
    }

    /// Every live session, for `/api/sessions`. Ordered by id for stability.
    public func summaries() -> [SessionSummary] {
        sessions
            .map { id, session in
                SessionSummary(
                    id: id,
                    shell: session.shellPath,
                    cwd: session.liveCwd,
                    pid: session.pid,
                    attached: attachedIDs.contains(id),
                    observerCount: session.observerCount,
                    profile: session.profileName,
                    labels: session.labels.values,
                    marks: session.marksSnapshot(),
                    exited: !session.isRunning,
                    exitCode: session.exitCode
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public enum SessionResolution: Sendable {
        /// No controller attached — the caller becomes it.
        case controller(PtySession)
        /// Another client controls the session — the caller may observe.
        case observer(PtySession)
        case notFound
    }

    /// Resolve a session link: first client in becomes controller, later
    /// clients become read-only observers.
    public func resolve(_ id: UUID) -> SessionResolution {
        guard let session = sessions[id] else { return .notFound }
        guard session.isRunning else {
            // A labelled session is kept after its shell dies so its records
            // can still be read, so looking at it must not reap it.
            if session.labels.isEmpty { removeInternal(id) }
            return .notFound
        }
        lingerTasks.removeValue(forKey: id)?.cancel()
        if attachedIDs.contains(id) {
            return .observer(session)
        }
        attachedIDs.insert(id)
        return .controller(session)
    }

    /// A promoted observer now controls the session (live control handoff):
    /// record it attached and stop any linger clock. The swap itself ran
    /// synchronously on the event loop; this bookkeeping arrives a beat later,
    /// which is harmless against the 300s linger window.
    public func claimControl(_ id: UUID) {
        guard sessions[id] != nil else { return }
        lingerTasks.removeValue(forKey: id)?.cancel()
        attachedIDs.insert(id)
    }

    /// Controller went away; keep the session for the linger window.
    /// (`PtySession.detach()` has already been called by the handler.)
    public func markDetached(_ id: UUID) {
        guard let session = sessions[id] else { return }
        attachedIDs.remove(id)
        if session.observerCount == 0 {
            scheduleLinger(id)
        }
    }

    /// An observer disconnected; if nobody is left, start the linger clock.
    public func observerLeft(_ id: UUID) {
        guard let session = sessions[id] else { return }
        if !attachedIDs.contains(id), session.observerCount == 0 {
            scheduleLinger(id)
        }
    }

    private func scheduleLinger(_ id: UUID) {
        lingerTasks[id]?.cancel()
        // A tab that went away is probably closed for good; a program's session
        // is probably mid-run with its caller restarting.
        let window = sessions[id]?.labels.isEmpty == false
            ? orchestratedLinger
            : KittermConstants.sessionDetachLingerSeconds
        lingerTasks[id] = Task { [weak self] in
            // Suspending clock: machine sleep must not consume the window.
            try? await Task.sleep(for: .seconds(window), clock: .suspending)
            guard !Task.isCancelled else { return }
            await self?.reapIfStillDetached(id)
        }
    }

    /// The shell exited. A program-created session stays for its linger window
    /// so `/commands` and retained output still answer — a node that crashed is
    /// exactly the one a caller wants to inspect. A browser tab's session goes
    /// now, as before; nobody wants a corpse in the fleet view.
    public func sessionDidExit(_ id: UUID) {
        guard let session = sessions[id] else { return }
        guard !session.labels.isEmpty else {
            removeInternal(id)
            return
        }
        attachedIDs.remove(id)
        scheduleLinger(id)
    }

    public func remove(_ id: UUID) {
        removeInternal(id)
    }

    public func terminateAll() {
        for (_, session) in sessions {
            session.terminate()
            session.discardRetainedOutput()
        }
        for (_, task) in lingerTasks {
            task.cancel()
        }
        sessions.removeAll()
        attachedIDs.removeAll()
        lingerTasks.removeAll()
    }

    private func reapIfStillDetached(_ id: UUID) {
        // An exited session is reaped when its window is up regardless: its
        // shell is already gone, and a reader must not hold the records open
        // forever.
        if let session = sessions[id], !session.isRunning {
            removeInternal(id)
            return
        }
        guard !attachedIDs.contains(id) else { return }
        if let session = sessions[id], session.observerCount > 0 { return }
        removeInternal(id)
    }

    private func removeInternal(_ id: UUID) {
        lingerTasks.removeValue(forKey: id)?.cancel()
        attachedIDs.remove(id)
        if let session = sessions.removeValue(forKey: id) {
            session.terminate()
            session.discardRetainedOutput()
            SessionDrops.discard(sessionID: id)
        }
    }
}
