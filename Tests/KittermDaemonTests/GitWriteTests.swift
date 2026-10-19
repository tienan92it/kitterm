#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers
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

/// The pure parts of `GitWrite` (`code-editor` round 6): the argv of every
/// write on a fake runner, the path and name rules, the failure line and
/// the output lines.
final class GitWriteTests: XCTestCase {
    private let repository = GitRead.Repository(toplevel: "/w/repo", relative: "src/a.ts")

    private func writer(_ seen: NIOLockedValueBox<[(args: [String], input: Data?, timeout: TimeInterval)]>, answer: @escaping @Sendable ([String]) -> PullRequestStatus.RunResult) -> GitWrite {
        GitWrite(run: { args, input, timeout in
            seen.withLockedValue { $0.append((args, input, timeout)) }
            return answer(args)
        })
    }

    func testEveryWriteCarriesTheOptionsAndPutsDataAfterTheSeparator() throws {
        let seen = NIOLockedValueBox<[(args: [String], input: Data?, timeout: TimeInterval)]>([])
        let git = writer(seen) { args in
            if args.contains("check-ref-format") { return .init(status: 0, output: Data((args.last! + "\n").utf8)) }
            if args.contains("--git-path") { return .init(status: 0, output: Data(".git/index.lock\n".utf8)) }
            if args.contains("symbolic-ref") { return .init(status: 0, output: Data("main\n".utf8)) }
            if args.contains("for-each-ref") { return .init(status: 0, output: Data("origin\nrefs/heads/main\n".utf8)) }
            if args.contains("rev-parse") { return .init(status: 0, output: Data("abc123\n".utf8)) }
            return .init(status: 0, output: Data("[main abc123] msg\n".utf8))
        }
        _ = try git.stage(repository, paths: ["src/a.ts", "b.txt"])
        _ = try git.unstage(repository, paths: ["src/a.ts"])
        let commit = try git.commit(repository, message: "a message\n\nwith a body")
        let push = try git.push(repository)
        _ = try git.branch(repository, name: "feature/x", create: true)
        _ = try git.branch(repository, name: "main", create: false)
        let calls = seen.withLockedValue { $0 }
        for call in calls {
            XCTAssertEqual(Array(call.args.prefix(2)), ["-C", "/w/repo"], call.args.joined(separator: " "))
            XCTAssertEqual(Array(call.args.dropFirst(2).prefix(GitWrite.writeOptions.count)), GitWrite.writeOptions, call.args.joined(separator: " "))
        }
        let subcommands = calls.map { Array($0.args.dropFirst(2 + GitWrite.writeOptions.count)) }
        XCTAssertTrue(subcommands.contains(["add", "--", "src/a.ts", "b.txt"]), "\(subcommands)")
        XCTAssertTrue(subcommands.contains(["restore", "--staged", "--", "src/a.ts"]), "\(subcommands)")
        XCTAssertTrue(subcommands.contains(["commit", "-F", "-"]), "\(subcommands)")
        XCTAssertTrue(subcommands.contains(["push", "--end-of-options", "origin", "refs/heads/main:refs/heads/main"]), "\(subcommands)")
        XCTAssertTrue(subcommands.contains(["switch", "--create", "feature/x"]), "\(subcommands)")
        XCTAssertTrue(subcommands.contains(["switch", "--end-of-options", "main"]), "\(subcommands)")
        XCTAssertTrue(subcommands.contains(["check-ref-format", "--branch", "feature/x"]), "\(subcommands)")
        // The message rides stdin with a trailing newline, never argv.
        let commitCall = try XCTUnwrap(calls.first { $0.args.contains("commit") })
        XCTAssertEqual(commitCall.input, Data("a message\n\nwith a body\n".utf8))
        XCTAssertEqual(commitCall.timeout, GitWrite.longTimeoutSeconds)
        XCTAssertFalse(calls.contains { $0.args.contains("with a body") })
        let pushCall = try XCTUnwrap(calls.first { $0.args.contains("push") })
        XCTAssertEqual(pushCall.timeout, GitWrite.longTimeoutSeconds)
        XCTAssertFalse(pushCall.args.contains { $0.hasPrefix("--force") || $0 == "-f" })
        XCTAssertEqual(commit.fields["oid"], "abc123")
        XCTAssertEqual(commit.fields["branch"], "main")
        XCTAssertEqual(commit.lines, ["[main abc123] msg"])
        XCTAssertEqual(push.fields["remote"], "origin")
        // A stage with the lock file reads the lock's path first and runs
        // no `add` while it exists.
        XCTAssertTrue(subcommands.contains(["rev-parse", "--git-path", "index.lock"]))
    }

    func testAPushWithNoUpstreamSetsOneOnOriginAndADetachedHeadIsAConflict() throws {
        let seen = NIOLockedValueBox<[(args: [String], input: Data?, timeout: TimeInterval)]>([])
        let git = writer(seen) { args in
            if args.contains("symbolic-ref") { return .init(status: 0, output: Data("feature\n".utf8)) }
            if args.contains("for-each-ref") { return .init(status: 0, output: Data("\n\n".utf8)) }
            if args.contains("get-url") { return .init(status: 0, output: Data("/r.git\n".utf8)) }
            return .init(status: 0)
        }
        _ = try git.push(repository)
        let pushed = seen.withLockedValue { $0 }.first { $0.args.contains("push") }?.args ?? []
        XCTAssertEqual(Array(pushed.suffix(5)), ["push", "--set-upstream", "--end-of-options", "origin", "feature"])

        let noOrigin = GitWrite(run: { args, _, _ in
            if args.contains("symbolic-ref") { return .init(status: 0, output: Data("feature\n".utf8)) }
            if args.contains("get-url") { return .init(status: 2, error: "error: No such remote 'origin'") }
            return .init(status: 0)
        })
        XCTAssertThrowsError(try noOrigin.push(repository)) { error in
            XCTAssertEqual(error as? GitWrite.Failure, .conflict("no upstream and no origin remote"))
        }
        let detached = GitWrite(run: { args, _, _ in
            if args.contains("symbolic-ref") { return .init(status: 1) }
            return .init(status: 0)
        })
        XCTAssertThrowsError(try detached.push(repository)) { error in
            XCTAssertEqual(error as? GitWrite.Failure, .conflict("HEAD is detached: nothing to push"))
        }
    }

    func testTheUnstageOfARepositoryWithNoCommitUsesRmCached() throws {
        let seen = NIOLockedValueBox<[(args: [String], input: Data?, timeout: TimeInterval)]>([])
        let git = writer(seen) { args in
            if args.contains("--verify") { return .init(status: 1) }
            return .init(status: 0)
        }
        _ = try git.unstage(repository, paths: ["x.txt"])
        let rm = seen.withLockedValue { $0 }.first { $0.args.contains("rm") }?.args ?? []
        XCTAssertEqual(Array(rm.suffix(7)), ["rm", "--cached", "-r", "-q", "--force", "--", "x.txt"])
    }

    func testAPathOrANameThatIsNotDataIsRefusedBeforeAnyGitRuns() {
        let seen = NIOLockedValueBox<[(args: [String], input: Data?, timeout: TimeInterval)]>([])
        let git = writer(seen) { _ in .init(status: 0) }
        for bad in ["-rf", "/etc/passwd", "../x", "a/../b", "", "a/./b"] {
            XCTAssertThrowsError(try git.stage(repository, paths: [bad]), bad) { error in
                guard case .refused = error as? GitWrite.Failure else { return XCTFail("\(bad): \(error)") }
            }
        }
        for bad in ["-x", "--force", "", "a b", "a\nb"] {
            XCTAssertThrowsError(try git.branch(repository, name: bad, create: true), bad) { error in
                guard case .refused = error as? GitWrite.Failure else { return XCTFail("\(bad): \(error)") }
            }
        }
        XCTAssertThrowsError(try git.commit(repository, message: " \n\t")) { error in
            XCTAssertEqual(error as? GitWrite.Failure, .refused("the message is empty"))
        }
        XCTAssertThrowsError(try git.stage(repository, paths: []))
        XCTAssertEqual(seen.withLockedValue { $0.count }, 0, "nothing ran")
        // A name `check-ref-format --branch` changes or refuses.
        let checking = GitWrite(run: { args, _, _ in
            if args.contains("check-ref-format") {
                return args.last == "@{-1}" ? .init(status: 0, output: Data("main\n".utf8)) : .init(status: 128, error: "fatal: 'bad..name' is not a valid branch name")
            }
            return .init(status: 0)
        })
        XCTAssertThrowsError(try checking.branch(repository, name: "bad..name", create: false)) { error in
            XCTAssertEqual(error as? GitWrite.Failure, .refused("the branch name is refused: bad..name"))
        }
        XCTAssertThrowsError(try checking.branch(repository, name: "@{-1}", create: false)) { error in
            XCTAssertEqual(error as? GitWrite.Failure, .refused("the branch name is refused: @{-1}"))
        }
    }

    func testGitsOwnLockErrorAndAFailedCommandAreTold() {
        let locked = GitWrite(run: { args, _, _ in
            if args.contains("add") { return .init(status: 128, error: "fatal: Unable to create '/w/repo/.git/index.lock': File exists.\n") }
            return .init(status: 0)
        })
        XCTAssertThrowsError(try locked.stage(repository, paths: ["a"])) { error in
            XCTAssertEqual(error as? GitWrite.Failure, .locked)
        }
        let rejected = GitWrite(run: { args, _, _ in
            if args.contains("symbolic-ref") { return .init(status: 0, output: Data("main\n".utf8)) }
            if args.contains("for-each-ref") { return .init(status: 0, output: Data("origin\nrefs/heads/main\n".utf8)) }
            if args.contains("push") {
                return .init(status: 1, output: Data(), error: "To /r.git\n ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs to '/r.git'\nhint: Updates were rejected\n")
            }
            return .init(status: 0)
        })
        XCTAssertThrowsError(try rejected.push(repository)) { error in
            guard case .failed(let line, let lines) = error as? GitWrite.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(line, "git push exited 1: ! [rejected] main -> main (fetch first)")
            XCTAssertEqual(lines.count, 4)
        }
        let timedOut = GitWrite(run: { args, _, _ in
            if args.contains("commit") { return .init(status: -1, timedOut: true) }
            return .init(status: 0)
        })
        XCTAssertThrowsError(try timedOut.commit(repository, message: "m")) { error in
            XCTAssertEqual((error as? GitWrite.Failure)?.reason, "git commit timed out after 120 s")
        }
        let nothing = GitWrite(run: { args, _, _ in
            if args.contains("commit") { return .init(status: 1, output: Data("On branch main\nnothing to commit, working tree clean\n".utf8)) }
            return .init(status: 0)
        })
        XCTAssertThrowsError(try nothing.commit(repository, message: "m")) { error in
            XCTAssertEqual((error as? GitWrite.Failure)?.reason, "git commit exited 1: nothing to commit, working tree clean")
        }
    }

    func testTheOutputKeepsTheLastEightLines() {
        let out = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let lines = GitWrite.lastLines(stdout: Data(out.utf8), stderr: "  \nhook: ok\n")
        XCTAssertEqual(lines, ["line 6", "line 7", "line 8", "line 9", "line 10", "line 11", "line 12", "hook: ok"])
        XCTAssertEqual(GitWrite.lastLines(stdout: Data(), stderr: ""), [])
    }
}

/// The five routes against a scratch repository with a bare remote
/// (`goal.md` conditions 11 and 12): stage and unstage (in a repository
/// with no commit too), commit with hooks, push with and without an
/// upstream, branch create and switch, the refusals, the lock, the grades
/// and the audit line.
final class GitWriteRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var scratch: URL!
    private var stateDir: URL!
    private var repo: String!
    private var bare: String!
    private var git: String!
    private var savedGlobal: String?
    private var savedSystem: String?

    override func setUpWithError() throws {
        git = try XCTUnwrap(PullRequestStatus.locate("git", in: PullRequestStatus.defaultSearchPath), "git on PATH")
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-git-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.appendingPathComponent("state").path), isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        // The daemon's git inherits this process's environment: the human's
        // global config (a signing key, a hooks path) stays out of the test.
        savedGlobal = ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]
        savedSystem = ProcessInfo.processInfo.environment["GIT_CONFIG_SYSTEM"]
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
        let repoAlias = scratch.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: repoAlias + "/src", withIntermediateDirectories: true)
        repo = try XCTUnwrap(FileEdit.realPath(repoAlias))
        try seed()
        try start(policy: .loopbackOnly, agentControl: true)
    }

    override func tearDown() async throws {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        group = nil
        unsetenv("KITTERM_STATE_DIR")
        if let savedGlobal { setenv("GIT_CONFIG_GLOBAL", savedGlobal, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") }
        if let savedSystem { setenv("GIT_CONFIG_SYSTEM", savedSystem, 1) } else { unsetenv("GIT_CONFIG_SYSTEM") }
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - the repository

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

    /// One commit pushed to the bare remote; `a.txt` modified, `b.txt`
    /// staged, `new.txt` untracked. The identity lives in the repository's
    /// own config, where the daemon's `git commit` finds it.
    private func seed() throws {
        bare = scratch.appendingPathComponent("remote.git").path
        try sh(scratch.path, "init", "-q", "--bare", "-b", "main", bare)
        try sh(repo, "init", "-q", "-b", "main")
        try sh(repo, "config", "user.name", "t")
        try sh(repo, "config", "user.email", "t@example")
        for (name, text) in [("a.txt", "one\ntwo\n"), ("b.txt", "b\n"), ("src/d.txt", "d\n")] {
            try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8)
        }
        try sh(repo, "add", "-A")
        try sh(repo, "commit", "-q", "-m", "init")
        try sh(repo, "remote", "add", "origin", bare)
        try sh(repo, "push", "-q", "-u", "origin", "main")
        try "one\nTWO\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "B\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
        try sh(repo, "add", "b.txt")
        try "new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    }

    private func hook(_ name: String, _ script: String) throws {
        let path = repo + "/.git/hooks/" + name
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    // MARK: - the server

    private func start(policy: AccessPolicy, agentControl: Bool) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let registry = SessionRegistry()
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPAPIHandler(
                        registry: registry, policy: policy, agentControl: agentControl, gitRead: GitRead(), gitWrite: GitWrite()
                    ))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    private func restart(policy: AccessPolicy, agentControl: Bool) async throws {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        try start(policy: policy, agentControl: agentControl)
    }

    private struct Answer: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var error: String { json["error"] as? String ?? "" }
        var lines: [String] { json["lines"] as? [String] ?? [] }
    }

    private func request(_ method: String, _ target: String, host: String? = nil, headers: [String] = [], body: Data? = nil) throws -> Answer {
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

    private var ownOrigin: String { "http://127.0.0.1:\(port!)" }

    /// One write with the editor header and the page's own `Origin`;
    /// `dropping` leaves a header out and `extra` adds some.
    private func write(
        _ kind: String, _ fields: [String: Any], dropping: [String] = [], extra: [String] = [], host: String? = nil
    ) throws -> Answer {
        var headers = ["Content-Type: application/json"]
        if !dropping.contains("X-Kitterm-Editor") { headers.append("X-Kitterm-Editor: 1") }
        if !dropping.contains("Origin") { headers.append("Origin: \(host.map { "http://\($0)" } ?? ownOrigin)") }
        headers += extra
        let body = try JSONSerialization.data(withJSONObject: fields)
        return try request("POST", "/api/git/\(kind)", host: host, headers: headers, body: body)
    }

    private func status() throws -> [String: Any] {
        let encoded = (repo + "/a.txt").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return try request("GET", "/api/git/status?path=\(encoded)").json
    }

    private func entries() throws -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for item in try status()["files"] as? [[String: Any]] ?? [] {
            if let path = item["path"] as? String { out[path] = item }
        }
        return out
    }

    private func auditLines() throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: DaemonPaths.editsLogFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    // MARK: - stage and unstage

    func testStageAndUnstageMoveTheFileBetweenTheColumns() throws {
        XCTAssertEqual(try entries()["a.txt"]?["index"] as? String, ".")
        let staged = try write("stage", ["path": repo + "/a.txt"])
        XCTAssertEqual(staged.status, 200, staged.text)
        XCTAssertEqual(staged.json["paths"] as? [String], ["a.txt"])
        XCTAssertEqual(try entries()["a.txt"]?["index"] as? String, "M")
        XCTAssertEqual(try entries()["a.txt"]?["worktree"] as? String, ".")
        // The untracked file by its path, named in `paths`.
        let untracked = try write("stage", ["path": repo + "/a.txt", "paths": ["new.txt"]])
        XCTAssertEqual(untracked.status, 200, untracked.text)
        XCTAssertEqual(try entries()["new.txt"]?["index"] as? String, "A")
        let unstaged = try write("unstage", ["path": repo + "/a.txt", "paths": ["a.txt", "b.txt"]])
        XCTAssertEqual(unstaged.status, 200, unstaged.text)
        XCTAssertEqual(try entries()["a.txt"]?["index"] as? String, ".")
        XCTAssertEqual(try entries()["a.txt"]?["worktree"] as? String, "M")
        XCTAssertEqual(try entries()["b.txt"]?["index"] as? String, ".")
        XCTAssertEqual(try entries()["b.txt"]?["worktree"] as? String, "M")
        XCTAssertEqual(try status()["writes"] as? Bool, true)
        XCTAssertEqual(try status()["branches"] as? [String], ["main"])
        let audit = try auditLines()
        XCTAssertEqual(audit.count, 3, "\(audit)")
        XCTAssertEqual(audit[0]["git"] as? String, "stage")
        XCTAssertEqual(audit[0]["paths"] as? [String], ["a.txt"])
        XCTAssertEqual(audit[0]["status"] as? Int, 200)
        XCTAssertEqual(audit[0]["token"] as? String, "loopback")
        XCTAssertEqual(audit[2]["git"] as? String, "unstage")
        XCTAssertEqual(audit[2]["paths"] as? [String], ["a.txt", "b.txt"])
    }

    func testUnstageInARepositoryWithNoCommitYet() throws {
        let fresh = scratch.appendingPathComponent("fresh").path
        try sh(scratch.path, "init", "-q", "-b", "main", fresh)
        try "x\n".write(toFile: fresh + "/x.txt", atomically: true, encoding: .utf8)
        try "y\n".write(toFile: fresh + "/y.txt", atomically: true, encoding: .utf8)
        try sh(fresh, "add", "x.txt", "y.txt")
        try "yy\n".write(toFile: fresh + "/y.txt", atomically: true, encoding: .utf8)
        let answer = try write("unstage", ["path": fresh + "/x.txt", "paths": ["x.txt", "y.txt"]])
        XCTAssertEqual(answer.status, 200, answer.text)
        let listed = try sh(fresh, "status", "--porcelain")
        XCTAssertEqual(listed, "?? x.txt\n?? y.txt\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh + "/y.txt"), "the working tree file stays")
    }

    // MARK: - commit

    func testCommitWritesTheMessageAsSentAndAnswersTheIdAndTheLines() throws {
        let message = "code-editor: the write routes\n\nA body line with #hash and \"quotes\" --and-dashes\n"
        let answer = try write("commit", ["path": repo + "/b.txt", "message": message])
        XCTAssertEqual(answer.status, 200, answer.text)
        let oid = try XCTUnwrap(answer.json["oid"] as? String)
        XCTAssertEqual(oid.count, 40)
        XCTAssertEqual(answer.json["branch"] as? String, "main")
        XCTAssertEqual(try sh(repo, "log", "-1", "--format=%B"), message + "\n")
        XCTAssertEqual(try sh(repo, "rev-parse", "HEAD"), oid + "\n")
        XCTAssertTrue(answer.lines.contains { $0.contains("1 file changed") }, "\(answer.lines)")
        XCTAssertEqual(try status()["ahead"] as? Int, 1)
        // Only the staged file went: a.txt is still modified.
        XCTAssertEqual(try entries()["a.txt"]?["worktree"] as? String, "M")
        XCTAssertNil(try entries()["b.txt"])
        let audit = try auditLines()
        XCTAssertEqual(audit.last?["git"] as? String, "commit")
        XCTAssertEqual(audit.last?["status"] as? Int, 200)
        XCTAssertNil(audit.last?["paths"])
        let raw = try String(contentsOf: DaemonPaths.editsLogFile, encoding: .utf8)
        XCTAssertFalse(raw.contains("write routes"), "the message is never logged")
        XCTAssertFalse(raw.contains("body line"))
    }

    func testAnEmptyMessageIs400AndNothingIsCommitted() throws {
        let before = try sh(repo, "rev-parse", "HEAD")
        for message in ["", "  \n\t"] {
            let answer = try write("commit", ["path": repo + "/b.txt", "message": message])
            XCTAssertEqual(answer.status, 400, answer.text)
            XCTAssertEqual(answer.error, "the message is empty")
        }
        XCTAssertEqual(try write("commit", ["path": repo + "/b.txt"]).status, 400)
        XCTAssertEqual(try sh(repo, "rev-parse", "HEAD"), before)
        XCTAssertEqual(try auditLines().map { $0["status"] as? Int }, [400, 400, 400])
    }

    func testAPreCommitHookThatPrintsAndPassesHasItsLinesInTheAnswer() throws {
        try hook("pre-commit", "#!/bin/sh\necho 'pre-commit: checking'\necho 'tests: 12 passed' >&2\nexit 0\n")
        try hook("commit-msg", "#!/bin/sh\necho 'commit-msg: ok'\nexit 0\n")
        let answer = try write("commit", ["path": repo + "/b.txt", "message": "with hooks"])
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertTrue(answer.lines.contains("pre-commit: checking"), "\(answer.lines)")
        XCTAssertTrue(answer.lines.contains("commit-msg: ok"), "\(answer.lines)")
        XCTAssertTrue(answer.lines.contains("tests: 12 passed"), "\(answer.lines)")
        XCTAssertLessThanOrEqual(answer.lines.count, GitWrite.outputLines)
        XCTAssertEqual(try sh(repo, "log", "-1", "--format=%s"), "with hooks\n")
    }

    func testAPreCommitHookThatFailsIs502WithItsLineAndNothingIsCommitted() throws {
        try hook("pre-commit", "#!/bin/sh\necho 'lint: 3 errors in b.txt' >&2\necho 'see the log'\nexit 1\n")
        let before = try sh(repo, "rev-parse", "HEAD")
        let answer = try write("commit", ["path": repo + "/b.txt", "message": "refused by the hook"])
        XCTAssertEqual(answer.status, 502, answer.text)
        XCTAssertEqual(answer.error, "git commit exited 1: lint: 3 errors in b.txt")
        XCTAssertTrue(answer.lines.contains("see the log"), "\(answer.lines)")
        XCTAssertEqual(try sh(repo, "rev-parse", "HEAD"), before)
        XCTAssertEqual(try entries()["b.txt"]?["index"] as? String, "M", "still staged")
        XCTAssertEqual(try auditLines().last?["status"] as? Int, 502)
    }

    func testAHookThatPrintsManyLinesKeepsTheLastEight() throws {
        try hook("pre-commit", "#!/bin/sh\ni=1\nwhile [ $i -le 20 ]; do echo \"line $i\"; i=$((i+1)); done\nexit 0\n")
        let answer = try write("commit", ["path": repo + "/b.txt", "message": "long hook"])
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(answer.lines.count, GitWrite.outputLines)
        XCTAssertTrue(answer.lines.contains("line 20"), "\(answer.lines)")
        XCTAssertFalse(answer.lines.contains("line 1"))
    }

    // MARK: - push

    func testPushMovesTheRemoteAndPushWithNoUpstreamSetsOne() throws {
        let commit = try write("commit", ["path": repo + "/b.txt", "message": "to push"])
        XCTAssertEqual(commit.status, 200, commit.text)
        XCTAssertEqual(try status()["ahead"] as? Int, 1)
        let pushed = try write("push", ["path": repo + "/b.txt"])
        XCTAssertEqual(pushed.status, 200, pushed.text)
        XCTAssertEqual(pushed.json["branch"] as? String, "main")
        XCTAssertEqual(pushed.json["remote"] as? String, "origin")
        XCTAssertEqual(try sh(bare, "rev-parse", "main"), try sh(repo, "rev-parse", "HEAD"))
        XCTAssertEqual(try status()["ahead"] as? Int, 0)
        XCTAssertEqual(try auditLines().last?["git"] as? String, "push")
        XCTAssertEqual(try auditLines().last?["branch"] as? String, "main")

        // A new branch has no upstream: the push sets one on origin.
        let created = try write("branch", ["path": repo + "/b.txt", "create": "feature/one"])
        XCTAssertEqual(created.status, 200, created.text)
        XCTAssertEqual(created.json["branch"] as? String, "feature/one")
        XCTAssertEqual(created.json["created"] as? Bool, true)
        XCTAssertEqual(try status()["upstream"] as? String, nil)
        let first = try write("push", ["path": repo + "/b.txt"])
        XCTAssertEqual(first.status, 200, first.text)
        XCTAssertEqual(try sh(repo, "rev-parse", "--abbrev-ref", "@{u}"), "origin/feature/one\n")
        XCTAssertEqual(try sh(bare, "rev-parse", "feature/one"), try sh(repo, "rev-parse", "HEAD"))
        XCTAssertEqual(try status()["upstream"] as? String, "origin/feature/one")
    }

    func testARejectedPushIs502WithTheRejectionLine() throws {
        // The remote moves on from another clone; a plain push is rejected
        // and never forced.
        let other = scratch.appendingPathComponent("other").path
        try sh(scratch.path, "clone", "-q", bare, other)
        try sh(other, "config", "user.name", "o")
        try sh(other, "config", "user.email", "o@example")
        try "e\n".write(toFile: other + "/e.txt", atomically: true, encoding: .utf8)
        try sh(other, "add", "e.txt")
        try sh(other, "commit", "-q", "-m", "e")
        try sh(other, "push", "-q", "origin", "main")
        let remoteHead = try sh(bare, "rev-parse", "main")
        XCTAssertEqual(try write("commit", ["path": repo + "/b.txt", "message": "local"]).status, 200)
        let answer = try write("push", ["path": repo + "/b.txt"])
        XCTAssertEqual(answer.status, 502, answer.text)
        XCTAssertTrue(answer.error.hasPrefix("git push exited 1: ! [rejected] main -> main"), answer.error)
        XCTAssertEqual(try sh(bare, "rev-parse", "main"), remoteHead, "the remote is untouched")
    }

    func testAPushWithNoUpstreamAndNoOriginIs409() throws {
        try sh(repo, "remote", "rename", "origin", "upstream")
        try sh(repo, "branch", "--unset-upstream")
        let answer = try write("push", ["path": repo + "/b.txt"])
        XCTAssertEqual(answer.status, 409, answer.text)
        XCTAssertEqual(answer.error, "no upstream and no origin remote")
    }

    // MARK: - branch

    func testBranchCreateAndSwitchAndTheRefusedNames() throws {
        let created = try write("branch", ["path": repo + "/b.txt", "create": "side"])
        XCTAssertEqual(created.status, 200, created.text)
        XCTAssertEqual(try sh(repo, "symbolic-ref", "--short", "HEAD"), "side\n")
        XCTAssertEqual(try status()["branch"] as? String, "side")
        XCTAssertEqual(Set(try status()["branches"] as? [String] ?? []), ["main", "side"])
        let switched = try write("branch", ["path": repo + "/b.txt", "switch": "main"])
        XCTAssertEqual(switched.status, 200, switched.text)
        XCTAssertEqual(switched.json["created"] as? Bool, false)
        XCTAssertEqual(try sh(repo, "symbolic-ref", "--short", "HEAD"), "main\n")
        XCTAssertEqual(try auditLines().last?["branch"] as? String, "main")
        // The working tree's changes came along: a switch never drops them.
        XCTAssertEqual(try entries()["a.txt"]?["worktree"] as? String, "M")

        for bad in ["-x", "--force", "bad..name", "a b", "has~tilde", ""] {
            let answer = try write("branch", ["path": repo + "/b.txt", "create": bad])
            XCTAssertEqual(answer.status, 400, "\(bad): \(answer.text)")
        }
        XCTAssertEqual(try write("branch", ["path": repo + "/b.txt", "switch": "-"]).status, 400)
        XCTAssertEqual(try write("branch", ["path": repo + "/b.txt"]).status, 400)
        XCTAssertEqual(try sh(repo, "symbolic-ref", "--short", "HEAD"), "main\n")
        // A switch git refuses: no such branch.
        let missing = try write("branch", ["path": repo + "/b.txt", "switch": "nowhere"])
        XCTAssertEqual(missing.status, 502, missing.text)
        XCTAssertTrue(missing.error.hasPrefix("git switch exited 128: fatal: invalid reference: nowhere"), missing.error)
    }

    func testASwitchGitRefusesOverLocalChangesIsTold() throws {
        try sh(repo, "branch", "other")
        try sh(repo, "switch", "-q", "other")
        try "other\n".write(toFile: repo + "/src/d.txt", atomically: true, encoding: .utf8)
        try sh(repo, "commit", "-q", "-am", "other d")
        try sh(repo, "switch", "-q", "main")
        try "mine\n".write(toFile: repo + "/src/d.txt", atomically: true, encoding: .utf8)
        let answer = try write("branch", ["path": repo + "/b.txt", "switch": "other"])
        XCTAssertEqual(answer.status, 502, answer.text)
        XCTAssertTrue(answer.error.contains("would be overwritten"), answer.error)
        XCTAssertEqual(try sh(repo, "symbolic-ref", "--short", "HEAD"), "main\n")
        XCTAssertEqual(try String(contentsOfFile: repo + "/src/d.txt", encoding: .utf8), "mine\n")
    }

    // MARK: - refusals

    func testAHeldIndexLockIs409AndIsNeverDeleted() throws {
        let lock = open(repo + "/.git/index.lock", O_WRONLY | O_CREAT | O_EXCL, 0o644)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer {
            close(lock)
            unlink(repo + "/.git/index.lock")
        }
        let cases: [(String, [String: Any])] = [
            ("stage", ["path": repo + "/a.txt"]),
            ("unstage", ["path": repo + "/b.txt"]),
            ("commit", ["path": repo + "/b.txt", "message": "locked"]),
            ("branch", ["path": repo + "/b.txt", "create": "locked"]),
        ]
        for (kind, fields) in cases {
            let answer = try write(kind, fields)
            XCTAssertEqual(answer.status, 409, "\(kind): \(answer.text)")
            XCTAssertEqual(answer.error, "index.lock is held")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/.git/index.lock"))
        XCTAssertEqual(try entries()["a.txt"]?["index"] as? String, ".")
        XCTAssertEqual(try auditLines().map { $0["status"] as? Int }, [409, 409, 409, 409])
    }

    func testWithoutAgentControlEveryWriteIs403AndTheStatusSaysSo() async throws {
        try await restart(policy: .loopbackOnly, agentControl: false)
        XCTAssertEqual(try status()["writes"] as? Bool, false)
        let cases: [(String, [String: Any])] = [
            ("stage", ["path": repo + "/a.txt"]), ("unstage", ["path": repo + "/b.txt"]),
            ("commit", ["path": repo + "/b.txt", "message": "m"]), ("push", ["path": repo + "/b.txt"]),
            ("branch", ["path": repo + "/b.txt", "create": "x"]),
        ]
        for (kind, fields) in cases {
            let answer = try write(kind, fields)
            XCTAssertEqual(answer.status, 403, "\(kind): \(answer.text)")
            XCTAssertEqual(answer.error, "agent control disabled; start the daemon with --agent-control")
        }
        XCTAssertEqual(try entries()["a.txt"]?["index"] as? String, ".")
        XCTAssertEqual(try auditLines().count, 5, "every attempt past the grade check is logged")
    }

    func testAWatchTokenReachesNoWriteAndAFullTokenDoes() async throws {
        try await restart(policy: .proxied(token: "ctl", watchToken: "ktw_w", trustedHosts: ["mac.example"]), agentControl: true)
        let watch = try write("stage", ["path": repo + "/a.txt"], extra: ["Cookie: kitterm_token=ktw_w"], host: "mac.example")
        XCTAssertEqual(watch.status, 403, watch.text)
        XCTAssertEqual(watch.error, "watch-only token")
        XCTAssertEqual(try auditLines().count, 0, "a watch refusal is before the audit")
        let full = try write("stage", ["path": repo + "/a.txt"], extra: ["Cookie: kitterm_token=ctl"], host: "mac.example")
        XCTAssertEqual(full.status, 200, full.text)
        XCTAssertEqual(try auditLines().last?["token"] as? String, "ephemeral")
    }

    func testTheEditorHeaderAndTheExactOriginAreRequired() throws {
        let noHeader = try write("stage", ["path": repo + "/a.txt"], dropping: ["X-Kitterm-Editor"])
        XCTAssertEqual(noHeader.status, 403, noHeader.text)
        XCTAssertTrue(noHeader.error.contains("X-Kitterm-Editor"))
        let noOrigin = try write("stage", ["path": repo + "/a.txt"], dropping: ["Origin"])
        XCTAssertEqual(noOrigin.status, 403, noOrigin.text)
        let other = try write("stage", ["path": repo + "/a.txt"], dropping: ["Origin"], extra: ["Origin: http://evil.example"])
        XCTAssertEqual(other.status, 403, other.text)
        XCTAssertTrue(other.error.contains("Origin"))
        XCTAssertEqual(try entries()["a.txt"]?["index"] as? String, ".")
    }

    func testAPathOutsideEveryRepositoryAndAMalformedBody() throws {
        try FileManager.default.createDirectory(atPath: scratch.appendingPathComponent("plain").path, withIntermediateDirectories: true)
        try "loose\n".write(toFile: scratch.appendingPathComponent("plain/loose.txt").path, atomically: true, encoding: .utf8)
        let outside = try write("stage", ["path": scratch.appendingPathComponent("plain/loose.txt").path])
        XCTAssertEqual(outside.status, 404, outside.text)
        XCTAssertEqual(outside.error, "outside every project")
        XCTAssertEqual(try write("stage", [:]).status, 400)
        let notJSON = try request("POST", "/api/git/stage", headers: ["X-Kitterm-Editor: 1", "Origin: \(ownOrigin)"], body: Data("nope".utf8))
        XCTAssertEqual(notJSON.status, 400, notJSON.text)
        // A path that climbs out, or an option, in `paths`.
        for bad in ["../x", "-rf", "/etc/passwd"] {
            let answer = try write("stage", ["path": repo + "/a.txt", "paths": [bad]])
            XCTAssertEqual(answer.status, 400, "\(bad): \(answer.text)")
        }
    }
}
