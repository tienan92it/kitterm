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

#if canImport(Darwin)
private let socketType = SOCK_STREAM
#else
private let socketType = Int32(SOCK_STREAM.rawValue)
#endif

/// `GitRead.index` and `GitRead.filterHidden` (`code-editor` round 14, rule
/// 8 of `corpus/07-projects-and-tree.md`): the file index behind the
/// palette, direct, no HTTP.
final class GitFilesIndexTests: XCTestCase {
    private var git: String!
    private var scratch: URL!
    private var repo: String!

    override func setUpWithError() throws {
        git = try XCTUnwrap(PullRequestStatus.locate("git", in: PullRequestStatus.defaultSearchPath), "git on PATH")
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-files-index-\(UUID().uuidString)", isDirectory: true)
        let repoURL = scratch.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent(".build"), withIntermediateDirectories: true)
        repo = try XCTUnwrap(FileEdit.realPath(repoURL.path))
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "b\n".write(toFile: repo + "/src/b.ts", atomically: true, encoding: .utf8)
        try ".build/\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: repo + "/.build/x.txt", atomically: true, encoding: .utf8)
        try sh(repo, "init", "-q", "-b", "main")
        try sh(repo, "add", "a.txt", "src/b.ts", ".gitignore")
        try sh(repo, "commit", "-q", "-m", "init")
        // An untracked file `.gitignore` does not exclude: the index lists it
        // too (`--others --exclude-standard`).
        try "c\n".write(toFile: repo + "/c.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func sh(_ directory: String, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "t"
        environment["GIT_AUTHOR_EMAIL"] = "t@example"
        environment["GIT_COMMITTER_NAME"] = "t"
        environment["GIT_COMMITTER_EMAIL"] = "t@example"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard waitForExit(of: process, output: text) else { return text }
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")): \(text)")
        return text
    }

    /// Tracked, untracked-and-not-ignored, and ignored: the first two list,
    /// the third does not, relative to the toplevel.
    func testTheIndexListsTrackedAndUntrackedButNotIgnoredPaths() throws {
        let gitRead = GitRead()
        let (files, truncated) = try gitRead.index(of: GitRead.Repository(toplevel: repo, relative: ""))
        XCTAssertEqual(Set(files), ["a.txt", "src/b.ts", ".gitignore", "c.txt"])
        XCTAssertFalse(files.contains(".build/x.txt"))
        XCTAssertFalse(truncated)
    }

    /// The cap, through a small injected limit: `GitRead.index(of:limit:)`
    /// takes it as a parameter so the route's default of 20000 need not be
    /// reached to prove the behaviour.
    func testTheCapTruncatesThroughASmallInjectedLimit() throws {
        let gitRead = GitRead()
        let (files, truncated) = try gitRead.index(of: GitRead.Repository(toplevel: repo, relative: ""), limit: 2)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(truncated)
        let (untruncated, notTruncated) = try gitRead.index(of: GitRead.Repository(toplevel: repo, relative: ""), limit: 100)
        XCTAssertEqual(untruncated.count, 4)
        XCTAssertFalse(notTruncated)
    }

    /// `filterHidden` (the tree's own `HIDDEN_NAMES`, `edit-tree.ts`): a
    /// path under any of the six names is dropped at any depth, a path that
    /// merely contains one of the names as a substring is kept.
    func testFilterHiddenDropsAPathUnderAHiddenNameAtAnyDepth() {
        let paths = ["a.txt", "src/.git/HEAD", ".git/config", "x/.svn/entries", "x/.DS_Store", "Thumbs.db", "a.gitignore", "not.hidden/CVS/x"]
        XCTAssertEqual(GitRead.filterHidden(paths), ["a.txt", "a.gitignore"])
    }
}

/// `GET /api/files/index?path=<file or folder>&session=<id>` over HTTP: the
/// root, the files, the `ETag` and 304, and the grade and repository
/// refusals every other file and git route shares.
final class FilesIndexRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var scratch: URL!
    private var stateDir: URL!
    private var repo: String!
    private var git: String!

    override func setUpWithError() throws {
        git = try XCTUnwrap(PullRequestStatus.locate("git", in: PullRequestStatus.defaultSearchPath), "git on PATH")
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-files-index-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.appendingPathComponent("state").path), isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        let repoAlias = scratch.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: repoAlias, withIntermediateDirectories: true)
        repo = try XCTUnwrap(FileEdit.realPath(repoAlias))
        try FileManager.default.createDirectory(atPath: scratch.appendingPathComponent("plain").path, withIntermediateDirectories: true)
        try "loose\n".write(toFile: scratch.appendingPathComponent("plain/loose.txt").path, atomically: true, encoding: .utf8)
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try sh(repo, "init", "-q", "-b", "main")
        try sh(repo, "add", "a.txt")
        try sh(repo, "commit", "-q", "-m", "init")
        try start(policy: .loopbackOnly)
    }

    override func tearDown() async throws {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        group = nil
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func sh(_ directory: String, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "t"
        environment["GIT_AUTHOR_EMAIL"] = "t@example"
        environment["GIT_COMMITTER_NAME"] = "t"
        environment["GIT_COMMITTER_EMAIL"] = "t@example"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard waitForExit(of: process, output: text) else { return text }
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")): \(text)")
        return text
    }

    private func start(policy: AccessPolicy) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let registry = SessionRegistry()
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPAPIHandler(registry: registry, policy: policy, gitRead: GitRead()))
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

    private func request(_ target: String, host: String? = nil, headers: [String] = []) throws -> Answer {
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
        var lines = ["GET \(target) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port!)")", "Connection: close"]
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

    private func index(_ path: String, headers: [String] = [], host: String? = nil) throws -> Answer {
        try request("/api/files/index?path=\(encoded(path))", host: host, headers: headers)
    }

    func testTheIndexNamesTheRootAndTheFiles() throws {
        let answer = try index(repo + "/a.txt")
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(answer.json["ok"] as? Bool, true)
        XCTAssertEqual(answer.json["root"] as? String, repo)
        XCTAssertEqual(answer.json["files"] as? [String], ["a.txt"])
        XCTAssertEqual(answer.json["truncated"] as? Bool, false)
        XCTAssertEqual(answer.headers["cache-control"], "no-cache")
        XCTAssertEqual(answer.headers["content-type"], "application/json")
    }

    /// A folder opens too (`path=<file or folder>`): the same resolution
    /// `GET /api/git/status` and `GET /api/git/diff` share.
    func testAFolderPathResolvesTheSameRepository() throws {
        let answer = try index(repo)
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(answer.json["root"] as? String, repo)
    }

    func testAnswers304ToItsOwnTag() throws {
        let first = try index(repo + "/a.txt")
        let tag = try XCTUnwrap(first.headers["etag"])
        let same = try index(repo + "/a.txt", headers: ["If-None-Match: \(tag)"])
        XCTAssertEqual(same.status, 304, same.text)
        XCTAssertEqual(same.body.count, 0)
    }

    func testAPathInNoRepositoryIs404AndNoPathIs400() throws {
        let loose = try index(scratch.appendingPathComponent("plain/loose.txt").path)
        XCTAssertEqual(loose.status, 404, loose.text)
        XCTAssertEqual(loose.error, "outside every project")
        XCTAssertEqual(try index("").status, 400)
    }

    func testFullGradeOnly() async throws {
        try await restart(policy: .proxied(token: "ctl", watchToken: "ktw_w", trustedHosts: ["mac.example"]))
        let watch = try index(repo + "/a.txt", headers: ["Cookie: kitterm_token=ktw_w"], host: "mac.example")
        XCTAssertEqual(watch.status, 403, watch.text)
        XCTAssertEqual(watch.error, "watch-only token")
        let full = try index(repo + "/a.txt", headers: ["Cookie: kitterm_token=ctl"], host: "mac.example")
        XCTAssertEqual(full.status, 200, full.text)
    }
}
