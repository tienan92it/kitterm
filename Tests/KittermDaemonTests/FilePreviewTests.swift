import Foundation
import XCTest

@testable import KittermDaemon

/// What the preview route hands a browser.
///
/// The point of these is not that the right bytes come back — it is that the
/// *type* is never the file's own. kitterm serves this from its own origin, so
/// a file returned as `text/html` or `image/svg+xml` would run its script with
/// the auth cookie, and the file need not be one the user trusts.
final class FilePreviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeBytes(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - The types that must never be honoured

    func testHTMLIsServedAsPlainText() throws {
        let url = try write("evil.html", "<script>fetch('/api/sessions')</script>")
        let payload = try FilePreview.read(url)
        XCTAssertEqual(payload.contentType, "text/plain; charset=utf-8")
        XCTAssertNotEqual(payload.contentType, "text/html; charset=utf-8")
        XCTAssertFalse(payload.attachment)
    }

    /// An image to a person, a scriptable document to a browser. This route
    /// cannot tell a trusted one from a hostile one, so neither is drawn.
    func testSVGIsServedAsPlainText() throws {
        let url = try write("logo.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"><script/></svg>")
        XCTAssertEqual(try FilePreview.read(url).contentType, "text/plain; charset=utf-8")
    }

    func testJSONIsText() throws {
        let url = try write("report.json", "{\"ok\":true}")
        let payload = try FilePreview.read(url)
        XCTAssertEqual(payload.kind, "text")
        XCTAssertEqual(payload.contentType, "text/plain; charset=utf-8")
    }

    // MARK: - The types that are safe as themselves

    func testImagesKeepTheirType() throws {
        // A one-pixel PNG's signature is enough; nothing here parses it.
        let png = try writeBytes("a.png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let payload = try FilePreview.read(png)
        XCTAssertEqual(payload.contentType, "image/png")
        XCTAssertEqual(payload.kind, "image")
        XCTAssertFalse(payload.attachment)
    }

    func testPDFKeepsItsType() throws {
        let pdf = try writeBytes("a.pdf", Array("%PDF-1.4".utf8))
        XCTAssertEqual(try FilePreview.read(pdf).contentType, "application/pdf")
    }

    // MARK: - Everything else

    func testUnknownBinaryIsOfferedAsADownload() throws {
        let bin = try writeBytes("a.bin", [0x00, 0x01, 0x02, 0xFF, 0x00])
        let payload = try FilePreview.read(bin)
        XCTAssertEqual(payload.contentType, "application/octet-stream")
        XCTAssertEqual(payload.kind, "binary")
        XCTAssertTrue(payload.attachment)
    }

    /// A file with no extension is judged by its bytes, because output names
    /// plenty of them — Makefile, a log, a scratch file.
    func testExtensionlessTextIsStillText() throws {
        let url = try write("notes", "just some words")
        XCTAssertEqual(try FilePreview.read(url).kind, "text")
    }

    func testDirectoryIsNotAFile() {
        XCTAssertThrowsError(try FilePreview.read(root))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try FilePreview.read(root.appendingPathComponent("nope")))
    }

    // MARK: - The cap

    func testLargeFileIsCappedAndSaysSo() throws {
        let url = root.appendingPathComponent("big.log")
        try Data(repeating: UInt8(ascii: "a"), count: 5000).write(to: url)
        let payload = try FilePreview.read(url, cap: 1000)
        XCTAssertEqual(payload.data.count, 1000)
        XCTAssertTrue(payload.truncated)
        // The header reports the whole size, not what was sent.
        XCTAssertEqual(payload.totalBytes, 5000)
    }

    func testSmallFileIsNotMarkedTruncated() throws {
        let url = try write("small.txt", "hi")
        let payload = try FilePreview.read(url, cap: 1000)
        XCTAssertFalse(payload.truncated)
        XCTAssertEqual(payload.totalBytes, 2)
    }

    // MARK: - Text sniffing

    func testNulByteMeansNotText() {
        XCTAssertFalse(FilePreview.isProbablyText(Data([0x68, 0x69, 0x00, 0x68])))
        XCTAssertTrue(FilePreview.isProbablyText(Data("hello\nworld\t".utf8)))
    }

    func testEmptyFileReadsAsText() {
        XCTAssertTrue(FilePreview.isProbablyText(Data()))
    }

    // MARK: - The filename in the header

    /// A crafted name must not break out of the `Content-Disposition` value.
    func testHeaderNameCannotEscapeItsQuotes() {
        XCTAssertFalse(FilePreview.headerSafeName("a\";x=\"b").contains("\""))
        XCTAssertFalse(FilePreview.headerSafeName("a\r\nX-Evil: 1").contains("\r"))
        XCTAssertFalse(FilePreview.headerSafeName("a\r\nX-Evil: 1").contains("\n"))
    }

    func testHeaderNameNeverEmpty() {
        XCTAssertEqual(FilePreview.headerSafeName("\"\""), "file")
        XCTAssertEqual(FilePreview.headerSafeName("report.json"), "report.json")
    }
}
