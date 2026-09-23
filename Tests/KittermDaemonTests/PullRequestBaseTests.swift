import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `pullRequestBase` on `GET /api/projects` (`agent-dashboard`, round 15):
/// `https://github.com/owner/repo/pull/` from the checkout's `origin`
/// remote in each form `git remote get-url` prints, nothing for a remote
/// off GitHub or no remote, one `git` per root every five minutes.
final class PullRequestBaseTests: XCTestCase {
    func testTheThreeRemoteFormsParseToOneBase() {
        let base = "https://github.com/tienan92it/kitterm/pull/"
        XCTAssertEqual(PullRequestBase.parse(remote: "git@github.com:tienan92it/kitterm.git"), base)
        XCTAssertEqual(PullRequestBase.parse(remote: "ssh://git@github.com/tienan92it/kitterm.git"), base)
        XCTAssertEqual(PullRequestBase.parse(remote: "https://github.com/tienan92it/kitterm.git"), base)
        XCTAssertEqual(PullRequestBase.parse(remote: "https://github.com/tienan92it/kitterm"), base)
        XCTAssertEqual(PullRequestBase.parse(remote: "https://github.com/tienan92it/kitterm/\n"), base, "a trailing slash and the newline git prints")
        XCTAssertEqual(PullRequestBase.parse(remote: "git@github.com:tienan92it/kitterm"), base)
    }

    /// A multi-account SSH setup names a `Host` alias in `~/.ssh/config`,
    /// so the remote reads `git@github.com-tienan92it:nghenhan/nghenhan-mt5.git`;
    /// the alias is the SSH host, not the web host, and the base is the
    /// same `https://github.com/` one.
    func testAnSSHConfigHostAliasParsesToTheSameBase() {
        let base = "https://github.com/nghenhan/nghenhan-mt5/pull/"
        XCTAssertEqual(PullRequestBase.parse(remote: "git@github.com-tienan92it:nghenhan/nghenhan-mt5.git\n"), base)
        XCTAssertEqual(PullRequestBase.parse(remote: "git@github.com-work:nghenhan/nghenhan-mt5.git"), base)
        XCTAssertEqual(PullRequestBase.parse(remote: "git@github.com_2:nghenhan/nghenhan-mt5"), base)
        XCTAssertEqual(PullRequestBase.parse(remote: "ssh://git@github.comX/nghenhan/nghenhan-mt5.git"), base)
        XCTAssertNil(PullRequestBase.parse(remote: "git@github.comX"), "an alias with no separator and no path")
        XCTAssertNil(PullRequestBase.parse(remote: "git@github.com-work"), "an alias with no separator and no path")
    }

    func testARemoteOffGitHubOrAMalformedOneYieldsNothing() {
        XCTAssertNil(PullRequestBase.parse(remote: "https://gitlab.com/owner/repo.git"))
        XCTAssertNil(PullRequestBase.parse(remote: "git@bitbucket.org:owner/repo.git"))
        XCTAssertNil(PullRequestBase.parse(remote: "https://example.invalid/repo.git"))
        XCTAssertNil(PullRequestBase.parse(remote: ""))
        XCTAssertNil(PullRequestBase.parse(remote: "https://github.com/owner"), "no repository")
        XCTAssertNil(PullRequestBase.parse(remote: "https://github.com/owner/repo/extra.git"), "three components")
        XCTAssertNil(PullRequestBase.parse(remote: "https://notgithub.com/owner/repo.git"), "the host is a suffix, not the host")
        XCTAssertNil(PullRequestBase.parse(remote: "https://github.com.evil.test/owner/repo.git"), "the host is a prefix, not the host")
        XCTAssertNil(PullRequestBase.parse(remote: "git@github.com.evil.example:owner/repo.git"), "a dot after the prefix is another host, not an alias")
        XCTAssertNil(PullRequestBase.parse(remote: "git@github.com-work.evil.test:owner/repo.git"), "an alias never holds a dot")
        XCTAssertNil(PullRequestBase.parse(remote: "git@gitlab.com-work:owner/repo.git"), "an alias on another host")
    }

    func testTheOriginsAreReadOncePerRootPerInterval() {
        let calls = NIOLockedValueBox<[[String]]>([])
        let origins = RemoteOrigins(git: { args in
            calls.withLockedValue { $0.append(args) }
            if args.contains("/w/kitterm") { return (0, "git@github.com:tienan92it/kitterm.git\n") }
            if args.contains("/w/gitlab") { return (0, "https://gitlab.com/o/r.git\n") }
            return (128, "")
        })
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(origins.pullRequestBase(root: "/w/kitterm", now: t0), "https://github.com/tienan92it/kitterm/pull/")
        XCTAssertNil(origins.pullRequestBase(root: "/w/gitlab", now: t0))
        XCTAssertNil(origins.pullRequestBase(root: "/w/plain", now: t0), "no checkout: git fails, no base")
        XCTAssertEqual(calls.withLockedValue { $0 }, [
            ["-C", "/w/kitterm", "remote", "get-url", "origin"],
            ["-C", "/w/gitlab", "remote", "get-url", "origin"],
            ["-C", "/w/plain", "remote", "get-url", "origin"],
        ])
        // Inside the interval every answer, a miss included, is kept.
        XCTAssertEqual(origins.pullRequestBases(roots: ["/w/kitterm", "/w/gitlab", "/w/plain", "/w/kitterm"], now: t0.addingTimeInterval(299)), ["/w/kitterm": "https://github.com/tienan92it/kitterm/pull/"])
        XCTAssertEqual(calls.withLockedValue { $0.count }, 3)
        // Past it, each root is asked again.
        _ = origins.pullRequestBase(root: "/w/kitterm", now: t0.addingTimeInterval(RemoteOrigins.ttlSeconds))
        XCTAssertEqual(calls.withLockedValue { $0.count }, 4)
    }

    func testTheProjectsRouteCarriesTheBaseForAGitHubRootAndNoFieldOtherwise() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-pr-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Made real before they are canonicalised: the store reloads its
        // roots as `realpath`s, and `/var` is `/private/var` only once the
        // directory exists.
        func root(_ name: String) throws -> String {
            let url = scratch.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return ProjectStore.canonicalRoot(url.path)
        }
        let hub = try root("hub")
        let lab = try root("lab")
        let plain = try root("plain")
        let file = scratch.appendingPathComponent("projects.json")
        try ProjectStore.save([
            Project(id: "hub", name: "hub", root: hub),
            Project(id: "lab", name: "lab", root: lab),
            Project(id: "plain", name: "plain", root: plain),
        ], to: file)
        let store = ProjectStore(url: file)
        let origins = RemoteOrigins(git: { args in
            if args.contains(hub) { return (0, "https://github.com/tienan92it/kitterm.git\n") }
            if args.contains(lab) { return (0, "https://gitlab.com/o/r.git\n") }
            return (128, "")
        })

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        func server(origins: RemoteOrigins?) throws -> Channel {
            try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(HTTPAPIHandler(
                            registry: SessionRegistry(), policy: .loopbackOnly, agentControl: false, staticRoot: nil,
                            projects: store, remoteOrigins: origins
                        ))
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        }
        func projects(_ port: Int) async throws -> [String: [String: Any]] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/projects")!)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let items = try XCTUnwrap(json["projects"] as? [[String: Any]])
            return Dictionary(uniqueKeysWithValues: items.map { ($0["id"] as! String, $0) })
        }

        let channel = try server(origins: origins)
        let byID = try await projects(channel.localAddress!.port!)
        XCTAssertEqual(byID["hub"]?["pullRequestBase"] as? String, "https://github.com/tienan92it/kitterm/pull/")
        XCTAssertNil(byID["lab"]?["pullRequestBase"], "a remote off GitHub: no field, and the page prints plain text")
        XCTAssertNil(byID["plain"]?["pullRequestBase"], "no remote: no field")
        XCTAssertEqual(Set(byID["hub"]!.keys), ["id", "name", "root", "registered", "knowledge", "pullRequestBase"])
        XCTAssertEqual(Set(byID["lab"]!.keys), ["id", "name", "root", "registered", "knowledge"])
        try channel.close().wait()

        // A handler built without the origins carries the field nowhere.
        let bare = try server(origins: nil)
        let none = try await projects(bare.localAddress!.port!)
        XCTAssertNil(none["hub"]?["pullRequestBase"])
        try bare.close().wait()
        try await group.shutdownGracefully()
    }
}
