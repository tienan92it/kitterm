import Foundation

/// Coordinates live control transfer between two WebSocket connections of the
/// same session: an observer sends `requestControl`, the current controller is
/// demoted to observer, the requester is promoted, and both get a fresh `role`
/// frame.
///
/// **Loop-confined by design.** Every WebSocket handler runs on the daemon's
/// single event-loop thread, so all access to this class happens on that one
/// thread and the whole swap — take the old controller's step-down closure,
/// run it, promote the requester — executes synchronously with no interleaving
/// window. That is what makes the swap safe without touching `PtySession`'s
/// lock discipline: no new lock, no actor hop between demote and promote.
/// (The `SessionRegistry` actor keeps its attached/linger bookkeeping, updated
/// asynchronously after the fact — a few-ms lag against a 300s linger window.)
/// `@unchecked Sendable`: it crosses into the connection-setup closure, but
/// every actual access happens on the one event-loop thread (see above).
final class ControlHandoff: @unchecked Sendable {
    /// The current controller's step-down closure per session. Invoking it
    /// synchronously demotes that connection to observer (detach → observe,
    /// role frame). Registered whenever a connection becomes controller;
    /// cleared on its teardown.
    private var stepDowns: [UUID: () -> Void] = [:]

    /// Record `connection` as the session's controller.
    func setController(_ session: UUID, stepDown: @escaping () -> Void) {
        stepDowns[session] = stepDown
    }

    /// Remove the controller record on teardown. Safe without an ownership
    /// token: a connection only tears down with the controller role if it was
    /// never demoted, and demotion (which happens synchronously before anyone
    /// else registers) flips its role first — so the entry it clears is
    /// always its own.
    func clearController(_ session: UUID) {
        stepDowns.removeValue(forKey: session)
    }

    /// Take (and remove) the current controller's step-down closure. The
    /// caller runs it, then registers itself via `setController` — all in the
    /// same event-loop tick. Nil when no controller is attached (the previous
    /// one disconnected); the session is then detached and plain `attach`
    /// works.
    func takeStepDown(_ session: UUID) -> (() -> Void)? {
        stepDowns.removeValue(forKey: session)
    }
}
