import Foundation
import KittermProtocol

/// Tracks live PTY sessions. A session survives a transient WS disconnect
/// (sleep/wake, network blip): it is marked detached and reaped only if no
/// client reattaches within the linger window.
public actor SessionRegistry {
    private var sessions: [UUID: PtySession] = [:]
    private var attachedIDs: Set<UUID> = []
    private var lingerTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public var count: Int {
        sessions.count
    }

    public func register(_ session: PtySession) -> UUID {
        let id = UUID()
        sessions[id] = session
        attachedIDs.insert(id)
        return id
    }

    /// Read-only lookup (API handlers); does not affect controller claims.
    public func session(_ id: UUID) -> PtySession? {
        sessions[id]
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
            removeInternal(id)
            return .notFound
        }
        lingerTasks.removeValue(forKey: id)?.cancel()
        if attachedIDs.contains(id) {
            return .observer(session)
        }
        attachedIDs.insert(id)
        return .controller(session)
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
        lingerTasks[id] = Task { [weak self] in
            // Suspending clock: machine sleep must not consume the window.
            try? await Task.sleep(
                for: .seconds(KittermConstants.sessionDetachLingerSeconds),
                clock: .suspending
            )
            guard !Task.isCancelled else { return }
            await self?.reapIfStillDetached(id)
        }
    }

    public func remove(_ id: UUID) {
        removeInternal(id)
    }

    public func terminateAll() {
        for (_, session) in sessions {
            session.terminate()
        }
        for (_, task) in lingerTasks {
            task.cancel()
        }
        sessions.removeAll()
        attachedIDs.removeAll()
        lingerTasks.removeAll()
    }

    private func reapIfStillDetached(_ id: UUID) {
        guard !attachedIDs.contains(id) else { return }
        if let session = sessions[id], session.observerCount > 0 { return }
        removeInternal(id)
    }

    private func removeInternal(_ id: UUID) {
        lingerTasks.removeValue(forKey: id)?.cancel()
        attachedIDs.remove(id)
        if let session = sessions.removeValue(forKey: id) {
            session.terminate()
        }
    }
}
