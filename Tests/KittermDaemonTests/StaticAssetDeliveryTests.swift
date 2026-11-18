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

/// How the daemon sends the web bundle (chore `asset-delivery`): the `.br`
/// or `.gz` sibling the build wrote when `Accept-Encoding` allows it, a year
/// of `immutable` for a hashed name under `/assets/`, and `no-cache` with an
/// `ETag` and a 304 for every other file.
final class StaticAssetDeliveryTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var base: URL!
    private var webRoot: URL!

    /// The bundle. A sibling holds a marker, not a real stream: the daemon
    /// sends the bytes of the file and never encodes or decodes.
    private static let files: [String: String] = [
        "index.html": "<!doctype html><title>kitterm</title>",
        "index.html.br": "BR(index)",
        "index.html.gz": "GZ(index)",
        "sessions.html": "<!doctype html><title>kitterm — sessions</title>",
        "sw.js": "self.addEventListener('fetch', () => {});",
        "sw.js.br": "BR(sw)",
        "sw.js.gz": "GZ(sw)",
        "manifest.webmanifest": "{\"name\":\"kitterm\"}",
        "icon-192.png": "PNG",
        "icon-192.png.br": "BR(png) which the daemon must not send",
        "assets/main-BDCeJSzg.js": "console.log('main')",
        "assets/main-BDCeJSzg.js.br": "BR(main)",
        "assets/main-BDCeJSzg.js.gz": "GZ(main)",
        "assets/main-BDCeJSzg.js.map": "{\"version\":3}",
        "assets/main-BDCeJSzg.js.map.br": "BR(map) which the daemon must not send",
        "assets/only-gz-Aa0_-Zz9.css": "body{}",
        "assets/only-gz-Aa0_-Zz9.css.gz": "GZ(css)",
        "assets/plain-00000000.js": "console.log('no sibling')",
        "assets/logo.svg": "<svg/>",
        "assets/short-abc.js": "console.log('seven characters are not a hash')",
    ]

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-asset-delivery-\(UUID().uuidString)", isDirectory: true)
        webRoot = base.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(
            at: webRoot.appendingPathComponent("assets"), withIntermediateDirectories: true)
        for (name, body) in Self.files {
            try body.write(to: webRoot.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // Beside the root, not under it: what a traversal would reach.
        try "SECRET".write(to: base.appendingPathComponent("secret.js"), atomically: true, encoding: .utf8)
        try "BR(secret)".write(to: base.appendingPathComponent("secret.js.br"), atomically: true, encoding: .utf8)

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
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Accept-Encoding

    func testBrotliIsServedWhenTheRequestAcceptsBr() throws {
        let answer = try raw("/assets/main-BDCeJSzg.js", acceptEncoding: "br")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.text, "BR(main)")
        XCTAssertEqual(answer.header("Content-Encoding"), "br")
        XCTAssertEqual(answer.header("Content-Type"), "text/javascript; charset=utf-8")
        XCTAssertEqual(answer.header("Content-Length"), "\("BR(main)".utf8.count)")
        XCTAssertEqual(answer.header("Vary"), "Accept-Encoding")
    }

    func testGzipIsServedWhenTheRequestAcceptsGzipOnly() throws {
        let answer = try raw("/assets/main-BDCeJSzg.js", acceptEncoding: "gzip, deflate")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.text, "GZ(main)")
        XCTAssertEqual(answer.header("Content-Encoding"), "gzip")
        XCTAssertEqual(answer.header("Content-Type"), "text/javascript; charset=utf-8")
        XCTAssertEqual(answer.header("Vary"), "Accept-Encoding")
    }

    func testBrotliWinsWhenTheRequestAcceptsBoth() throws {
        // The order in the header does not decide, and neither does a
        // lower weight: the daemon prefers the smaller body.
        for header in ["gzip, deflate, br", "br, gzip", "gzip;q=1.0, br;q=0.5"] {
            let answer = try raw("/assets/main-BDCeJSzg.js", acceptEncoding: header)
            XCTAssertEqual(answer.text, "BR(main)", header)
            XCTAssertEqual(answer.header("Content-Encoding"), "br", header)
        }
    }

    func testTheOriginalIsServedWhenTheRequestAcceptsNeither() throws {
        for header in [nil, "", "identity", "deflate", "zstd"] {
            let answer = try raw("/assets/main-BDCeJSzg.js", acceptEncoding: header)
            XCTAssertEqual(answer.status, 200, header ?? "no header")
            XCTAssertEqual(answer.text, "console.log('main')", header ?? "no header")
            XCTAssertNil(answer.header("Content-Encoding"), header ?? "no header")
            XCTAssertEqual(answer.header("Vary"), "Accept-Encoding", header ?? "no header")
        }
    }

    func testAZeroWeightRefusesACoding() throws {
        let noBrotli = try raw("/assets/main-BDCeJSzg.js", acceptEncoding: "br;q=0, gzip")
        XCTAssertEqual(noBrotli.text, "GZ(main)")
        XCTAssertEqual(noBrotli.header("Content-Encoding"), "gzip")

        let neither = try raw("/assets/main-BDCeJSzg.js", acceptEncoding: "br; q=0, gzip;q=0.0")
        XCTAssertEqual(neither.text, "console.log('main')")
        XCTAssertNil(neither.header("Content-Encoding"))

        // `*` names each coding the header does not; `*;q=0` refuses them.
        let star = try raw("/assets/main-BDCeJSzg.js", acceptEncoding: "*")
        XCTAssertEqual(star.header("Content-Encoding"), "br")
        let starButBrotli = try raw("/assets/main-BDCeJSzg.js", acceptEncoding: "br;q=0, *")
        XCTAssertEqual(starButBrotli.header("Content-Encoding"), "gzip")
        let refused = try raw("/assets/main-BDCeJSzg.js", acceptEncoding: "gzip, *;q=0")
        XCTAssertEqual(refused.header("Content-Encoding"), "gzip")
    }

    func testAcceptedCodingsParsesTheHeader() {
        XCTAssertEqual(StaticFileServer.acceptedCodings([]), [])
        XCTAssertEqual(StaticFileServer.acceptedCodings(["gzip, deflate, br, zstd"]), [.br, .gzip])
        XCTAssertEqual(StaticFileServer.acceptedCodings(["GZIP"]), [.gzip])
        XCTAssertEqual(StaticFileServer.acceptedCodings(["gzip", "br"]), [.br, .gzip])
        XCTAssertEqual(StaticFileServer.acceptedCodings(["br;q=0"]), [])
        XCTAssertEqual(StaticFileServer.acceptedCodings(["br;q=nonsense, gzip"]), [.gzip])
        XCTAssertEqual(StaticFileServer.acceptedCodings(["*;q=0.1"]), [.br, .gzip])
    }

    // MARK: No sibling

    func testAFileWithNoSiblingIsServedAsItIs() throws {
        let answer = try raw("/assets/plain-00000000.js", acceptEncoding: "br, gzip")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.text, "console.log('no sibling')")
        XCTAssertNil(answer.header("Content-Encoding"))
        XCTAssertEqual(answer.header("Vary"), "Accept-Encoding")

        // Brotli accepted, but the build left only the gzip one.
        let onlyGzip = try raw("/assets/only-gz-Aa0_-Zz9.css", acceptEncoding: "br, gzip")
        XCTAssertEqual(onlyGzip.text, "GZ(css)")
        XCTAssertEqual(onlyGzip.header("Content-Encoding"), "gzip")
        XCTAssertEqual(onlyGzip.header("Content-Type"), "text/css; charset=utf-8")
    }

    func testAFileThatIsNotTextIsNeverEncoded() throws {
        // A sibling exists for each, and the daemon does not look at it.
        for path in ["/icon-192.png", "/assets/main-BDCeJSzg.js.map"] {
            let answer = try raw(path, acceptEncoding: "br, gzip")
            XCTAssertEqual(answer.status, 200, path)
            XCTAssertEqual(answer.text, Self.files[String(path.dropFirst())], path)
            XCTAssertNil(answer.header("Content-Encoding"), path)
            XCTAssertNil(answer.header("Vary"), path)
        }
    }

    func testVaryIsOnEveryCompressibleAnswer() throws {
        let paths = [
            "/", "/index.html", "/sessions", "/sw.js", "/manifest.webmanifest",
            "/assets/main-BDCeJSzg.js", "/assets/only-gz-Aa0_-Zz9.css", "/assets/plain-00000000.js",
            "/assets/logo.svg",
        ]
        for path in paths {
            for header in [nil, "br", "gzip", "identity"] {
                let answer = try raw(path, acceptEncoding: header)
                XCTAssertEqual(answer.status, 200, "\(path) \(header ?? "none")")
                XCTAssertEqual(answer.header("Vary"), "Accept-Encoding", "\(path) \(header ?? "none")")
            }
        }
    }

    // MARK: A sibling has no address

    func testASiblingPathIsNotServed() throws {
        for path in [
            "/assets/main-BDCeJSzg.js.br", "/assets/main-BDCeJSzg.js.gz", "/index.html.br", "/sw.js.gz",
            "/assets/main-BDCeJSzg.js.BR", "/index.html.br?x=1",
        ] {
            XCTAssertEqual(try raw(path, acceptEncoding: "br, gzip").status, 404, path)
            XCTAssertEqual(try raw(path).status, 404, path)
        }
    }

    // MARK: Path traversal

    func testPathTraversalIsStillRefused() throws {
        for path in [
            "/../secret.js", "/assets/../../secret.js", "/assets/../../secret.js.br",
            "/..%2fsecret.js", "/%2e%2e/secret.js", "//../secret.js",
        ] {
            for header in [nil, "br, gzip"] {
                let answer = try raw(path, acceptEncoding: header)
                XCTAssertEqual(answer.status, 404, "\(path) \(header ?? "none")")
                XCTAssertFalse(answer.text.contains("SECRET"), path)
                XCTAssertFalse(answer.text.contains("BR(secret)"), path)
            }
        }
        XCTAssertNil(StaticFileServer.file(for: "/../secret.js", root: webRoot))
        XCTAssertNil(StaticFileServer.file(for: "/assets/../../secret.js", root: webRoot))
    }

    // MARK: Cache-Control

    func testImmutableIsOnlyOnAHashedAssetName() throws {
        let immutable = "public, max-age=31536000, immutable"
        for path in [
            "/assets/main-BDCeJSzg.js", "/assets/main-BDCeJSzg.js.map", "/assets/only-gz-Aa0_-Zz9.css",
            "/assets/plain-00000000.js",
        ] {
            for header in [nil, "br"] {
                let answer = try raw(path, acceptEncoding: header)
                XCTAssertEqual(answer.header("Cache-Control"), immutable, path)
                XCTAssertNil(answer.header("ETag"), path)
            }
        }
        for path in [
            "/", "/index.html", "/sessions", "/sw.js", "/manifest.webmanifest", "/icon-192.png",
            "/assets/logo.svg", "/assets/short-abc.js",
        ] {
            let answer = try raw(path, acceptEncoding: "br")
            XCTAssertEqual(answer.status, 200, path)
            XCTAssertEqual(answer.header("Cache-Control"), "no-cache", path)
            XCTAssertNotNil(answer.header("ETag"), path)
        }
    }

    func testIsHashedAssetReadsTheName() {
        func hashed(_ relative: String) -> Bool {
            StaticFileServer.isHashedAsset(webRoot.appendingPathComponent(relative), root: webRoot)
        }
        XCTAssertTrue(hashed("assets/main-BDCeJSzg.js"))
        XCTAssertTrue(hashed("assets/main-BDCeJSzg.js.map"))
        XCTAssertTrue(hashed("assets/theme-tokens-DAUW_wc5.js"))
        XCTAssertTrue(hashed("assets/query-WkU28aGW.css"))
        XCTAssertTrue(hashed("assets/index-Baz3op4-.js"))
        // Not under /assets/: a root file keeps its name over builds.
        XCTAssertFalse(hashed("main-BDCeJSzg.js"))
        XCTAssertFalse(hashed("other/main-BDCeJSzg.js"))
        XCTAssertFalse(hashed("assets/logo.svg"))
        XCTAssertFalse(hashed("assets/short-abc.js"))
        XCTAssertFalse(hashed("assets/BDCeJSzg.js"))
        XCTAssertFalse(hashed("assets/-BDCeJSzg.js"))
        XCTAssertFalse(hashed("assets/main-BDCe!Szg.js"))
        XCTAssertFalse(hashed("assets/main.BDCeJSzg.js"))
    }

    // MARK: ETag and 304

    func testThePageHasAnETagAndAnswers304() throws {
        for path in ["/", "/index.html", "/sessions", "/sw.js", "/manifest.webmanifest", "/icon-192.png"] {
            let first = try raw(path)
            XCTAssertEqual(first.status, 200, path)
            let etag = try XCTUnwrap(first.header("ETag"), path)
            XCTAssertTrue(etag.hasPrefix("\"") && etag.hasSuffix("\""), "\(path): \(etag)")

            let again = try raw(path, extra: ["If-None-Match: \(etag)"])
            XCTAssertEqual(again.status, 304, path)
            XCTAssertTrue(again.body.isEmpty, path)
            XCTAssertEqual(again.header("ETag"), etag, path)
            XCTAssertEqual(again.header("Cache-Control"), "no-cache", path)
            XCTAssertNil(again.header("Content-Encoding"), path)

            // A proxy makes the tag weak; the list form names more than one.
            XCTAssertEqual(try raw(path, extra: ["If-None-Match: \"other\", W/\(etag)"]).status, 304, path)
            XCTAssertEqual(try raw(path, extra: ["If-None-Match: \"other\""]).status, 200, path)
        }
    }

    func testEachCodingHasItsOwnETag() throws {
        let identity = try XCTUnwrap(try raw("/").header("ETag"))
        let brotli = try XCTUnwrap(try raw("/", acceptEncoding: "br").header("ETag"))
        let gzip = try XCTUnwrap(try raw("/", acceptEncoding: "gzip").header("ETag"))
        XCTAssertEqual(Set([identity, brotli, gzip]).count, 3)

        // The tag of one coding does not answer for another.
        let same = try raw("/", acceptEncoding: "br", extra: ["If-None-Match: \(brotli)"])
        XCTAssertEqual(same.status, 304)
        XCTAssertEqual(same.header("Vary"), "Accept-Encoding")
        let other = try raw("/", acceptEncoding: "gzip", extra: ["If-None-Match: \(brotli)"])
        XCTAssertEqual(other.status, 200)
        XCTAssertEqual(other.text, "GZ(index)")
    }

    func testTheETagChangesWithTheContent() throws {
        let before = try XCTUnwrap(try raw("/sessions").header("ETag"))
        try "<!doctype html><title>a new build</title>"
            .write(to: webRoot.appendingPathComponent("sessions.html"), atomically: true, encoding: .utf8)
        let after = try raw("/sessions", extra: ["If-None-Match: \(before)"])
        XCTAssertEqual(after.status, 200)
        XCTAssertNotEqual(after.header("ETag"), before)
        XCTAssertEqual(after.text, "<!doctype html><title>a new build</title>")
    }

    // MARK: Raw client

    private struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// One HTTP/1.1 request over a raw socket: the path reaches the daemon
    /// byte for byte (a URL client folds `..` away), `Accept-Encoding` is
    /// what the test says (URLSession sets its own), and the body arrives
    /// as sent (URLSession decodes it).
    private func raw(_ target: String, acceptEncoding: String? = nil, extra: [String] = []) throws -> Answer {
        let fd = socket(AF_INET, streamSocketType, 0)
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
        var lines = ["GET \(target) HTTP/1.1", "Host: 127.0.0.1:\(port!)", "Connection: close"]
        if let acceptEncoding { lines.append("Accept-Encoding: \(acceptEncoding)") }
        lines += extra
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
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Answer(status: status, headers: headers, body: Data(received[split.upperBound...]))
    }
}
