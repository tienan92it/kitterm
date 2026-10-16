import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// The extensionless pages: `GET /sessions` serves `sessions.html` and
/// `GET /md` serves `md.html` from the static root, both as HTML the browser
/// must not cache, so a `?path=` or `?project=` query reaches a page and not
/// a 404 (`markdown-preview` round 3).
final class StaticPageRouteTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var webRoot: URL!

    private static let pages: [String: String] = [
        "index.html": "<!doctype html><title>kitterm</title>",
        "sessions.html": "<!doctype html><title>kitterm — sessions</title>",
        "md.html": "<!doctype html><title>kitterm — markdown</title><main id=\"md\"></main>",
    ]

    override func setUpWithError() throws {
        webRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-static-pages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
        for (name, body) in Self.pages {
            try body.write(to: webRoot.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let registry = SessionRegistry()
        let root = webRoot!
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(registry: registry, policy: .loopbackOnly, agentControl: false, staticRoot: root)
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        try? channel.close().wait()
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(at: webRoot)
    }

    private func get(_ path: String) async throws -> (Int, HTTPURLResponse, String) {
        let url = URL(string: "http://127.0.0.1:\(port!)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, http, String(decoding: data, as: UTF8.self))
    }

    func testMdServesTheMarkdownPageLikeSessions() async throws {
        for (path, file) in [("/md", "md.html"), ("/sessions", "sessions.html")] {
            let (status, response, body) = try await get(path)
            XCTAssertEqual(status, 200, path)
            XCTAssertEqual(body, Self.pages[file], path)
            XCTAssertTrue(
                (response.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("text/html"),
                "\(path): \(response.value(forHTTPHeaderField: "Content-Type") ?? "no content type")"
            )
            XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-cache", path)
        }
    }

    func testMdKeepsItsQueryAndIsNotAnAPIRoute() async throws {
        // The query names the file to the page; the daemon ignores it here.
        let (status, _, body) = try await get("/md?project=kitterm&path=markdown-preview/goal.md")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, Self.pages["md.html"])
        // `/md.html` is the file itself, as `/sessions.html` is; `/mdx` is nothing.
        let (direct, _, directBody) = try await get("/md.html")
        XCTAssertEqual(direct, 200)
        XCTAssertEqual(directBody, Self.pages["md.html"])
        let (missing, _, _) = try await get("/mdx")
        XCTAssertEqual(missing, 404)
    }
}
