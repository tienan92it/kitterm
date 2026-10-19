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

/// The three route changes of the editor page (`code-editor` round 4,
/// `goal.md` condition 8): `GET /edit` serves `edit.html` as `/md` serves
/// `md.html`; `GET /api/files/project` names the project that would jail a
/// file's save, by the save route's own resolution; and `GET
/// /api/files/content` answers 304 to an `If-None-Match` that names the
/// current tag, so the page's 3 s poll costs no body.
final class EditPageRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var scratch: URL!
    private var stateDir: URL!
    private var webRoot: URL!
    /// The checkout, by its real path.
    private var root: String!
    /// The same checkout through the `/var` symlink, as a client names it.
    private var rootAlias: String!

    private static let page = "<!doctype html><title>kitterm — edit</title><main id=\"edit\"></main>"

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-edit-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.appendingPathComponent("state").path), isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        webRoot = scratch.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
        try Self.page.write(to: webRoot.appendingPathComponent("edit.html"), atomically: true, encoding: .utf8)
        rootAlias = scratch.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: rootAlias + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: rootAlias + "/src", withIntermediateDirectories: true)
        try "config".write(toFile: rootAlias + "/.git/config", atomically: true, encoding: .utf8)
        try "hello\n".write(toFile: rootAlias + "/src/a.ts", atomically: true, encoding: .utf8)
        try "loose\n".write(toFile: scratch.appendingPathComponent("loose.txt").path, atomically: true, encoding: .utf8)
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
        let web = webRoot!
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(registry: registry, policy: policy, staticRoot: web)
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

    /// One HTTP/1.1 request over a raw socket, so every header is exactly
    /// what the test says (`URLSession` would add its own conditional
    /// headers and follow a 304 with a cached body).
    private func request(
        _ method: String, _ target: String, host: String? = nil, headers: [String] = []
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
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port!)")", "Connection: close"]
        lines += headers
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
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

    private func project(_ path: String, headers: [String] = [], host: String? = nil) throws -> Answer {
        try request("GET", "/api/files/project?path=\(encoded(path))", host: host, headers: headers)
    }

    private func content(_ path: String, headers: [String] = []) throws -> Answer {
        try request("GET", "/api/files/content?path=\(encoded(path))", headers: headers)
    }

    // MARK: - the page

    func testEditServesThePageLikeMd() throws {
        for target in ["/edit", "/edit?path=%2Fw%2Fa.ts&session=1", "/edit.html"] {
            let answer = try request("GET", target)
            XCTAssertEqual(answer.status, 200, target)
            XCTAssertEqual(answer.text, Self.page, target)
            XCTAssertTrue(answer.headers["content-type"]?.hasPrefix("text/html") ?? false, target)
            XCTAssertEqual(answer.headers["cache-control"], "no-cache", target)
        }
        XCTAssertEqual(try request("GET", "/editx").status, 404)
    }

    // MARK: - the project

    func testProjectNamesTheCheckoutThatWouldJailTheSave() throws {
        let answer = try project(rootAlias + "/src/a.ts")
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(answer.json["ok"] as? Bool, true)
        // The path is the lexical one the client named; the root is real.
        XCTAssertEqual(answer.json["path"] as? String, rootAlias + "/src/a.ts")
        let project = try XCTUnwrap(answer.json["project"] as? [String: Any], answer.text)
        XCTAssertEqual(project["root"] as? String, root)
        XCTAssertEqual(project["name"] as? String, "repo")
        XCTAssertEqual(project["id"] as? String, "repo")
        XCTAssertEqual(project["relative"] as? String, "src/a.ts")
    }

    func testProjectResolvesARelativePathAndATilde() throws {
        // With no session a relative path resolves against the home
        // directory, which is where the save route resolves it too.
        // The file need not exist; its parent must.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let answer = try project("kitterm-edit-page-probe.ts")
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(answer.json["path"] as? String, home + "/kitterm-edit-page-probe.ts")
        let tilde = try project("~/kitterm-edit-page-probe.ts")
        XCTAssertEqual(tilde.status, 200, tilde.text)
        XCTAssertEqual(tilde.json["path"] as? String, home + "/kitterm-edit-page-probe.ts")
    }

    func testAFileUnderNoProjectHasNoProjectAndAMissingParentIs404() throws {
        let loose = try project(scratch.appendingPathComponent("loose.txt").path)
        XCTAssertEqual(loose.status, 200, loose.text)
        XCTAssertEqual(loose.json["ok"] as? Bool, true)
        XCTAssertNil(loose.json["project"], loose.text)
        let missing = try project(rootAlias + "/nowhere/a.ts")
        XCTAssertEqual(missing.status, 404, missing.text)
        XCTAssertEqual(missing.error, "no such directory")
        XCTAssertEqual(try project("").status, 400)
    }

    func testProjectIsFullGradeOnly() async throws {
        try await restart(policy: .proxied(token: "ctl", watchToken: "ktw_w", trustedHosts: ["mac.example"]))
        let watch = try project(rootAlias + "/src/a.ts", headers: ["Cookie: kitterm_token=ktw_w"], host: "mac.example")
        XCTAssertEqual(watch.status, 403, watch.text)
        XCTAssertEqual(watch.error, "watch-only token")
        let full = try project(rootAlias + "/src/a.ts", headers: ["Cookie: kitterm_token=ctl"], host: "mac.example")
        XCTAssertEqual(full.status, 200, full.text)
    }

    // MARK: - the conditional read

    func testTheReadAnswers304ToTheTagItGave() throws {
        let path = rootAlias + "/src/a.ts"
        let first = try content(path)
        XCTAssertEqual(first.status, 200)
        let tag = try XCTUnwrap(first.headers["etag"])
        XCTAssertEqual(tag, FileEdit.etag(Data("hello\n".utf8)))

        let same = try content(path, headers: ["If-None-Match: \(tag)"])
        XCTAssertEqual(same.status, 304, same.text)
        XCTAssertEqual(same.headers["etag"], tag)
        XCTAssertEqual(same.body.count, 0)

        // The file changed: the whole answer again, with the new tag.
        try "changed\n".write(toFile: path, atomically: true, encoding: .utf8)
        let changed = try content(path, headers: ["If-None-Match: \(tag)"])
        XCTAssertEqual(changed.status, 200, changed.text)
        XCTAssertEqual(changed.text, "changed\n")
        XCTAssertEqual(changed.headers["etag"], FileEdit.etag(Data("changed\n".utf8)))

        // A weak tag, a list and a stranger's tag match nothing.
        for header in ["W/\(tag)", "\(tag), \"sha256:0\"", "\"sha256:0\""] {
            XCTAssertEqual(try content(path, headers: ["If-None-Match: \(header)"]).status, 200, header)
        }
    }

    func testATruncatedReadNeverMatches() throws {
        let path = rootAlias + "/src/big.txt"
        let big = String(repeating: "x", count: FileEdit.maxBytes + 1)
        try big.write(toFile: path, atomically: true, encoding: .utf8)
        let first = try content(path)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.headers["x-kitterm-truncated"], "1")
        XCTAssertNil(first.headers["etag"])
        let shown = Data(first.body.prefix(FileEdit.maxBytes))
        let again = try content(path, headers: ["If-None-Match: \(FileEdit.etag(shown))"])
        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(again.body.count, FileEdit.maxBytes)
    }
}
