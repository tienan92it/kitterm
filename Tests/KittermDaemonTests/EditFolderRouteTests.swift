import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// The folder form of `/edit` (`code-editor` round 7, `corpus/04-quick-open.md`
/// item 1): `GET /api/files/project` says whether the path is a file or a
/// directory, locates a directory by itself so a checkout's root is its own
/// project, and `GET /api/git/status` answers for a directory, the root
/// included, because the page drives its git tab with the folder's path.
final class EditFolderRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var scratch: URL!
    private var stateDir: URL!
    /// The checkout as a client names it, through the `/var` symlink.
    private var repoAlias: String!
    /// The same checkout by its real path, as the daemon names roots.
    private var repo: String!
    private var git: String!

    override func setUpWithError() throws {
        git = try XCTUnwrap(PullRequestStatus.locate("git", in: PullRequestStatus.defaultSearchPath), "git on PATH")
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-edit-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.appendingPathComponent("state").path), isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        repoAlias = scratch.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: repoAlias + "/src", withIntermediateDirectories: true)
        try "hello\n".write(toFile: repoAlias + "/src/a.ts", atomically: true, encoding: .utf8)
        try "# repo\n".write(toFile: repoAlias + "/README.md", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: scratch.appendingPathComponent("plain").path, withIntermediateDirectories: true)
        repo = try XCTUnwrap(FileEdit.realPath(repoAlias))
        try sh(repo, "init", "-q", "-b", "main")
        try start()
    }

    override func tearDown() async throws {
        FileEdit.queue.sync {}
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        group = nil
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: scratch)
    }

    private func sh(_ directory: String, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard waitForExit(of: process, output: text) else { return }
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")): \(text)")
    }

    private func start() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let registry = SessionRegistry()
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(registry: registry, policy: .loopbackOnly, gitRead: GitRead())
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    private struct Answer {
        let status: Int
        let json: [String: Any]
        var project: [String: Any]? { json["project"] as? [String: Any] }
    }

    /// One plain GET; the routes under test take no conditional header.
    private func get(_ route: String, path: String) throws -> Answer {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port!)\(route)?path=\(encoded)"))
        let done = expectation(description: route)
        var answer = Answer(status: 0, json: [:])
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            XCTAssertNil(error)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            answer = Answer(status: status, json: json)
            done.fulfill()
        }
        task.resume()
        wait(for: [done], timeout: 10)
        return answer
    }

    func testTheProjectRouteLocatesADirectoryByItself() throws {
        let root = try get("/api/files/project", path: repoAlias)
        XCTAssertEqual(root.status, 200)
        XCTAssertEqual(root.json["kind"] as? String, "directory")
        XCTAssertEqual(root.json["path"] as? String, repoAlias)
        XCTAssertEqual(root.project?["root"] as? String, repo)
        XCTAssertEqual(root.project?["name"] as? String, "repo")
        XCTAssertEqual(root.project?["relative"] as? String, "")

        let folder = try get("/api/files/project", path: repoAlias + "/src")
        XCTAssertEqual(folder.json["kind"] as? String, "directory")
        XCTAssertEqual(folder.project?["root"] as? String, repo)
        XCTAssertEqual(folder.project?["relative"] as? String, "src")

        // A file keeps the round 4 answer, with its kind beside it.
        let file = try get("/api/files/project", path: repoAlias + "/src/a.ts")
        XCTAssertEqual(file.json["kind"] as? String, "file")
        XCTAssertEqual(file.project?["relative"] as? String, "src/a.ts")

        // A folder under no project: the kind, no project.
        let plain = try get("/api/files/project", path: scratch.appendingPathComponent("plain").path)
        XCTAssertEqual(plain.status, 200)
        XCTAssertEqual(plain.json["kind"] as? String, "directory")
        XCTAssertNil(plain.project)
    }

    func testGitStatusAnswersForTheRootAndAFolderOfTheRepository() throws {
        let projects = ProjectStore()
        let read = GitRead()
        XCTAssertEqual(try read.repository(for: repoAlias, projects: projects).get(), GitRead.Repository(toplevel: repo, relative: ""))
        XCTAssertEqual(try read.repository(for: repoAlias + "/src", projects: projects).get(), GitRead.Repository(toplevel: repo, relative: "src"))
        // A file keeps its own rule: the parent's repository, the file's path.
        XCTAssertEqual(try read.repository(for: repoAlias + "/src/a.ts", projects: projects).get(), GitRead.Repository(toplevel: repo, relative: "src/a.ts"))

        let status = try get("/api/git/status", path: repoAlias)
        XCTAssertEqual(status.status, 200, "\(status.json)")
        XCTAssertEqual(status.json["root"] as? String, repo)
        let files = try XCTUnwrap(status.json["files"] as? [[String: Any]])
        // Git lists an untracked folder as one entry, `src/`.
        XCTAssertEqual(Set(files.compactMap { $0["path"] as? String }), ["README.md", "src/"])

        let plain = try get("/api/git/status", path: scratch.appendingPathComponent("plain").path)
        XCTAssertEqual(plain.status, 404)
    }
}
