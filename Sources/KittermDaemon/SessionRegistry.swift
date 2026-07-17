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

    /// Reattach: returns the session if it exists, is detached, and still runs.
    public func claim(_ id: UUID) -> PtySession? {
        guard let session = sessions[id], !attachedIDs.contains(id) else {
            return nil
        }
        guard session.isRunning else {
            removeInternal(id)
            return nil
        }
        lingerTasks.removeValue(forKey: id)?.cancel()
        attachedIDs.insert(id)
        return session
    }

    /// Client went away; keep the session for the linger window.
    /// (`PtySession.detach()` has already been called by the handler.)
    public func markDetached(_ id: UUID) {
        guard sessions[id] != nil else { return }
        attachedIDs.remove(id)
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
