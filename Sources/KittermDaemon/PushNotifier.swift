import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOConcurrencyHelpers

/// One Web Push message, ready to POST: the push service's endpoint, the
/// headers it reads, and the body sealed for one browser.
public struct PushRequest: Sendable, Equatable {
    public let endpoint: URL
    public let headers: [String: String]
    public let body: Data
}

/// What carries a message to a push service. The daemon uses `URLSession`;
/// a test hands the notifier a transport that records and answers.
public protocol PushTransport: Sendable {
    /// POST the message and return the service's status code, or nil when
    /// no answer came back at all (unreachable, timed out).
    func send(_ request: PushRequest) async -> Int?
}

/// The transport the daemon runs: one `URLSession` request per message,
/// with a short timeout because the loop is not waiting and a phone is not
/// helped by a message that arrives a minute late.
public struct URLSessionPushTransport: PushTransport {
    public static let timeoutSeconds: TimeInterval = 10

    public init() {}

    public func send(_ request: PushRequest) async -> Int? {
        var urlRequest = URLRequest(url: request.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = Self.timeoutSeconds
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        guard let (_, response) = try? await URLSession.shared.data(for: urlRequest) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }
}

/// Sends one message per subscription when a session enters a state a human
/// can act on, and only then.
///
/// ## What it hears
///
/// The daemon never advances a state machine: `mergedState` is computed from
/// three kinds of evidence at read time (`MergedSessionState.merge`). So
/// there is no one place that knows the merged state changed, and this class
/// is told at each place the evidence does: the hook route on a hook
/// transition, on a held approval and on its answer, and the registry when a
/// command ends with an exit code. Each caller hands over the state as the
/// row would show it now, and the memory of the last state handed over is
/// what turns "the evidence changed" into "the state changed".
///
/// ## One per transition
///
/// `observe` sends only when the state differs from the last one it saw for
/// that session and is one of `needs-input`, `needs-approval` or `failed`.
/// A session that sits in `needs-input` for an hour produces one message;
/// `working`, `idle` and `completed` produce none but reset the memory, so
/// the next `needs-input` is a transition again.
///
/// The memory lives in this process only. A restart ends every shell, so
/// nothing that was waiting still exists to be told about twice, and a live
/// upgrade restores each session's last hook report, which is what gates
/// the `agent.status` transition at its source: an unchanged state stays
/// silent there before it could reach here.
///
/// ## Rate limit
///
/// At most `rateLimitPerWindow` messages per session per `rateWindowSeconds`.
/// A message past the limit is dropped and logged, not queued: a human who
/// was told four times in a minute that one session needs them is looking
/// at it already, and a queue would deliver a state the session has left.
///
/// ## Off the loop
///
/// `observe` takes a lock, updates two dictionaries and starts a `Task`. The
/// session lookup, the encryption and the HTTP round trip all run in that
/// task. A push service that answers `404` or `410` has forgotten the
/// subscription for good, and so does the store, through the same
/// `remove(endpoint:)` that `DELETE` uses.
public final class PushNotifier: @unchecked Sendable {
    /// The states a human can act on. `goal.md` excludes the rest.
    public static let actionable: Set<MergedSessionState> = [.needsInput, .needsApproval, .failed]
    public static let rateWindowSeconds: TimeInterval = 60
    public static let rateLimitPerWindow = 4
    /// How long a push service holds a message for a phone that is off.
    public static let ttlSeconds = 3600

    /// What `observe` decided, so a test reads the rule rather than a clock.
    public enum Verdict: Equatable, Sendable {
        /// A transition into an actionable state: a message per subscription is on its way.
        case sent
        /// The same state as last time for this session.
        case unchanged
        /// A transition, but into a state a human cannot act on.
        case notActionable
        /// A transition past the per-session limit; dropped and logged.
        case rateLimited
    }

    private let store: PushSubscriptionStore
    private let keys: VAPIDKeys
    private let registry: SessionRegistry
    private let transport: any PushTransport
    private let lock = NIOLock()
    /// The last state handed over per session.
    private var lastState: [UUID: MergedSessionState] = [:]
    /// When each session's recent messages were decided, newest last.
    private var sentAt: [UUID: [Date]] = [:]
    /// Messages decided so far, for a test to wait on delivery.
    private var decided = 0
    private var delivered = 0

    public init(
        store: PushSubscriptionStore,
        keys: VAPIDKeys,
        registry: SessionRegistry,
        transport: any PushTransport = URLSessionPushTransport()
    ) {
        self.store = store
        self.keys = keys
        self.registry = registry
        self.transport = transport
    }

    /// A session's state as the row shows it now, from whichever caller saw
    /// the evidence change. `reason` is what that caller knows: the hook's
    /// message, the tool waiting on an answer, the exit code.
    @discardableResult
    public func observe(
        _ id: UUID, state: MergedSessionState, reason: String?, now: Date = Date()
    ) -> Verdict {
        let verdict: Verdict = lock.withLock {
            guard lastState[id] != state else { return .unchanged }
            lastState[id] = state
            guard Self.actionable.contains(state) else { return .notActionable }
            var recent = (sentAt[id] ?? []).filter { now.timeIntervalSince($0) < Self.rateWindowSeconds }
            guard recent.count < Self.rateLimitPerWindow else {
                sentAt[id] = recent
                return .rateLimited
            }
            recent.append(now)
            sentAt[id] = recent
            decided += 1
            return .sent
        }
        switch verdict {
        case .sent:
            Task { await self.deliver(id, state: state, reason: reason, at: now) }
        case .rateLimited:
            FileHandle.standardError.write(Data(
                "kitterm: push for session \(id.uuidString) (\(state.rawValue)) dropped: over \(Self.rateLimitPerWindow) in \(Int(Self.rateWindowSeconds))s\n".utf8
            ))
        case .unchanged, .notActionable:
            break
        }
        return verdict
    }

    /// The session is gone: drop what was remembered about it, so the tables
    /// stay bounded by the live fleet.
    public func forget(_ id: UUID) {
        lock.withLock {
            lastState[id] = nil
            sentAt[id] = nil
        }
    }

    /// True once every message `observe` decided has been answered or given
    /// up on. A test waits on this instead of on a clock.
    public var isDrained: Bool { lock.withLock { decided == delivered } }

    private func deliver(_ id: UUID, state: MergedSessionState, reason: String?, at: Date) async {
        defer { lock.withLock { delivered += 1 } }
        // The session named at send time, the way the row would name it. One
        // removed between the decision and now has nothing to be told about.
        guard let summary = await registry.summary(id) else { return }
        let payload = Self.payload(for: summary, state: state, reason: reason, at: at)
        for subscription in store.all {
            guard let endpoint = URL(string: subscription.endpoint),
                  let authorization = keys.authorization(for: endpoint, now: at)
            else {
                log("cannot address \(subscription.endpoint)")
                continue
            }
            let body: Data
            do {
                body = try WebPush.encrypt(payload, p256dh: subscription.p256dh, auth: subscription.auth)
            } catch let failure as WebPush.EncryptionFailure {
                log("cannot encrypt for \(endpoint.host ?? subscription.endpoint): \(failure.reason)")
                continue
            } catch {
                log("cannot encrypt for \(endpoint.host ?? subscription.endpoint): \(error)")
                continue
            }
            var headers = WebPush.headers(ttlSeconds: Self.ttlSeconds)
            headers["Authorization"] = authorization
            let status = await transport.send(PushRequest(endpoint: endpoint, headers: headers, body: body))
            switch status {
            case .some(200 ..< 300):
                break
            case .some(404), .some(410):
                // RFC 8030 §5: the subscription is gone for good. Forget it
                // the way DELETE does, so the file agrees.
                store.remove(endpoint: subscription.endpoint)
                log("\(endpoint.host ?? subscription.endpoint) answered \(status ?? 0); subscription forgotten")
            case .some(let code):
                log("\(endpoint.host ?? subscription.endpoint) answered \(code)")
            case .none:
                log("\(endpoint.host ?? subscription.endpoint) did not answer")
            }
        }
    }

    /// What the phone receives, once decrypted: the session, its state, the
    /// name and the project the row would show, the reason, and a title and
    /// body already composed so a service worker can show them as they are.
    /// `url` is the pane to open. Sorted keys, so the bytes are stable.
    static func payload(
        for summary: SessionRegistry.SessionSummary, state: MergedSessionState, reason: String?, at: Date
    ) -> Data {
        let name = summary.name ?? "session \(summary.id.uuidString.prefix(8))"
        var reason = reason
        if state == .failed {
            let derived = DerivedSessionState.derive(from: summary.marks)
            if let command = derived.lastCommand {
                reason = [reason, command].compactMap { $0 }.joined(separator: ": ")
            }
        }
        let phrase: String
        switch state {
        case .needsInput: phrase = "needs input"
        case .needsApproval: phrase = "needs approval"
        case .failed: phrase = "failed"
        default: phrase = state.rawValue
        }
        var item: [String: Any] = [
            "session": summary.id.uuidString,
            "state": state.rawValue,
            "name": name,
            "title": "\(name) \(phrase)",
            "body": [summary.project?.name, reason].compactMap { $0 }.joined(separator: " · "),
            "url": "/?session=\(summary.id.uuidString)",
            "at": Int(at.timeIntervalSince1970 * 1000),
        ]
        if let project = summary.project { item["project"] = project.name }
        if let reason { item["reason"] = reason }
        return (try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])) ?? Data()
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("kitterm: push: \(line)\n".utf8))
    }
}

/// The registry's side of the evidence: a command that ended is `failed`
/// when its exit is non-zero and `idle` otherwise, because the mark that
/// just landed is the newest evidence the merge rule has. A removed session
/// is forgotten.
extension PushNotifier: SessionRegistryObserver {
    public func commandEnded(session id: UUID, exit: Int32) {
        if exit == 0 {
            observe(id, state: .idle, reason: nil)
        } else {
            observe(id, state: .failed, reason: "exit \(exit)")
        }
    }

    public func sessionRemoved(_ id: UUID) {
        forget(id)
    }
}
