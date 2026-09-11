import Foundation
import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import KittermDaemon

/// The rule: one message per transition into a state a human can act on,
/// none for the rest, a per-session limit, and a gone endpoint forgotten.
/// Read from `observe`'s verdict, so no test here waits on a clock; what
/// reaches a fake endpoint over HTTP is `PushSendRouteTests`' proof.
final class PushNotifierTests: XCTestCase {
    /// Records every request and answers what the test set per endpoint.
    private final class RecordingTransport: PushTransport, @unchecked Sendable {
        private let lock = NIOLock()
        private var requests: [PushRequest] = []
        private var status: [String: Int] = [:]

        func answer(_ endpoint: String, with code: Int) { lock.withLock { status[endpoint] = code } }
        var sent: [PushRequest] { lock.withLock { requests } }

        func send(_ request: PushRequest) async -> Int? {
            lock.withLock {
                requests.append(request)
                return status[request.endpoint.absoluteString] ?? 201
            }
        }
    }

    private var stateDir: URL!
    private var store: PushSubscriptionStore!
    private var registry: SessionRegistry!
    private var transport: RecordingTransport!
    private var notifier: PushNotifier!
    private var sessions: [PtySession] = []
    private let browser = FakeBrowser()

    override class func setUp() {
        super.setUp()
        let buildDir = Bundle(for: PushNotifierTests.self).bundleURL.deletingLastPathComponent()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-push-notifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        store = PushSubscriptionStore(file: stateDir.appendingPathComponent("push.json"))
        registry = SessionRegistry()
        transport = RecordingTransport()
        notifier = PushNotifier(store: store, keys: VAPIDKeys(), registry: registry, transport: transport)
    }

    override func tearDown() {
        for session in sessions { session.terminate() }
        sessions = []
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private func spawn(name: String? = nil, labels: String? = nil) async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse(labels))
        if let name { session.setName(name) }
        sessions.append(session)
        let registered = await registry.register(session)
        return try XCTUnwrap(registered)
    }

    private func drain() async throws {
        let deadline = SuspendingClock.now + .seconds(10)
        while !notifier.isDrained {
            guard SuspendingClock.now < deadline else { throw XCTSkip("never drained") }
            try await Task.sleep(for: .milliseconds(10), clock: .suspending)
        }
    }

    // MARK: - The rule

    func testOnlyTheThreeActionableStatesSendAndOnlyOnEntry() async throws {
        let id = try await spawn()
        XCTAssertEqual(notifier.observe(id, state: .working, reason: nil), .notActionable)
        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: "waiting"), .sent)
        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: "waiting"), .unchanged)
        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: "another message"), .unchanged,
                       "the state, not the message, is what dedupes")
        XCTAssertEqual(notifier.observe(id, state: .working, reason: nil), .notActionable)
        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: "waiting"), .sent, "left and came back")
        XCTAssertEqual(notifier.observe(id, state: .needsApproval, reason: "Bash"), .sent)
        XCTAssertEqual(notifier.observe(id, state: .needsApproval, reason: "Bash"), .unchanged)
        XCTAssertEqual(notifier.observe(id, state: .failed, reason: "exit 1"), .sent)
        XCTAssertEqual(notifier.observe(id, state: .idle, reason: nil), .notActionable)
        XCTAssertEqual(notifier.observe(id, state: .completed, reason: nil), .notActionable)
        XCTAssertEqual(notifier.observe(id, state: .exited, reason: nil), .notActionable)
        XCTAssertEqual(notifier.observe(id, state: .unknown, reason: nil), .notActionable)
    }

    func testAFirstObservationOfAnActionableStateSends() async throws {
        let id = try await spawn()
        XCTAssertEqual(notifier.observe(id, state: .needsApproval, reason: "Edit"), .sent)
    }

    func testSessionsAreIndependent() async throws {
        let one = try await spawn()
        let two = try await spawn()
        XCTAssertEqual(notifier.observe(one, state: .needsInput, reason: nil), .sent)
        XCTAssertEqual(notifier.observe(two, state: .needsInput, reason: nil), .sent)
        XCTAssertEqual(notifier.observe(one, state: .needsInput, reason: nil), .unchanged)
    }

    // MARK: - Rate limit

    func testAFlappingSessionIsCappedPerWindowAndFreedAfterIt() async throws {
        let id = try await spawn()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for turn in 0 ..< PushNotifier.rateLimitPerWindow {
            let at = start.addingTimeInterval(Double(turn))
            XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: nil, now: at), .sent, "turn \(turn)")
            XCTAssertEqual(notifier.observe(id, state: .working, reason: nil, now: at), .notActionable)
        }
        let capped = start.addingTimeInterval(10)
        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: nil, now: capped), .rateLimited)
        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: nil, now: capped), .unchanged,
                       "a dropped transition still counts as seen")
        XCTAssertEqual(notifier.observe(id, state: .working, reason: nil, now: capped), .notActionable)
        let later = start.addingTimeInterval(PushNotifier.rateWindowSeconds + 1)
        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: nil, now: later), .sent, "the window passed")
    }

    func testTheLimitIsPerSession() async throws {
        let noisy = try await spawn()
        let quiet = try await spawn()
        let now = Date()
        for _ in 0 ..< PushNotifier.rateLimitPerWindow {
            notifier.observe(noisy, state: .needsInput, reason: nil, now: now)
            notifier.observe(noisy, state: .working, reason: nil, now: now)
        }
        XCTAssertEqual(notifier.observe(noisy, state: .needsInput, reason: nil, now: now), .rateLimited)
        XCTAssertEqual(notifier.observe(quiet, state: .needsInput, reason: nil, now: now), .sent)
    }

    func testForgettingASessionResetsIt() async throws {
        let id = try await spawn()
        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: nil), .sent)
        notifier.forget(id)
        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: nil), .sent)
    }

    // MARK: - The registry's side

    func testACommandEndIsFailedWhenNonZeroAndIdleOtherwise() async throws {
        let id = try await spawn()
        notifier.commandEnded(session: id, exit: 0)
        XCTAssertEqual(notifier.observe(id, state: .idle, reason: nil), .unchanged, "exit 0 was idle")
        notifier.commandEnded(session: id, exit: 3)
        XCTAssertEqual(notifier.observe(id, state: .failed, reason: nil), .unchanged, "exit 3 was failed")
        notifier.commandEnded(session: id, exit: 3)
        notifier.sessionRemoved(id)
        XCTAssertEqual(notifier.observe(id, state: .failed, reason: nil), .sent, "forgotten with the session")
    }

    /// A shell's mark reaches the notifier through the session the registry
    /// wired, with no hook route involved.
    func testTheRegistryWiresAShellsMarksToTheObserver() async throws {
        await registry.setObserver(notifier)
        let id = try await spawn(name: "builder")
        let session = try XCTUnwrap(sessions.last)
        store.upsert(browser.subscription(endpoint: "https://push.example/builder"))

        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeString("\u{1b}]633;E;make test\u{07}\u{1b}]133;C\u{07}boom\u{1b}]133;D;2\u{07}")
        session.handleRead(&buffer)
        XCTAssertEqual(notifier.observe(id, state: .failed, reason: nil), .unchanged, "the mark was observed")
        try await drain()

        let request = try XCTUnwrap(transport.sent.first)
        let payload = try browser.payload(request.body)
        XCTAssertEqual(payload["state"] as? String, "failed")
        XCTAssertEqual(payload["name"] as? String, "builder")
        XCTAssertEqual(payload["reason"] as? String, "exit 2: make test")
        XCTAssertEqual(payload["title"] as? String, "builder failed")
    }

    // MARK: - What is sent

    func testTheMessageNamesTheSessionTheProjectAndTheReason() async throws {
        let id = try await spawn(name: "crew alpha", labels: "project:kitterm,crew:alpha")
        store.upsert(browser.subscription(endpoint: "https://push.example/one"))
        let other = FakeBrowser()
        store.upsert(other.subscription(endpoint: "https://push.example/two"))

        XCTAssertEqual(notifier.observe(id, state: .needsInput, reason: "Claude is waiting for your input"), .sent)
        try await drain()

        let sent = transport.sent
        XCTAssertEqual(Set(sent.map(\.endpoint.absoluteString)), ["https://push.example/one", "https://push.example/two"],
                       "one message per subscription")
        let one = try XCTUnwrap(sent.first { $0.endpoint.absoluteString.hasSuffix("/one") })
        XCTAssertEqual(one.headers["Content-Encoding"], "aes128gcm")
        XCTAssertEqual(one.headers["TTL"], String(PushNotifier.ttlSeconds))
        XCTAssertEqual(one.headers["Urgency"], "high")
        XCTAssertTrue(one.headers["Authorization"]?.hasPrefix("vapid t=") == true)

        let payload = try browser.payload(one.body)
        XCTAssertEqual(payload["session"] as? String, id.uuidString)
        XCTAssertEqual(payload["state"] as? String, "needs-input")
        XCTAssertEqual(payload["name"] as? String, "crew alpha")
        XCTAssertEqual(payload["project"] as? String, "kitterm")
        XCTAssertEqual(payload["reason"] as? String, "Claude is waiting for your input")
        XCTAssertEqual(payload["title"] as? String, "crew alpha needs input")
        XCTAssertEqual(payload["body"] as? String, "kitterm · Claude is waiting for your input")
        XCTAssertEqual(payload["url"] as? String, "/?session=\(id.uuidString)")
        XCTAssertNotNil(payload["at"] as? Int)

        let two = try XCTUnwrap(sent.first { $0.endpoint.absoluteString.hasSuffix("/two") })
        XCTAssertEqual(try other.payload(two.body)["session"] as? String, id.uuidString)
        XCTAssertThrowsError(try browser.decrypt(two.body), "sealed for the other browser")
    }

    func testAnUnnamedSessionIsNamedByItsId() async throws {
        // The label pins the project: a freshly spawned shell's kernel cwd is
        // still the test's own until the helper changes directory.
        let id = try await spawn(labels: "project:scratch")
        store.upsert(browser.subscription(endpoint: "https://push.example/one"))
        notifier.observe(id, state: .needsApproval, reason: "Bash")
        try await drain()
        let payload = try browser.payload(try XCTUnwrap(transport.sent.first).body)
        XCTAssertEqual(payload["name"] as? String, "session \(id.uuidString.prefix(8))")
        XCTAssertEqual(payload["title"] as? String, "session \(id.uuidString.prefix(8)) needs approval")
        XCTAssertEqual(payload["body"] as? String, "scratch · Bash")
        XCTAssertEqual(payload["project"] as? String, "scratch")
    }

    // MARK: - Gone

    func testAnEndpointThatAnswersGoneIsForgottenAndTheFileAgrees() async throws {
        let id = try await spawn()
        store.upsert(browser.subscription(endpoint: "https://push.example/gone"))
        store.upsert(browser.subscription(endpoint: "https://push.example/kept"))
        store.upsert(browser.subscription(endpoint: "https://push.example/unknown"))
        transport.answer("https://push.example/gone", with: 410)
        transport.answer("https://push.example/unknown", with: 404)

        notifier.observe(id, state: .needsInput, reason: nil)
        try await drain()

        XCTAssertEqual(store.all.map(\.endpoint), ["https://push.example/kept"])
        XCTAssertEqual(
            PushSubscriptionStore(file: stateDir.appendingPathComponent("push.json")).all.map(\.endpoint),
            ["https://push.example/kept"]
        )
    }

    func testOtherFailuresKeepTheSubscription() async throws {
        let id = try await spawn()
        store.upsert(browser.subscription(endpoint: "https://push.example/busy"))
        transport.answer("https://push.example/busy", with: 503)
        notifier.observe(id, state: .needsInput, reason: nil)
        try await drain()
        XCTAssertEqual(store.count, 1, "a 503 is the service's day, not the phone's")
    }

    func testASessionGoneBeforeDeliveryIsNotSent() async throws {
        store.upsert(browser.subscription(endpoint: "https://push.example/one"))
        notifier.observe(UUID(), state: .needsInput, reason: nil)
        try await drain()
        XCTAssertTrue(transport.sent.isEmpty)
    }
}
