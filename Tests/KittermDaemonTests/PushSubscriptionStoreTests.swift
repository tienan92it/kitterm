import Foundation
import XCTest

@testable import KittermDaemon

/// `PushSubscriptionStore` on its own: what it accepts, what the file holds,
/// and what a reader does with a file it was not built for.
final class PushSubscriptionStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("push.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-push-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private static let p256dh = "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM"
    private static let auth = "tBHItJI5svbpez7KI4CCXg"

    private func subscription(_ endpoint: String, auth: String = PushSubscriptionStoreTests.auth) -> PushSubscription {
        PushSubscription(endpoint: endpoint, p256dh: Self.p256dh, auth: auth, createdAt: 1_757_000_000_000)
    }

    // MARK: - Parsing the browser's shape

    /// `PushSubscription.toJSON()` as Chrome and Safari hand it to the page,
    /// `expirationTime` included, which decodes away.
    func testParsesTheBrowsersShape() throws {
        let json: [String: Any] = [
            "endpoint": "https://fcm.googleapis.com/fcm/send/abc",
            "expirationTime": NSNull(),
            "keys": ["p256dh": Self.p256dh, "auth": Self.auth],
        ]
        let parsed = try PushSubscription.parse(json, now: Date(timeIntervalSince1970: 1_757_000_000)).get()
        XCTAssertEqual(parsed.endpoint, "https://fcm.googleapis.com/fcm/send/abc")
        XCTAssertEqual(parsed.p256dh, Self.p256dh)
        XCTAssertEqual(parsed.auth, Self.auth)
        XCTAssertEqual(parsed.createdAt, 1_757_000_000_000)
    }

    func testRefusesWhatThePushServiceWouldRefuse() {
        let good: [String: Any] = ["p256dh": Self.p256dh, "auth": Self.auth]
        let cases: [(String, [String: Any])] = [
            ("no endpoint", ["keys": good]),
            ("http endpoint", ["endpoint": "http://push.example/1", "keys": good]),
            ("not a URL", ["endpoint": "push", "keys": good]),
            ("endpoint too long", ["endpoint": "https://push.example/" + String(repeating: "a", count: 2048), "keys": good]),
            ("no keys", ["endpoint": "https://push.example/1"]),
            ("empty auth", ["endpoint": "https://push.example/1", "keys": ["p256dh": Self.p256dh, "auth": ""]]),
            ("auth not base64url", ["endpoint": "https://push.example/1", "keys": ["p256dh": Self.p256dh, "auth": "a b/c"]]),
            ("p256dh missing", ["endpoint": "https://push.example/1", "keys": ["auth": Self.auth]]),
        ]
        for (name, json) in cases {
            guard case .failure = PushSubscription.parse(json) else {
                return XCTFail("\(name) was accepted")
            }
        }
    }

    // MARK: - The file

    func testTheFileIsVersionedOwnerOnlyAndHoldsNothingButTheSubscription() throws {
        let store = PushSubscriptionStore(file: file)
        XCTAssertEqual(store.upsert(subscription("https://push.example/1")), .created)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(mode & 0o777, 0o600)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(Set(json.keys), ["version", "subscriptions"])
        let entries = try XCTUnwrap(json["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(Set(entries[0].keys), ["endpoint", "p256dh", "auth", "createdAt"],
                       "no session, no project, no token: a subscription names a browser")
    }

    func testASecondStoreReadsWhatTheFirstWrote() {
        let first = PushSubscriptionStore(file: file)
        _ = first.upsert(subscription("https://push.example/1"))
        _ = first.upsert(subscription("https://push.example/2"))

        let second = PushSubscriptionStore(file: file)
        XCTAssertEqual(second.all.map(\.endpoint), ["https://push.example/1", "https://push.example/2"])
    }

    /// The same endpoint posted again replaces the keys, keeps the first
    /// `createdAt`, and is still one entry.
    func testTheSameEndpointIsStoredOnceAndTheLaterKeysWin() {
        let store = PushSubscriptionStore(file: file)
        XCTAssertEqual(store.upsert(subscription("https://push.example/1")), .created)
        var later = subscription("https://push.example/1", auth: "newauth_newauth_newaut")
        later.createdAt = 1_757_009_999_000
        XCTAssertEqual(store.upsert(later), .updated)
        XCTAssertEqual(store.upsert(later), .updated, "an identical re-post is still an update")

        XCTAssertEqual(store.count, 1)
        let stored = PushSubscriptionStore(file: file).all
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].auth, "newauth_newauth_newaut")
        XCTAssertEqual(stored[0].createdAt, 1_757_000_000_000, "the first creation time stays")
    }

    func testRemoveForgetsAnEndpointAndSaysWhetherItWasThere() {
        let store = PushSubscriptionStore(file: file)
        _ = store.upsert(subscription("https://push.example/1"))
        XCTAssertTrue(store.remove(endpoint: "https://push.example/1"))
        XCTAssertFalse(store.remove(endpoint: "https://push.example/1"))
        XCTAssertEqual(PushSubscriptionStore(file: file).count, 0)
    }

    func testTheCapRefusesANewEndpointAndStillUpdatesAStoredOne() {
        let store = PushSubscriptionStore(file: file)
        for n in 0..<PushSubscriptionStore.maxSubscriptions {
            XCTAssertEqual(store.upsert(subscription("https://push.example/\(n)")), .created)
        }
        XCTAssertEqual(store.upsert(subscription("https://push.example/overflow")), .full)
        XCTAssertEqual(store.upsert(subscription("https://push.example/0", auth: "other_other_other_othe")), .updated)
        XCTAssertEqual(store.count, PushSubscriptionStore.maxSubscriptions)
    }

    // MARK: - A file this build was not built for

    func testAnUnknownVersionReadsAsEmptyAndIsNotRewrittenUntilAChange() throws {
        try Data(#"{"version":2,"subscriptions":[{"endpoint":"https://push.example/1","p256dh":"a","auth":"b","createdAt":1,"extra":true}]}"#.utf8)
            .write(to: file)
        let store = PushSubscriptionStore(file: file)
        XCTAssertEqual(store.count, 0, "a wrong guess about who to notify is worse than none")
        XCTAssertTrue(try String(contentsOf: file).contains(#""version":2"#), "reading does not write")
    }

    func testAnUnknownFieldDecodesAway() throws {
        try Data(#"{"version":1,"subscriptions":[{"endpoint":"https://push.example/1","p256dh":"a","auth":"b","createdAt":1,"later":"x"}]}"#.utf8)
            .write(to: file)
        XCTAssertEqual(PushSubscriptionStore(file: file).all.map(\.endpoint), ["https://push.example/1"])
    }

    func testGarbageReadsAsEmpty() throws {
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(PushSubscriptionStore(file: file).count, 0)
    }
}
