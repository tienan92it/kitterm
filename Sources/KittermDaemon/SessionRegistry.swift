import Foundation

public actor SessionRegistry {
    private var sessions: [UUID: PtySession] = [:]

    public init() {}

    public var count: Int {
        sessions.count
    }

    public func register(_ session: PtySession) -> UUID {
        let id = UUID()
        sessions[id] = session
        return id
    }

    public func remove(_ id: UUID) {
        if let session = sessions.removeValue(forKey: id) {
            session.terminate()
        }
    }

    public func terminateAll() {
        for (_, session) in sessions {
            session.terminate()
        }
        sessions.removeAll()
    }
}
