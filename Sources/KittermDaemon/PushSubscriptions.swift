import Foundation
import NIOConcurrencyHelpers

/// One browser's Web Push subscription, as `PushSubscription.toJSON()` hands
/// it to the page: the push service's endpoint and the two keys the service
/// needs to deliver an encrypted message to that browser.
///
/// The record names a browser, never a session or a project. A phone
/// subscribes once, and every message it later receives is composed at send
/// time from the session that needs a human. Anything session-shaped here
/// would be a stale copy of what the sender already has.
public struct PushSubscription: Codable, Equatable, Sendable {
    /// The push service URL the browser was given. Unique per subscription;
    /// the store's key.
    public var endpoint: String
    /// The browser's P-256 public key, base64url (`keys.p256dh`).
    public var p256dh: String
    /// The browser's 16-byte authentication secret, base64url (`keys.auth`).
    public var auth: String
    /// Epoch milliseconds, when the daemon first stored this endpoint. A
    /// re-post of the same endpoint keeps it.
    public var createdAt: Int64

    public init(endpoint: String, p256dh: String, auth: String, createdAt: Int64) {
        self.endpoint = endpoint
        self.p256dh = p256dh
        self.auth = auth
        self.createdAt = createdAt
    }

    /// Bounds a browser's subscription stays inside. A real endpoint is a
    /// few hundred bytes; a real `p256dh` is 87 characters and a real `auth`
    /// 22. The caps refuse a body that could only be a mistake or an attack.
    public static let maxEndpointBytes = 2048
    public static let maxKeyBytes = 256

    /// Why a body was refused, in the words the 400 carries.
    public struct Invalid: Error, Equatable, Sendable {
        public let reason: String
    }

    /// Parse the browser's JSON (`{endpoint, keys: {p256dh, auth}}`), refusing
    /// a shape the push service would reject anyway. `expirationTime` and
    /// any other field decode away.
    public static func parse(_ json: [String: Any], now: Date = Date()) -> Result<PushSubscription, Invalid> {
        guard let endpoint = json["endpoint"] as? String else {
            return .failure(Invalid(reason: "endpoint must be a string"))
        }
        guard endpoint.utf8.count <= maxEndpointBytes,
              let url = URL(string: endpoint), url.scheme == "https", let host = url.host, !host.isEmpty
        else {
            return .failure(Invalid(reason: "endpoint must be an https URL"))
        }
        guard let keys = json["keys"] as? [String: Any] else {
            return .failure(Invalid(reason: "keys must be {p256dh, auth}"))
        }
        guard let p256dh = keys["p256dh"] as? String, isBase64URL(p256dh) else {
            return .failure(Invalid(reason: "keys.p256dh must be base64url"))
        }
        guard let auth = keys["auth"] as? String, isBase64URL(auth) else {
            return .failure(Invalid(reason: "keys.auth must be base64url"))
        }
        return .success(PushSubscription(
            endpoint: endpoint, p256dh: p256dh, auth: auth,
            createdAt: Int64(now.timeIntervalSince1970 * 1000)
        ))
    }

    /// Non-empty, within `maxKeyBytes`, and only the base64url alphabet. The
    /// browser strips the padding; a `=` is accepted so a hand-made client
    /// that keeps it is not refused for nothing.
    static func isBase64URL(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maxKeyBytes else { return false }
        return text.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F || byte == 0x3D
        }
    }
}

/// The subscriptions the daemon keeps, on disk at `~/.kitterm/push.json`.
///
/// ## What the file survives
///
/// The browser keys a subscription to the page's origin, and behind
/// `tailscale serve` the origin carries no port, so the phone's subscription
/// is still valid after a daemon restart, a port change and a live upgrade.
/// The daemon must therefore still have it after all three. The store loads
/// the file once at construction and rewrites the whole file on every
/// change, the way `RespawnHintStore` does: a restarted daemon and a
/// takeover successor each build a fresh store from the file, and nothing is
/// carried through `TakeoverState`, because the disk already carries it.
///
/// ## What the file holds
///
/// `version`, then one entry per endpoint with the endpoint, the two keys the
/// browser handed the page, and when it was first stored. Nothing else: no
/// session, no project, no token, no VAPID key. The keys are the only secret,
/// and they are the browser's own; whoever holds them can send that browser
/// a message, which is why the file is `0600` like every other file here. A
/// VAPID key pair, when capability 3 needs one, is a daemon secret of another
/// class and belongs in its own file.
///
/// ## One per endpoint
///
/// A second post of an endpoint replaces its keys and answers as an update.
/// The page cannot know whether the daemon still has its subscription, so it
/// posts on every load; rejecting the repeat would make that idempotent
/// re-post an error, and the browser's latest statement about its own keys
/// is the true one.
///
/// ## Removal
///
/// `remove(endpoint:)` serves both `DELETE /api/push/subscriptions` and the
/// sender that sees a `410 Gone` from the push service. The sender owns that
/// removal because it is the one that sees the answer; the store only has to
/// make forgetting an endpoint one call.
///
/// Every method is synchronous under a lock. The route hops onto `queue`
/// before it calls one, so the disk write never runs on the event loop; a
/// sender running in its own `Task` may call directly.
public final class PushSubscriptionStore: @unchecked Sendable {
    public static let formatVersion = 1
    /// A phone or two per human is the shape; the cap stops a full-grade
    /// caller from growing the file without bound.
    public static let maxSubscriptions = 32
    /// Where the HTTP routes run the store's disk I/O, off the event loop.
    static let queue = DispatchQueue(label: "kitterm.push")

    private struct FileShape: Codable {
        var version: Int
        var subscriptions: [PushSubscription]
    }

    /// What a post did.
    public enum Upsert: Equatable, Sendable {
        case created
        case updated
        /// `maxSubscriptions` reached and the endpoint is new.
        case full
    }

    private let file: URL
    private let lock = NIOLock()
    /// In post order, so the file reads oldest first.
    private var subscriptions: [PushSubscription]

    public init(file: URL) {
        self.file = file
        self.subscriptions = Self.load(file)
    }

    /// Store a subscription, or replace the keys of the one with the same
    /// endpoint. The first `createdAt` is kept on a replace.
    public func upsert(_ subscription: PushSubscription) -> Upsert {
        lock.withLock {
            if let index = subscriptions.firstIndex(where: { $0.endpoint == subscription.endpoint }) {
                var replaced = subscription
                replaced.createdAt = subscriptions[index].createdAt
                guard replaced != subscriptions[index] else { return .updated }
                subscriptions[index] = replaced
                persistLocked()
                return .updated
            }
            guard subscriptions.count < Self.maxSubscriptions else { return .full }
            subscriptions.append(subscription)
            persistLocked()
            return .created
        }
    }

    /// Forget an endpoint. False when the store did not have it.
    @discardableResult
    public func remove(endpoint: String) -> Bool {
        lock.withLock {
            let before = subscriptions.count
            subscriptions.removeAll { $0.endpoint == endpoint }
            guard subscriptions.count != before else { return false }
            persistLocked()
            return true
        }
    }

    /// Every stored subscription, for a sender to iterate.
    public var all: [PushSubscription] { lock.withLock { subscriptions } }

    public var count: Int { lock.withLock { subscriptions.count } }

    /// The file's entries, or none when the file is absent, unreadable, or a
    /// version this build was not built for. A wrong guess about who to
    /// notify is worse than a phone that must subscribe again.
    private static func load(_ file: URL) -> [PushSubscription] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        do {
            let shape = try JSONDecoder().decode(FileShape.self, from: data)
            guard shape.version == formatVersion else {
                FileHandle.standardError.write(Data(
                    "kitterm: ignoring \(file.path): format version \(shape.version), expected \(formatVersion)\n".utf8
                ))
                return []
            }
            return shape.subscriptions
        } catch {
            FileHandle.standardError.write(Data("kitterm: ignoring \(file.path): \(error)\n".utf8))
            return []
        }
    }

    /// Caller holds `lock`. Whole-file atomic replace, then owner-only, the
    /// order `tokens.json` and `projects.json` use.
    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(FileShape(version: Self.formatVersion, subscriptions: subscriptions))
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            FileHandle.standardError.write(Data("kitterm: cannot write \(file.path): \(error)\n".utf8))
        }
    }
}
