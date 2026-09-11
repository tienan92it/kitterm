import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// A test daemon with a fake push service: the corpus request
/// `01-phone-walks-away`, driven through `/api/hooks` and a shell's marks,
/// with the messages read at the endpoint over real HTTP and opened with
/// the browser's own key. Then the same through a real `kitterm serve`, so
/// the wiring in `DaemonServer.start()` is what is proved, not a handler
/// built by hand.
final class PushSendRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var registry: SessionRegistry!
    private var approvals: ApprovalStore!
    private var eventLog: EventLog!
    private var store: PushSubscriptionStore!
    private var notifier: PushNotifier!
    private var service: FakePushService!
    private var stateDir: URL!
    private var sessions: [PtySession] = []
    private var port: Int!
    private let browser = FakeBrowser()

    private static var buildDir: URL {
        Bundle(for: PushSendRouteTests.self).bundleURL.deletingLastPathComponent()
    }

    override class func setUp() {
        super.setUp()
        setenv("PATH", buildDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""), 1)
        setenv("SHELL", "/bin/sh", 1)
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-push-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        service = FakePushService()
        try service.start()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLog = EventLog()
        registry = SessionRegistry(eventLog: eventLog)
        approvals = ApprovalStore()
        store = PushSubscriptionStore(file: pushFile)
        notifier = PushNotifier(store: store, keys: VAPIDKeys(), registry: registry)
    }

    override func tearDown() async throws {
        for session in sessions { session.terminate() }
        sessions = []
        try? channel?.close().wait()
        try? await group.shutdownGracefully()
        await service.stop()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    private var pushFile: URL { stateDir.appendingPathComponent("push.json") }

    private func startHandler() async throws {
        await registry.setObserver(notifier)
        let registry = self.registry!
        let approvals = self.approvals!
        let eventLog = self.eventLog!
        let notifier = self.notifier!
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
                            policy: .loopbackOnly,
                            agentControl: true,
                            approvals: approvals,
                            eventLog: eventLog,
                            staticRoot: nil,
                            pushNotifier: notifier
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    private func spawn(name: String, labels: String? = nil) async throws -> UUID {
        let session = try PtySession.spawn(cwd: NSTemporaryDirectory(), labels: SessionLabels.parse(labels))
        session.setName(name)
        sessions.append(session)
        let registered = await registry.register(session)
        return try XCTUnwrap(registered)
    }

    private func hook(_ id: UUID, port: Int? = nil, _ body: String) async throws {
        let answer = try await request(
            "POST", port: port ?? self.port, "/api/hooks", body: body,
            headers: ["X-Kitterm-Session": id.uuidString]
        )
        XCTAssertEqual(answer.status, 200, answer.body)
    }

    private func notification(_ message: String) -> String {
        #"{"hook_event_name":"Notification","message":"\#(message)"}"#
    }

    private static let preToolUse = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#
    private static let stop = #"{"hook_event_name":"Stop"}"#
    private static let permissionRequest =
        #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#

    /// The notifier decides on the loop before the hook answers; delivery
    /// is the HTTP round trip to the fake, which this waits out.
    private func settle() async throws {
        try await waitFor("the notifier to drain") { self.notifier.isDrained }
    }

    private func payloads(to path: String) throws -> [[String: Any]] {
        try service.requests(to: path).map { try browser.payload($0.body) }
    }

    // MARK: - The corpus request, in process

    /// One message after the `Notification`, nothing while the session sits
    /// in `needs-input`, one for the other session's held tool call, nothing
    /// for the answer, `working` or `completed`.
    func testOneMessagePerTransitionAndNoneForTheRest() async throws {
        try await startHandler()
        store.upsert(browser.subscription(endpoint: "\(service.origin)/phone"))
        let first = try await spawn(name: "crew alpha", labels: "project:kitterm")
        let second = try await spawn(name: "crew beta", labels: "project:kitterm")

        // Step 1: the agent works, then asks.
        try await hook(first, Self.preToolUse)
        try await settle()
        XCTAssertEqual(service.requests.count, 0, "working is not actionable")
        try await hook(first, notification("Claude is waiting for your input"))
        try await settle()
        var received = try payloads(to: "/phone")
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?["session"] as? String, first.uuidString)
        XCTAssertEqual(received.first?["state"] as? String, "needs-input")
        XCTAssertEqual(received.first?["name"] as? String, "crew alpha")
        XCTAssertEqual(received.first?["project"] as? String, "kitterm")
        XCTAssertEqual(received.first?["reason"] as? String, "Claude is waiting for your input")
        XCTAssertEqual(received.first?["url"] as? String, "/?session=\(first.uuidString)")

        // Step 2: it stays there. A repeat of the hook, and a hook with new
        // words, both leave the state where it is.
        try await hook(first, notification("Claude is waiting for your input"))
        try await hook(first, notification("Still waiting"))
        try await settle()
        XCTAssertEqual(service.requests.count, 1, "one unchanged state, one message")

        // Step 3: the other session's tool call is held.
        let p = port!
        async let held = Self.rawPost(port: p, "/api/hooks", Self.permissionRequest, session: second)
        let approvalID = try await waitForPendingApproval()
        try await settle()
        received = try payloads(to: "/phone")
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last?["session"] as? String, second.uuidString)
        XCTAssertEqual(received.last?["state"] as? String, "needs-approval")
        XCTAssertEqual(received.last?["name"] as? String, "crew beta")
        XCTAssertEqual(received.last?["reason"] as? String, "Bash")
        XCTAssertEqual(received.last?["title"] as? String, "crew beta needs approval")

        let resolved = try await request(
            "POST", port: port, "/api/approvals/\(approvalID)", body: #"{"decision":"allow"}"#
        )
        XCTAssertEqual(resolved.status, 200, resolved.body)
        let heldAnswer = try await held
        XCTAssertEqual(heldAnswer.status, 200, heldAnswer.body)

        // Step 4: the first session's human answers; it works, then finishes.
        try await hook(first, Self.preToolUse)
        try await hook(first, Self.stop)
        try await settle()
        XCTAssertEqual(service.requests.count, 2, "the answer, working and completed send nothing")

        // Asked again is a transition again, for either session.
        try await hook(first, notification("Claude is waiting for your input"))
        async let heldAgain = Self.rawPost(port: p, "/api/hooks", Self.permissionRequest, session: second)
        let againID = try await waitForPendingApproval()
        try await settle()
        XCTAssertEqual(service.requests.count, 4)
        _ = try await request("POST", port: port, "/api/approvals/\(againID)", body: #"{"decision":"deny"}"#)
        let heldAgainAnswer = try await heldAgain
        XCTAssertEqual(heldAgainAnswer.status, 200, heldAgainAnswer.body)

        for request in service.requests {
            XCTAssertEqual(request.headers["content-encoding"], "aes128gcm")
            XCTAssertEqual(request.headers["ttl"], String(PushNotifier.ttlSeconds))
            XCTAssertTrue(request.headers["authorization"]?.hasPrefix("vapid t=") == true)
        }
    }

    /// `failed` comes from the shell, not from a hook: a `commandEnd` mark
    /// with a non-zero exit reaches the phone through the registry's wiring.
    func testANonZeroExitSendsFailedOnceAndAZeroExitSendsNothing() async throws {
        try await startHandler()
        store.upsert(browser.subscription(endpoint: "\(service.origin)/phone"))
        let id = try await spawn(name: "builder", labels: "project:kitterm")
        let session = try XCTUnwrap(sessions.last)

        feed(session, "\u{1b}]633;E;make test\u{07}\u{1b}]133;C\u{07}ok\u{1b}]133;D;0\u{07}")
        try await settle()
        XCTAssertEqual(service.requests.count, 0, "exit 0 is idle")

        feed(session, "\u{1b}]633;E;make test\u{07}\u{1b}]133;C\u{07}boom\u{1b}]133;D;2\u{07}")
        try await settle()
        let received = try payloads(to: "/phone")
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?["session"] as? String, id.uuidString)
        XCTAssertEqual(received.first?["state"] as? String, "failed")
        XCTAssertEqual(received.first?["reason"] as? String, "exit 2: make test")
        XCTAssertEqual(received.first?["body"] as? String, "kitterm · exit 2: make test")

        feed(session, "\u{1b}]633;E;make test\u{07}\u{1b}]133;C\u{07}boom\u{1b}]133;D;2\u{07}")
        try await settle()
        XCTAssertEqual(service.requests.count, 1, "failed again is the same state")
    }

    /// The push service says the phone is gone: the daemon forgets that
    /// endpoint, keeps the other, and the file agrees.
    func testAGoneAnswerRemovesTheSubscription() async throws {
        try await startHandler()
        store.upsert(browser.subscription(endpoint: "\(service.origin)/gone"))
        store.upsert(browser.subscription(endpoint: "\(service.origin)/kept"))
        service.answer("/gone", with: 410)
        let id = try await spawn(name: "crew")

        try await hook(id, notification("Claude is waiting for your input"))
        try await settle()
        XCTAssertEqual(service.requests(to: "/gone").count, 1)
        XCTAssertEqual(service.requests(to: "/kept").count, 1)
        XCTAssertEqual(store.all.map(\.endpoint), ["\(service.origin)/kept"])
        XCTAssertEqual(PushSubscriptionStore(file: pushFile).all.map(\.endpoint), ["\(service.origin)/kept"])

        // Nothing goes to the forgotten one again.
        try await hook(id, Self.preToolUse)
        try await hook(id, notification("Claude is waiting for your input"))
        try await settle()
        XCTAssertEqual(service.requests(to: "/gone").count, 1)
        XCTAssertEqual(service.requests(to: "/kept").count, 2)
    }

    func testNoSubscriptionMeansNoRequest() async throws {
        try await startHandler()
        let id = try await spawn(name: "crew")
        try await hook(id, notification("Claude is waiting for your input"))
        try await settle()
        XCTAssertTrue(service.requests.isEmpty)
    }

    // MARK: - Proved with a real process

    /// `kitterm serve` under its own state directory, with `push.json`
    /// written the way capability 2 writes it: a `Notification` for a
    /// session the route spawned reaches the fake, sealed for the browser's
    /// key and signed with the pair in `vapid.json`, and the endpoint that
    /// answers 410 is gone from the file afterwards.
    func testARealServeSendsAndForgets() async throws {
        store.upsert(browser.subscription(endpoint: "\(service.origin)/phone"))
        store.upsert(browser.subscription(endpoint: "\(service.origin)/gone"))
        service.answer("/gone", with: 410)
        let daemon = try startDaemon()
        defer { stop(daemon) }
        try await waitFor("the daemon to be healthy") { await self.isHealthy(port: daemon.port) }

        let spawned = try await request(
            "POST", port: daemon.port, "/api/sessions", body: #"{"name":"crew alpha","labels":{"project":"kitterm"}}"#
        )
        XCTAssertEqual(spawned.status, 201, spawned.body)
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(json(spawned.body)["id"] as? String)))

        try await hook(id, port: daemon.port, Self.preToolUse)
        try await hook(id, port: daemon.port, notification("Claude is waiting for your input"))
        try await waitFor("both endpoints to hear") { self.service.requests.count == 2 }
        try await hook(id, port: daemon.port, notification("Claude is waiting for your input"))
        try await hook(id, port: daemon.port, Self.stop)

        let payload = try browser.payload(try XCTUnwrap(service.requests(to: "/phone").first).body)
        XCTAssertEqual(payload["session"] as? String, id.uuidString)
        XCTAssertEqual(payload["state"] as? String, "needs-input")
        XCTAssertEqual(payload["name"] as? String, "crew alpha")
        XCTAssertEqual(payload["project"] as? String, "kitterm")
        XCTAssertEqual(payload["title"] as? String, "crew alpha needs input")

        // The token was signed with the pair the daemon wrote to its own file.
        let keyFile = stateDir.appendingPathComponent("vapid.json")
        let keys = try XCTUnwrap(VAPIDKeys.read(from: keyFile))
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(mode & 0o777, 0o600)
        let authorization = try XCTUnwrap(service.requests(to: "/phone").first?.headers["authorization"])
        XCTAssertTrue(authorization.hasSuffix("k=\(keys.publicKeyBase64URL)"), authorization)

        try await waitFor("the gone endpoint to leave the file") {
            PushSubscriptionStore(file: self.pushFile).all.map(\.endpoint) == ["\(self.service.origin)/phone"]
        }
        // The repeat and the Stop sent nothing more: still one per endpoint.
        try await Task.sleep(for: .milliseconds(200), clock: .suspending)
        XCTAssertEqual(service.requests(to: "/phone").count, 1)
        XCTAssertEqual(service.requests(to: "/gone").count, 1)
    }

    // MARK: - Helpers

    /// A hook post that `async let` can hold while the daemon holds it.
    private static func rawPost(
        port: Int, _ path: String, _ body: String, session: UUID
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue(session.uuidString, forHTTPHeaderField: "X-Kitterm-Session")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func feed(_ session: PtySession, _ text: String) {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        session.handleRead(&buffer)
    }

    private func waitForPendingApproval() async throws -> String {
        var id: String?
        try await waitFor("the held hook to register") {
            let listed = try? self.json(try await self.request("GET", port: self.port, "/api/approvals").body)
            id = ((listed?["approvals"] as? [[String: Any]])?.first?["id"] as? String)
            return id != nil
        }
        return try XCTUnwrap(id)
    }

    private struct Daemon {
        let process: Process
        let port: Int
        let pid: Int32
    }

    private func startDaemon() throws -> Daemon {
        let executable = Self.buildDir.appendingPathComponent("kitterm")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "kitterm binary not built beside the test bundle"
        )
        let port = try freePort()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--port", "\(port)", "--agent-control"]
        var environment = ProcessInfo.processInfo.environment
        environment["KITTERM_STATE_DIR"] = stateDir.path
        environment["SHELL"] = "/bin/sh"
        process.environment = environment
        try process.run()
        return Daemon(process: process, port: port, pid: process.processIdentifier)
    }

    private func stop(_ daemon: Daemon) {
        guard daemon.process.isRunning else { return }
        kill(daemon.pid, SIGTERM)
        daemon.process.waitUntilExit()
    }

    private func isHealthy(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func waitFor(
        _ what: String, timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = SuspendingClock.now + .seconds(timeout)
        while SuspendingClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50), clock: .suspending)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        throw CancellationError()
    }

    private func request(
        _ method: String, port: Int, _ path: String, body: String? = nil, headers: [String: String] = [:]
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    private func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw CancellationError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw CancellationError() }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
