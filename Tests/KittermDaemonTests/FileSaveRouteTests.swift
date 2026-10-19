#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon
@testable import KittermProtocol

#if canImport(Darwin)
private let socketType = SOCK_STREAM
#else
private let socketType = Int32(SOCK_STREAM.rawValue)
#endif

/// `PUT /api/files/content`, the first route that writes outside
/// `~/.kitterm/` (`code-editor` round 3, `goal.md` condition 7): the jail,
/// the atomic save, the precondition, the CSRF rules, the grade and the audit
/// line; and the `ETag` the read now sends. Every request goes over a raw
/// socket, so the `Host`, `Origin` and `Cookie` headers are exactly what the
/// test says.
final class FileSaveRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    /// The scratch directory as `NSTemporaryDirectory()` names it: under
    /// `/var/folders` on macOS, a symlink to `/private/var/folders`.
    private var scratch: URL!
    private var stateDir: URL!
    /// The checkout, by its real path: the project root the store resolves.
    private var root: String!
    /// The same checkout through the `/var` symlink, as a client might name it.
    private var rootAlias: String!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.appendingPathComponent("state").path), isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        rootAlias = scratch.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: rootAlias + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: rootAlias + "/src", withIntermediateDirectories: true)
        try "config".write(toFile: rootAlias + "/.git/config", atomically: true, encoding: .utf8)
        try "hello\n".write(toFile: rootAlias + "/src/a.ts", atomically: true, encoding: .utf8)
        root = ProjectStore.canonicalRoot(rootAlias)
        try start(policy: .loopbackOnly)
    }

    override func tearDown() async throws {
        FileEdit.queue.sync {}
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        group = nil
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - helpers

    private func start(policy: AccessPolicy) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let registry = SessionRegistry()
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(registry: registry, policy: policy, staticRoot: nil)
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    private func restart(policy: AccessPolicy) async throws {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        try start(policy: policy)
    }

    private struct Answer: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var error: String { json["error"] as? String ?? "" }
    }

    private func encoded(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
    }

    private func request(
        _ method: String, _ target: String, host: String? = nil, headers: [String] = [], body: Data? = nil
    ) throws -> Answer {
        try Self.request(port: port, method, target, host: host, headers: headers, body: body)
    }

    /// One HTTP/1.1 request over a raw socket. `host` is the `Host` header;
    /// the request still connects to loopback. Static, so a test can fire
    /// two at once from detached tasks.
    private static func request(
        port: Int, _ method: String, _ target: String, host: String?, headers: [String], body: Data?
    ) throws -> Answer {
        let fd = socket(AF_INET, socketType, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connect failed: errno \(errno)")
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")", "Connection: close"]
        lines += headers
        if let body { lines.append("Content-Length: \(body.count)") }
        var request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { request.append(body) }
        request.withUnsafeBytes { XCTAssertEqual(send(fd, $0.baseAddress, $0.count, 0), request.count) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        guard let split = received.range(of: Data("\r\n\r\n".utf8)) else {
            XCTFail("no header block in \(String(decoding: received, as: UTF8.self))")
            return Answer(status: 0, headers: [:], body: Data())
        }
        let head = String(decoding: received[..<split.lowerBound], as: UTF8.self).split(separator: "\r\n")
        let status = Int(head.first?.split(separator: " ").dropFirst().first ?? "0") ?? 0
        var parsed: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            parsed[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Answer(status: status, headers: parsed, body: received[split.upperBound...])
    }

    private func get(_ path: String) throws -> Answer {
        try request("GET", "/api/files/content?path=\(encoded(path))")
    }

    private var ownOrigin: String { "http://127.0.0.1:\(port!)" }

    /// A save as the editor sends it: the editor header, the page's own
    /// `Origin`, the tag the read gave. `dropping` leaves a header out and
    /// `origin` replaces the page's.
    private func put(
        _ path: String, _ text: String, ifMatch: String?,
        dropping: Set<String> = [], origin: String? = nil, extra: [String] = [], host: String? = nil
    ) throws -> Answer {
        var headers: [String] = []
        if !dropping.contains("X-Kitterm-Editor") { headers.append("X-Kitterm-Editor: 1") }
        if !dropping.contains("Origin") { headers.append("Origin: \(origin ?? ownOrigin)") }
        if let ifMatch { headers.append("If-Match: \(ifMatch)") }
        headers += extra
        return try request(
            "PUT", "/api/files/content?path=\(encoded(path))", host: host, headers: headers,
            body: Data(text.utf8)
        )
    }

    /// The current tag of `path`, read as the page reads it.
    private func tag(_ path: String) throws -> String {
        let answer = try get(path)
        XCTAssertEqual(answer.status, 200, answer.text)
        return try XCTUnwrap(answer.headers["etag"], "no ETag on \(path)")
    }

    private func mode(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private var auditLines: [[String: Any]] {
        FileEdit.queue.sync {}
        guard let text = try? String(contentsOf: DaemonPaths.editsLogFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func temporaryFiles(in directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasPrefix(FileEdit.temporaryPrefix) }
    }

    // MARK: - the read

    func testReadSendsTheTagAndTheMode() throws {
        chmod(root + "/src/a.ts", 0o640)
        let answer = try get(root + "/src/a.ts")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.headers["etag"], FileEdit.etag(Data("hello\n".utf8)))
        XCTAssertTrue(answer.headers["etag"]?.hasPrefix("\"sha256:") ?? false)
        XCTAssertEqual(answer.headers["x-kitterm-mode"], "640")
        XCTAssertEqual(answer.headers["x-kitterm-truncated"], "0")
    }

    /// A tag of part of a file would let a save destroy the rest.
    func testTruncatedReadSendsNoTag() throws {
        let big = Data(repeating: UInt8(ascii: "x"), count: FileEdit.maxBytes + 1)
        try big.write(to: URL(fileURLWithPath: root + "/src/big.txt"))
        let answer = try get(root + "/src/big.txt")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.headers["x-kitterm-truncated"], "1")
        XCTAssertNil(answer.headers["etag"])
    }

    /// The read and the listing follow a symlinked directory as before: a
    /// full token can `cat`, and `/tmp` is a symlink.
    func testReadAndListingStillFollowASymlinkedDirectory() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/linkdir", withDestinationPath: root + "/src")
        let read = try get(root + "/linkdir/a.ts")
        XCTAssertEqual(read.status, 200, read.text)
        XCTAssertEqual(read.text, "hello\n")
        let listing = try request("GET", "/api/files?path=\(encoded(root + "/linkdir"))")
        XCTAssertEqual(listing.status, 200, listing.text)
        let names = (listing.json["entries"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("a.ts"), listing.text)
    }

    // MARK: - the save

    func testSaveChangesTheBytesAndKeepsTheMode() throws {
        let path = root + "/src/a.ts"
        chmod(path, 0o755)
        let before = try tag(path)
        let answer = try put(path, "const a = 1;\n", ifMatch: before)
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(try contents(path), "const a = 1;\n")
        XCTAssertEqual(try mode(path), 0o755)
        let expected = FileEdit.etag(Data("const a = 1;\n".utf8))
        XCTAssertEqual(answer.headers["etag"], expected)
        XCTAssertEqual(answer.json["etag"] as? String, expected)
        XCTAssertEqual(answer.json["bytes"] as? Int, 13)
        XCTAssertEqual(answer.json["ok"] as? Bool, true)
        XCTAssertEqual(try tag(path), expected, "the next read sees the saved bytes")
        XCTAssertNil(answer.headers["access-control-allow-origin"])
        XCTAssertTrue(temporaryFiles(in: root + "/src").isEmpty)
    }

    /// The bytes are the bytes: no line-ending change, no BOM stripped.
    func testBytesAreWrittenAsSent() throws {
        let path = root + "/src/a.ts"
        let text = "\u{FEFF}line one\r\nline two\r\n\tno trailing newline"
        let answer = try put(path, text, ifMatch: try tag(path))
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(text.utf8))
    }

    /// The path a shell on macOS prints may go through `/var` or `/tmp`,
    /// while the root is stored as `/private/var/…`: a symlink above the
    /// root is the root's own business and is allowed.
    func testSaveThroughASymlinkAboveTheRootSucceeds() throws {
        try XCTSkipIf(rootAlias == root, "the scratch directory is its own real path here")
        let aliasPath = rootAlias + "/src/a.ts"
        let answer = try put(aliasPath, "via alias\n", ifMatch: try tag(aliasPath))
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(try contents(root + "/src/a.ts"), "via alias\n")
        XCTAssertEqual(answer.json["path"] as? String, aliasPath)
    }

    func testANormalizationFormDNameSaves() throws {
        let name = "caf\u{0065}\u{0301}.md"
        let path = root + "/src/" + name
        try "before".write(toFile: path, atomically: true, encoding: .utf8)
        let answer = try put(path, "after", ifMatch: try tag(path))
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(try contents(path), "after")
    }

    // MARK: - the precondition

    func testStaleIfMatchIs412WithTheCurrentTag() throws {
        let path = root + "/src/a.ts"
        let stale = try tag(path)
        try "an agent wrote this\n".write(toFile: path, atomically: true, encoding: .utf8)
        let answer = try put(path, "mine\n", ifMatch: stale)
        XCTAssertEqual(answer.status, 412, answer.text)
        let current = FileEdit.etag(Data("an agent wrote this\n".utf8))
        XCTAssertEqual(answer.headers["etag"], current)
        XCTAssertEqual(answer.json["etag"] as? String, current)
        XCTAssertEqual(try contents(path), "an agent wrote this\n", "nothing was written")
        XCTAssertTrue(temporaryFiles(in: root + "/src").isEmpty, "the temp file is gone after a refusal")
    }

    func testMissingIfMatchIs428() throws {
        let path = root + "/src/a.ts"
        let answer = try put(path, "mine\n", ifMatch: nil)
        XCTAssertEqual(answer.status, 428, answer.text)
        XCTAssertEqual(try contents(path), "hello\n")
    }

    /// A bare tag matches; a weak one or a list does not.
    func testIfMatchForms() throws {
        let path = root + "/src/a.ts"
        let quoted = try tag(path)
        let bare = FileEdit.bare(quoted)
        XCTAssertEqual(try put(path, "one\n", ifMatch: bare).status, 200)
        let weak = try put(path, "two\n", ifMatch: "W/" + FileEdit.etag(Data("one\n".utf8)))
        XCTAssertEqual(weak.status, 412, weak.text)
        XCTAssertEqual(try contents(path), "one\n")
    }

    /// Two saves hold the same tag and race: the queue runs them one after
    /// another, so the second finds the first's bytes and answers 412.
    func testConcurrentSavesWithOneTagLetExactlyOneWin() async throws {
        let path = root + "/src/a.ts"
        let shared = try tag(path)
        let port = self.port!
        let target = "/api/files/content?path=\(encoded(path))"
        let headers = ["X-Kitterm-Editor: 1", "Origin: \(ownOrigin)", "If-Match: \(shared)"]
        async let first = Task.detached {
            try Self.request(port: port, "PUT", target, host: nil, headers: headers, body: Data("first\n".utf8))
        }.value
        async let second = Task.detached {
            try Self.request(port: port, "PUT", target, host: nil, headers: headers, body: Data("second\n".utf8))
        }.value
        let statuses = [try await first.status, try await second.status].sorted()
        XCTAssertEqual(statuses, [200, 412])
        let saved = try contents(path)
        XCTAssertTrue(saved == "first\n" || saved == "second\n", saved)
        XCTAssertTrue(temporaryFiles(in: root + "/src").isEmpty)
    }

    // MARK: - CSRF and grade

    func testNoEditorHeaderIs403() throws {
        let path = root + "/src/a.ts"
        let answer = try put(path, "mine\n", ifMatch: try tag(path), dropping: ["X-Kitterm-Editor"])
        XCTAssertEqual(answer.status, 403, answer.text)
        XCTAssertTrue(answer.error.contains("X-Kitterm-Editor"), answer.text)
        XCTAssertEqual(try contents(path), "hello\n")
    }

    /// Another loopback name passes the access policy and still fails the
    /// route's exact match: the Origin must be this request's own.
    func testAnotherOriginIs403() throws {
        let path = root + "/src/a.ts"
        let other = try put(path, "mine\n", ifMatch: try tag(path), origin: "http://localhost:\(port!)")
        XCTAssertEqual(other.status, 403, other.text)
        XCTAssertTrue(other.error.contains("Origin"), other.text)
        let none = try put(path, "mine\n", ifMatch: try tag(path), dropping: ["Origin"])
        XCTAssertEqual(none.status, 403, none.text)
        XCTAssertEqual(try contents(path), "hello\n")
    }

    /// Through a trusted host a watch token reaches nothing here; the
    /// control token saves, and the audit names the token kind.
    func testWatchGradeIs403() async throws {
        try await restart(policy: .proxied(token: "ctl", watchToken: "ktw_w", trustedHosts: ["mac.example"]))
        let path = root + "/src/a.ts"
        let before = FileEdit.etag(Data("hello\n".utf8))
        let watch = try put(
            path, "mine\n", ifMatch: before, origin: "http://mac.example",
            extra: ["Cookie: kitterm_token=ktw_w"], host: "mac.example"
        )
        XCTAssertEqual(watch.status, 403, watch.text)
        XCTAssertEqual(watch.error, "watch-only token")
        XCTAssertEqual(try contents(path), "hello\n")
        let full = try put(
            path, "mine\n", ifMatch: before, origin: "http://mac.example",
            extra: ["Cookie: kitterm_token=ctl"], host: "mac.example"
        )
        XCTAssertEqual(full.status, 200, full.text)
        XCTAssertEqual(try contents(path), "mine\n")
        XCTAssertEqual(auditLines.last?["token"] as? String, "ephemeral")
    }

    func testOutsideEveryProjectIs403() throws {
        let outside = scratch.appendingPathComponent("plain", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "loose".write(toFile: outside + "/notes.txt", atomically: true, encoding: .utf8)
        let answer = try put(outside + "/notes.txt", "mine", ifMatch: try tag(outside + "/notes.txt"))
        XCTAssertEqual(answer.status, 403, answer.text)
        XCTAssertEqual(answer.error, "outside every project")
        XCTAssertEqual(try contents(outside + "/notes.txt"), "loose")
    }

    // MARK: - the jail

    func testSymlinkedParentIs403() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/linkdir", withDestinationPath: root + "/src")
        let answer = try put(root + "/linkdir/a.ts", "mine\n", ifMatch: FileEdit.etag(Data("hello\n".utf8)))
        XCTAssertEqual(answer.status, 403, answer.text)
        XCTAssertEqual(answer.error, "a symlink in the path")
        XCTAssertEqual(try contents(root + "/src/a.ts"), "hello\n")
    }

    func testSymlinkedTargetIs403() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/src/link.ts", withDestinationPath: root + "/src/a.ts")
        let answer = try put(root + "/src/link.ts", "mine\n", ifMatch: FileEdit.etag(Data("hello\n".utf8)))
        XCTAssertEqual(answer.status, 403, answer.text)
        XCTAssertEqual(answer.error, "a symlink in the path")
        XCTAssertEqual(try contents(root + "/src/a.ts"), "hello\n")
    }

    /// The filebrowser class of fault: a create through a dangling link
    /// lands wherever the link points. There is no create here, and the
    /// link itself is refused.
    func testDanglingSymlinkIs403() throws {
        let elsewhere = scratch.appendingPathComponent("planted.txt").path
        try FileManager.default.createSymbolicLink(atPath: root + "/src/dangling.ts", withDestinationPath: elsewhere)
        let answer = try put(root + "/src/dangling.ts", "mine\n", ifMatch: FileEdit.etag(Data()))
        XCTAssertEqual(answer.status, 403, answer.text)
        XCTAssertEqual(answer.error, "a symlink in the path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere))
    }

    /// A symlinked directory outside the root that points back in: the
    /// walk starts at the root and still meets the link below it.
    func testSymlinkBelowTheRootIntoTheRootIs403() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/src/again", withDestinationPath: root)
        let answer = try put(root + "/src/again/src/a.ts", "mine\n", ifMatch: FileEdit.etag(Data("hello\n".utf8)))
        XCTAssertEqual(answer.status, 403, answer.text)
        XCTAssertEqual(try contents(root + "/src/a.ts"), "hello\n")
    }

    func testHardLinkedFileIs409() throws {
        XCTAssertEqual(link(root + "/src/a.ts", root + "/src/twin.ts"), 0, "link failed: errno \(errno)")
        let answer = try put(root + "/src/a.ts", "mine\n", ifMatch: try tag(root + "/src/a.ts"))
        XCTAssertEqual(answer.status, 409, answer.text)
        XCTAssertEqual(answer.error, "hard-linked file")
        XCTAssertEqual(try contents(root + "/src/twin.ts"), "hello\n")
    }

    func testFIFOIs409() throws {
        XCTAssertEqual(mkfifo(root + "/src/pipe", 0o600), 0, "mkfifo failed: errno \(errno)")
        let answer = try put(root + "/src/pipe", "mine\n", ifMatch: FileEdit.etag(Data()))
        XCTAssertEqual(answer.status, 409, answer.text)
        XCTAssertEqual(answer.error, "not a regular file")
    }

    func testDirectoryIs409AndMissingFileIs404() throws {
        let directory = try put(root + "/src", "mine\n", ifMatch: FileEdit.etag(Data()))
        XCTAssertEqual(directory.status, 409, directory.text)
        let missing = try put(root + "/src/nope.ts", "mine\n", ifMatch: FileEdit.etag(Data()))
        XCTAssertEqual(missing.status, 404, missing.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/src/nope.ts"), "no create this round")
    }

    func testGitDirectoryIs403InEverySpelling() throws {
        let configTag = FileEdit.etag(Data("config".utf8))
        for spelling in [".git/config", ".GIT/config", "src/../.git/config", ".Git/config"] {
            let answer = try put(root + "/" + spelling, "[core]\n", ifMatch: configTag)
            XCTAssertEqual(answer.status, 403, "\(spelling): \(answer.text)")
            XCTAssertEqual(answer.error, "under .git", spelling)
        }
        XCTAssertEqual(try contents(root + "/.git/config"), "config")
        // A nested checkout's `.git`, by name at depth.
        try FileManager.default.createDirectory(atPath: root + "/vendor/dep/.git", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/vendor/dep/.git/HEAD", atomically: true, encoding: .utf8)
        let nested = try put(root + "/vendor/dep/.git/HEAD", "y", ifMatch: FileEdit.etag(Data("x".utf8)))
        XCTAssertEqual(nested.status, 403, nested.text)
    }

    func testBodyOverTheCapIs413() throws {
        let path = root + "/src/a.ts"
        let big = String(repeating: "x", count: FileEdit.maxBytes + 1)
        let answer = try put(path, big, ifMatch: try tag(path))
        XCTAssertEqual(answer.status, 413, answer.text)
        XCTAssertEqual(try contents(path), "hello\n")
    }

    // MARK: - the audit

    func testAuditLineNamesTheSaveAndCarriesNoContent() throws {
        let path = root + "/src/a.ts"
        let secret = "const password = \"hunter2\";\n"
        let before = try tag(path)
        XCTAssertEqual(try put(path, secret, ifMatch: before).status, 200)
        XCTAssertEqual(try put(path, "again\n", ifMatch: before).status, 412)
        XCTAssertEqual(try put(path, "again\n", ifMatch: nil).status, 428)

        let text = try String(contentsOf: DaemonPaths.editsLogFile, encoding: .utf8)
        XCTAssertFalse(text.contains("hunter2"), text)
        XCTAssertFalse(text.contains("again"), text)
        let lines = auditLines
        XCTAssertEqual(lines.count, 3, text)
        let saved = lines[0]
        XCTAssertEqual(saved["status"] as? Int, 200)
        XCTAssertEqual(saved["token"] as? String, "loopback")
        XCTAssertEqual(saved["path"] as? String, path)
        XCTAssertEqual(saved["bytes"] as? Int, secret.utf8.count)
        XCTAssertEqual(saved["oldHash"] as? String, FileEdit.bare(before))
        XCTAssertEqual(saved["newHash"] as? String, FileEdit.hashName(Data(secret.utf8)))
        XCTAssertNotNil(saved["at"] as? String)
        XCTAssertEqual(Set(saved.keys), ["at", "bytes", "newHash", "oldHash", "path", "status", "token"])
        XCTAssertEqual(lines[1]["status"] as? Int, 412)
        XCTAssertEqual(lines[1]["oldHash"] as? String, FileEdit.hashName(Data(secret.utf8)), "the 412 names what is there now")
        XCTAssertEqual(lines[2]["status"] as? Int, 428)
        XCTAssertNil(lines[2]["oldHash"], "nothing was read for a refusal before the file")
        let permissions = try FileManager.default.attributesOfItem(atPath: DaemonPaths.editsLogFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testAuditLogRotatesPastOneMebibyteKeepingOneOldFile() throws {
        let file = scratch.appendingPathComponent("edits.log")
        let filler = Data(repeating: UInt8(ascii: "a"), count: EditLog.maxBytes)
        try filler.write(to: file)
        try EditLog.appendOrThrow(
            EditLog.Entry(at: Date(), token: "loopback", path: "/p", bytes: 1, oldHash: nil, newHash: "sha256:00", status: 200),
            to: file
        )
        let rotated = scratch.appendingPathComponent("edits.log.1")
        XCTAssertEqual(try Data(contentsOf: rotated).count, EditLog.maxBytes)
        let fresh = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(fresh.split(separator: "\n").count, 1)
        XCTAssertTrue(fresh.contains("\"status\":200"), fresh)
    }
}
