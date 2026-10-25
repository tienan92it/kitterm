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

/// The porcelain v2 parser on fixed bytes (`GitStatus.parse`), and the
/// numstat and `--numstat -p` parsers beside it (`code-editor` round 5).
final class GitStatusParserTests: XCTestCase {
    private func bytes(_ records: [String]) -> Data {
        Data(records.joined(separator: "\0").utf8) + Data([0])
    }

    func testEveryRecordKindAndTheBranchHeaders() {
        let data = bytes([
            "# branch.oid 2fb40556da0d91b024e45c1f4b835f2f82980ac3",
            "# branch.head goal/code-editor",
            "# branch.upstream origin/goal/code-editor",
            "# branch.ab +3 -1",
            "1 .M N... 100644 100644 100644 4cb29ea38f70d7c61b2a3a25b02e3bdf44905402 4cb29ea38f70d7c61b2a3a25b02e3bdf44905402 a b.txt",
            "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 3e75765e2f1b3b9b6f2c5b1a0e6a4c3b2a1f0e9d src/osc52.ts",
            "1 D. N... 100644 000000 000000 4cb29ea38f70d7c61b2a3a25b02e3bdf44905402 0000000000000000000000000000000000000000 gone.txt",
            "2 R. N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba559614 587be6b4c3f93f93c489c0111bba559614 R100 new.txt",
            "old.txt",
            "2 C. N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba559614 587be6b4c3f93f93c489c0111bba559614 C90 copy.txt",
            "source.txt",
            "u UU N... 100644 100644 100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 3333333333333333333333333333333333333333 conflict.txt",
            "? nl\nin.txt",
            "? untracked.txt",
            "! build/",
            "x a record of a later version",
        ])
        let report = GitStatus.parse(data)
        XCTAssertEqual(report.branch, "goal/code-editor")
        XCTAssertEqual(report.oid, "2fb40556da0d91b024e45c1f4b835f2f82980ac3")
        XCTAssertEqual(report.upstream, "origin/goal/code-editor")
        XCTAssertEqual(report.ahead, 3)
        XCTAssertEqual(report.behind, 1)
        XCTAssertFalse(report.detached)
        // Chartered (`code-editor` round 13, `corpus/09-approved-frames.md`
        // rule 19): an ignored path is no longer a `.files` entry of kind
        // `.ignored` — it is `report.ignored`, outside `files` and `counts`,
        // so the tree can dim a path the daemon never treats as a change.
        // Old: `report.files.map(\.path)` ended `…, "untracked.txt", "build/"`
        // and `.kind` `…, .untracked, .ignored`, with `"!!"` in the XY list.
        XCTAssertEqual(report.files.map(\.path), [
            "a b.txt", "src/osc52.ts", "gone.txt", "new.txt", "copy.txt", "conflict.txt", "nl\nin.txt", "untracked.txt",
        ])
        XCTAssertEqual(report.files.map(\.kind), [
            .ordinary, .ordinary, .ordinary, .renamed, .copied, .unmerged, .untracked, .untracked,
        ])
        XCTAssertEqual(report.files.map { String($0.index) + String($0.worktree) }, [
            ".M", "A.", "D.", "R.", "C.", "UU", "??", "??",
        ])
        XCTAssertEqual(report.files[3].origPath, "old.txt")
        XCTAssertEqual(report.files[4].origPath, "source.txt")
        XCTAssertNil(report.files[0].origPath)
        XCTAssertEqual(report.ignored, ["build/"])
        XCTAssertFalse(report.ignoredTruncated)
        let counts = report.counts
        XCTAssertEqual(counts.changed, 8, "the ignored entry is never a files entry")
        XCTAssertEqual(counts.staged, 4, "A, D, R and C")
        XCTAssertEqual(counts.unstaged, 1)
        XCTAssertEqual(counts.untracked, 2)
        XCTAssertEqual(counts.conflicts, 1)
    }

    func testADetachedHeadAnUnbornBranchAndMalformedRecords() {
        let detached = GitStatus.parse(bytes(["# branch.oid abc", "# branch.head (detached)"]))
        XCTAssertTrue(detached.detached)
        XCTAssertNil(detached.branch)
        XCTAssertNil(detached.upstream)
        XCTAssertEqual(detached.ahead, 0)
        let unborn = GitStatus.parse(bytes(["# branch.oid (initial)", "# branch.head main", "1 A. N... 000000 100644 100644 0 1 a.txt"]))
        XCTAssertNil(unborn.oid)
        XCTAssertEqual(unborn.branch, "main")
        XCTAssertEqual(unborn.files.count, 1)
        // Too few fields, a bad XY, a rename with no second field: no entry,
        // no crash.
        let broken = GitStatus.parse(bytes(["1 .M N...", "1 MMM N... 1 2 3 4 5 x", "2 R. N... 1 2 3 4 5 R100 only.txt"]))
        XCTAssertEqual(broken.files, [])
        XCTAssertEqual(GitStatus.parse(Data()).files, [])
    }

    func testNumstatWithARenameAndABinary() {
        let data = Data("2\t1\ta b.txt\u{0}0\t0\t\u{0}old.txt\u{0}new.txt\u{0}-\t-\tlogo.png\u{0}".utf8)
        let lines = GitStatus.parseNumstat(data)
        XCTAssertEqual(lines, [
            GitStatus.NumstatLine(path: "a b.txt", origPath: nil, additions: 2, deletions: 1),
            GitStatus.NumstatLine(path: "new.txt", origPath: "old.txt", additions: 0, deletions: 0),
            GitStatus.NumstatLine(path: "logo.png", origPath: nil, additions: nil, deletions: nil),
        ])
    }

    func testTheDiffOutputSplitsIntoCountsAndPatchAndIsCutAtTheCap() {
        let patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-one\n+two\n"
        let diff = GitRead.parseDiff(Data(("1\t1\ta.txt\n\n" + patch).utf8), untracked: false)
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.text, patch)
        XCTAssertFalse(diff.binary)
        XCTAssertFalse(diff.truncated)
        let binary = GitRead.parseDiff(Data("-\t-\tlogo.png\n\nBinary files a/logo.png and b/logo.png differ\n".utf8), untracked: false)
        XCTAssertTrue(binary.binary)
        XCTAssertNil(binary.additions)
        XCTAssertEqual(GitRead.parseDiff(Data(), untracked: true).text, "")

        let line = String(repeating: "+", count: 99) + "\n"
        let long = "9000\t0\tbig.txt\n\n" + String(repeating: line, count: (GitRead.diffMaxBytes / 100) + 50)
        let cut = GitRead.parseDiff(Data(long.utf8), untracked: false)
        XCTAssertTrue(cut.truncated)
        XCTAssertLessThanOrEqual(cut.text.utf8.count, GitRead.diffMaxBytes)
        XCTAssertTrue(cut.text.hasSuffix("\n"), "cut on a line boundary")
        XCTAssertEqual(cut.additions, 9000)
    }

    func testEveryCommandCarriesTheReadOptionsBeforeItsSubcommand() throws {
        let seen = NIOLockedValueBox<[[String]]>([])
        let reader = GitRead(run: { args in
            seen.withLockedValue { $0.append(args) }
            if args.contains("rev-parse") { return .init(status: 0, output: Data("/w/repo\n".utf8)) }
            return .init(status: 0, output: Data())
        })
        _ = reader.toplevel(of: "/w/repo/src")
        let repository = GitRead.Repository(toplevel: "/w/repo", relative: "src/a.ts")
        _ = try reader.status(of: repository)
        _ = try reader.diff(of: repository, staged: false)
        _ = try reader.diff(of: repository, staged: true)
        let calls = seen.withLockedValue { $0 }
        XCTAssertGreaterThanOrEqual(calls.count, 5)
        for args in calls {
            XCTAssertEqual(Array(args.prefix(2)), ["-C", args[1]], args.joined(separator: " "))
            XCTAssertEqual(Array(args.dropFirst(2).prefix(GitRead.readOptions.count)), GitRead.readOptions, args.joined(separator: " "))
        }
        // The path is a pathspec after `--`, never an option.
        for args in calls where args.contains("diff") || args.contains("ls-files") {
            XCTAssertEqual(args.last, "src/a.ts")
            XCTAssertEqual(args[args.count - 2], "--", args.joined(separator: " "))
        }
        XCTAssertTrue(calls.contains { $0.contains("--cached") })
        // The second toplevel ask within the minute runs no git.
        let before = calls.count
        _ = reader.toplevel(of: "/w/repo/src")
        XCTAssertEqual(seen.withLockedValue { $0.count }, before)
    }
}

/// The two routes against a scratch repository with a bare remote
/// (`goal.md` conditions 10 and 12): a modified, a staged, an untracked and
/// a deleted file; ahead and behind; a path outside every repository; a
/// watch token; and the `index.lock` pair.
final class GitReadRouteTests: XCTestCase {
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
            .appendingPathComponent("kitterm-git-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        stateDir = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.appendingPathComponent("state").path), isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)
        let repoAlias = scratch.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: repoAlias + "/src", withIntermediateDirectories: true)
        // Git names the toplevel by its real path, so the answers are compared to it.
        repo = try XCTUnwrap(FileEdit.realPath(repoAlias))
        try FileManager.default.createDirectory(atPath: scratch.appendingPathComponent("plain").path, withIntermediateDirectories: true)
        try "loose\n".write(toFile: scratch.appendingPathComponent("plain/loose.txt").path, atomically: true, encoding: .utf8)
        try seed()
        try start(policy: .loopbackOnly)
    }

    override func tearDown() async throws {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        group = nil
        unsetenv("KITTERM_STATE_DIR")
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

    /// `a.txt` modified in the tree, `b.txt` staged, `c.txt` deleted,
    /// `new.txt` untracked, `src/d.txt` clean; one commit ahead of the
    /// bare remote and one behind it.
    private func seed() throws {
        let bare = scratch.appendingPathComponent("remote.git").path
        try sh(scratch.path, "init", "-q", "--bare", "-b", "main", bare)
        try sh(repo, "init", "-q", "-b", "main")
        for (name, text) in [("a.txt", "one\ntwo\nthree\n"), ("b.txt", "b\n"), ("c.txt", "c\n"), ("src/d.txt", "d\n")] {
            try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8)
        }
        try sh(repo, "add", "-A")
        try sh(repo, "commit", "-q", "-m", "init")
        try sh(repo, "remote", "add", "origin", bare)
        try sh(repo, "push", "-q", "-u", "origin", "main")
        // Behind: a second clone pushes a commit.
        let other = scratch.appendingPathComponent("other").path
        try sh(scratch.path, "clone", "-q", bare, other)
        try "e\n".write(toFile: other + "/e.txt", atomically: true, encoding: .utf8)
        try sh(other, "add", "e.txt")
        try sh(other, "commit", "-q", "-m", "e")
        try sh(other, "push", "-q", "origin", "main")
        try sh(repo, "fetch", "-q", "origin")
        // Ahead: a local commit.
        try "d2\n".write(toFile: repo + "/src/d.txt", atomically: true, encoding: .utf8)
        try sh(repo, "commit", "-q", "-am", "d2")
        // The working state.
        try "one\nTWO\nthree\nfour\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "B\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
        try sh(repo, "add", "b.txt")
        try FileManager.default.removeItem(atPath: repo + "/c.txt")
        try "new\nfile\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - the server

    private func start(policy: AccessPolicy, gitRead: GitRead = GitRead()) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let registry = SessionRegistry()
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPAPIHandler(registry: registry, policy: policy, gitRead: gitRead))
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

    private func status(_ path: String, headers: [String] = [], host: String? = nil) throws -> Answer {
        try request("/api/git/status?path=\(encoded(path))", host: host, headers: headers)
    }

    private func diff(_ path: String, staged: Bool = false, headers: [String] = [], host: String? = nil) throws -> Answer {
        try request("/api/git/diff?path=\(encoded(path))&staged=\(staged ? 1 : 0)", host: host, headers: headers)
    }

    private func files(_ answer: Answer) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for item in answer.json["files"] as? [[String: Any]] ?? [] {
            if let path = item["path"] as? String { out[path] = item }
        }
        return out
    }

    // MARK: - status

    func testStatusNamesTheBranchTheFilesAndTheCounts() throws {
        let answer = try status(repo + "/src/d.txt")
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(answer.json["ok"] as? Bool, true)
        XCTAssertEqual(answer.json["root"] as? String, repo)
        XCTAssertEqual(answer.json["branch"] as? String, "main")
        XCTAssertEqual(answer.json["upstream"] as? String, "origin/main")
        XCTAssertEqual(answer.json["ahead"] as? Int, 1)
        XCTAssertEqual(answer.json["behind"] as? Int, 1)
        XCTAssertEqual(answer.json["detached"] as? Bool, false)
        let entries = files(answer)
        XCTAssertEqual(Set(entries.keys), ["a.txt", "b.txt", "c.txt", "new.txt"], answer.text)
        XCTAssertEqual(entries["a.txt"]?["index"] as? String, ".")
        XCTAssertEqual(entries["a.txt"]?["worktree"] as? String, "M")
        XCTAssertEqual(entries["a.txt"]?["kind"] as? String, "ordinary")
        XCTAssertEqual(entries["a.txt"]?["additions"] as? Int, 2)
        XCTAssertEqual(entries["a.txt"]?["deletions"] as? Int, 1)
        XCTAssertEqual(entries["b.txt"]?["index"] as? String, "M")
        XCTAssertEqual(entries["b.txt"]?["worktree"] as? String, ".")
        XCTAssertEqual(entries["b.txt"]?["additions"] as? Int, 1)
        XCTAssertEqual(entries["c.txt"]?["worktree"] as? String, "D")
        XCTAssertEqual(entries["c.txt"]?["deletions"] as? Int, 1)
        XCTAssertEqual(entries["new.txt"]?["kind"] as? String, "untracked")
        XCTAssertEqual(entries["new.txt"]?["index"] as? String, "?")
        XCTAssertEqual(entries["new.txt"]?["additions"] as? Int, 2, "an untracked file's lines are all added")
        XCTAssertEqual(entries["new.txt"]?["deletions"] as? Int, 0)
        let counts = try XCTUnwrap(answer.json["counts"] as? [String: Int], answer.text)
        XCTAssertEqual(counts, ["changed": 4, "staged": 1, "unstaged": 2, "untracked": 1, "conflicts": 0])
        XCTAssertEqual(answer.headers["cache-control"], "no-cache")
        XCTAssertEqual(answer.headers["content-type"], "application/json")
    }

    func testStatusAnswers304ToItsOwnTagAndMovesWithTheTree() throws {
        let first = try status(repo + "/a.txt")
        let tag = try XCTUnwrap(first.headers["etag"])
        let same = try status(repo + "/a.txt", headers: ["If-None-Match: \(tag)"])
        XCTAssertEqual(same.status, 304, same.text)
        XCTAssertEqual(same.body.count, 0)
        try "more\n".write(toFile: repo + "/more.txt", atomically: true, encoding: .utf8)
        let moved = try status(repo + "/a.txt", headers: ["If-None-Match: \(tag)"])
        XCTAssertEqual(moved.status, 200)
        XCTAssertNotNil(files(moved)["more.txt"])
    }

    func testStatusOfADetachedHeadAndAnUnbornBranch() throws {
        try sh(repo, "checkout", "-q", "--detach")
        let detached = try status(repo + "/a.txt")
        XCTAssertEqual(detached.status, 200, detached.text)
        XCTAssertEqual(detached.json["detached"] as? Bool, true)
        XCTAssertNil(detached.json["branch"])
        XCTAssertNil(detached.json["upstream"])

        let fresh = scratch.appendingPathComponent("fresh").path
        try sh(scratch.path, "init", "-q", "-b", "main", fresh)
        try "x\ny\n".write(toFile: fresh + "/x.txt", atomically: true, encoding: .utf8)
        try sh(fresh, "add", "x.txt")
        let unborn = try status(fresh + "/x.txt")
        XCTAssertEqual(unborn.status, 200, unborn.text)
        XCTAssertEqual(unborn.json["branch"] as? String, "main")
        XCTAssertNil(unborn.json["oid"])
        XCTAssertEqual(files(unborn)["x.txt"]?["index"] as? String, "A")
        XCTAssertEqual(files(unborn)["x.txt"]?["additions"] as? Int, 2, "no HEAD to diff against: the file's lines")
    }

    func testAFileInAWorktreeReadsTheWorktreesOwnStatus() throws {
        // Where this repository keeps them: under the main checkout, whose
        // project the worktree's files belong to (`ProjectStore` follows the
        // `gitdir:` file to the main checkout).
        let worktree = repo + "/.claude/worktrees/wt"
        try FileManager.default.createDirectory(atPath: repo + "/.claude/worktrees", withIntermediateDirectories: true)
        try sh(repo, "worktree", "add", "-q", "-b", "side", worktree)
        try "side\n".write(toFile: worktree + "/side.txt", atomically: true, encoding: .utf8)
        let answer = try status(worktree + "/a.txt")
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(answer.json["root"] as? String, worktree)
        XCTAssertEqual(answer.json["branch"] as? String, "side")
        XCTAssertEqual(Set(files(answer).keys), ["side.txt"], "the main checkout's changes are not the worktree's")
    }

    // MARK: - diff

    func testDiffOfAModifiedAStagedAnUntrackedAndADeletedFile() throws {
        let modified = try diff(repo + "/a.txt")
        XCTAssertEqual(modified.status, 200, modified.text)
        XCTAssertEqual(modified.json["path"] as? String, "a.txt")
        XCTAssertEqual(modified.json["root"] as? String, repo)
        XCTAssertEqual(modified.json["staged"] as? Bool, false)
        XCTAssertEqual(modified.json["untracked"] as? Bool, false)
        XCTAssertEqual(modified.json["additions"] as? Int, 2)
        XCTAssertEqual(modified.json["deletions"] as? Int, 1)
        XCTAssertEqual(modified.json["truncated"] as? Bool, false)
        let text = try XCTUnwrap(modified.json["diff"] as? String)
        XCTAssertTrue(text.hasPrefix("diff --git a/a.txt b/a.txt\n"), text)
        XCTAssertTrue(text.contains("\n-two\n+TWO\n three\n+four\n"), text)

        // The staged file has no working-tree diff and an index diff.
        let unstaged = try diff(repo + "/b.txt")
        XCTAssertEqual(unstaged.status, 200)
        XCTAssertEqual(unstaged.json["diff"] as? String, "")
        XCTAssertEqual(unstaged.json["untracked"] as? Bool, false)
        let staged = try diff(repo + "/b.txt", staged: true)
        XCTAssertEqual(staged.status, 200, staged.text)
        XCTAssertEqual(staged.json["staged"] as? Bool, true)
        XCTAssertEqual(staged.json["additions"] as? Int, 1)
        XCTAssertTrue((staged.json["diff"] as? String ?? "").contains("\n-b\n+B\n"), staged.text)

        let untracked = try diff(repo + "/new.txt")
        XCTAssertEqual(untracked.status, 200, untracked.text)
        XCTAssertEqual(untracked.json["untracked"] as? Bool, true)
        XCTAssertEqual(untracked.json["additions"] as? Int, 2)
        XCTAssertEqual(untracked.json["deletions"] as? Int, 0)
        XCTAssertTrue((untracked.json["diff"] as? String ?? "").contains("@@ -0,0 +1,2 @@\n+new\n+file\n"), untracked.text)

        let deleted = try diff(repo + "/c.txt")
        XCTAssertEqual(deleted.status, 200, deleted.text)
        XCTAssertEqual(deleted.json["deletions"] as? Int, 1)
        XCTAssertTrue((deleted.json["diff"] as? String ?? "").contains("\n-c\n"), deleted.text)

        // A clean file, and a file that is nowhere: an empty diff, not an error.
        XCTAssertEqual(try diff(repo + "/src/d.txt").json["diff"] as? String, "")
        XCTAssertEqual(try diff(repo + "/src/nowhere.txt").status, 200)
    }

    func testAPathWithASpaceAndANonASCIIName() throws {
        try "é\n".write(toFile: repo + "/src/ca fé.txt", atomically: true, encoding: .utf8)
        let answer = try status(repo + "/a.txt")
        XCTAssertNotNil(files(answer)["src/ca fé.txt"], answer.text)
        let shown = try diff(repo + "/src/ca fé.txt")
        XCTAssertEqual(shown.status, 200, shown.text)
        XCTAssertEqual(shown.json["untracked"] as? Bool, true)
        XCTAssertTrue((shown.json["diff"] as? String ?? "").contains("+é\n"), shown.text)
    }

    // MARK: - refusals

    func testAPathInNoRepositoryIs404() throws {
        let loose = try status(scratch.appendingPathComponent("plain/loose.txt").path)
        XCTAssertEqual(loose.status, 404, loose.text)
        XCTAssertEqual(loose.error, "outside every project")
        XCTAssertEqual(try diff(scratch.appendingPathComponent("plain/loose.txt").path).status, 404)
        // A registered project that is no checkout: a project, no repository.
        let plain = scratch.appendingPathComponent("plain").path
        try ProjectStore.save([Project(id: "plain-git-read", name: "plain", root: ProjectStore.canonicalRoot(plain))])
        defer { try? FileManager.default.removeItem(at: DaemonPaths.projectsFile) }
        let registered = try status(plain + "/loose.txt")
        XCTAssertEqual(registered.status, 404, registered.text)
        XCTAssertEqual(registered.error, "no repository")
        XCTAssertEqual(try status("").status, 400)
        XCTAssertEqual(try status(repo + "/nowhere/a.txt").status, 404)
    }

    func testBothRoutesAreFullGradeOnly() async throws {
        try await restart(policy: .proxied(token: "ctl", watchToken: "ktw_w", trustedHosts: ["mac.example"]))
        let watch = try status(repo + "/a.txt", headers: ["Cookie: kitterm_token=ktw_w"], host: "mac.example")
        XCTAssertEqual(watch.status, 403, watch.text)
        XCTAssertEqual(watch.error, "watch-only token")
        let watchDiff = try diff(repo + "/a.txt", headers: ["Cookie: kitterm_token=ktw_w"], host: "mac.example")
        XCTAssertEqual(watchDiff.status, 403, watchDiff.text)
        let full = try status(repo + "/a.txt", headers: ["Cookie: kitterm_token=ctl"], host: "mac.example")
        XCTAssertEqual(full.status, 200, full.text)
    }

    // MARK: - index.lock

    func testAHeldIndexLockDoesNotStopAStatusRead() throws {
        let lock = open(repo + "/.git/index.lock", O_WRONLY | O_CREAT | O_EXCL, 0o644)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer {
            close(lock)
            unlink(repo + "/.git/index.lock")
        }
        let answer = try status(repo + "/a.txt")
        XCTAssertEqual(answer.status, 200, answer.text)
        XCTAssertEqual(files(answer)["a.txt"]?["worktree"] as? String, "M")
        XCTAssertEqual(try diff(repo + "/a.txt").status, 200)
    }

    func testAStatusRunLeavesNoIndexLockBehind() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/index.lock"))
        for _ in 0..<3 {
            XCTAssertEqual(try status(repo + "/a.txt").status, 200)
            XCTAssertEqual(try diff(repo + "/a.txt").status, 200)
            XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/index.lock"))
        }
        // The index itself was not rewritten by the reads: `--no-optional-locks`
        // skips the refresh that would take the lock.
        let before = try FileManager.default.attributesOfItem(atPath: repo + "/.git/index")[.modificationDate] as? Date
        XCTAssertEqual(try status(repo + "/a.txt").status, 200)
        let after = try FileManager.default.attributesOfItem(atPath: repo + "/.git/index")[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }
}
