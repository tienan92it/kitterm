import Foundation
import XCTest

@testable import KittermDaemon
@testable import KittermProtocol

/// `FileBrowser.stat` — the answer that decides whether a path in terminal
/// output is drawn as a link. A wrong "yes" produces a link that opens nothing,
/// which the feature exists to avoid.
final class FileStatTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-stat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true
        )
        try "hello".write(
            to: root.appendingPathComponent("src/main.ts"), atomically: true, encoding: .utf8
        )
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    func testTellsAFileFromADirectory() {
        let stats = FileBrowser.stat(["src", "src/main.ts"], base: root.path)
        XCTAssertEqual(stats.count, 2)
        XCTAssertTrue(stats[0].exists)
        XCTAssertTrue(stats[0].isDirectory)
        XCTAssertTrue(stats[1].exists)
        XCTAssertFalse(stats[1].isDirectory)
    }

    /// Not an error — "no" is the answer, and the client leaves the text plain.
    func testAbsentPathIsAnAnswerRatherThanAFailure() {
        let stats = FileBrowser.stat(["src/nope.ts"], base: root.path)
        XCTAssertEqual(stats.count, 1)
        XCTAssertFalse(stats[0].exists)
    }

    /// The reply carries the question back, so a caller can match answers to
    /// what it asked without re-deriving our resolution.
    func testEchoesWhatWasAsked() {
        let stats = FileBrowser.stat(["src/main.ts"], base: root.path)
        XCTAssertEqual(stats[0].requested, "src/main.ts")
        XCTAssertTrue(stats[0].resolved.hasSuffix("/src/main.ts"))
        XCTAssertTrue(stats[0].resolved.hasPrefix("/"))
    }

    /// Relative paths mean "from this shell's directory", which is the whole
    /// reason the route takes a session id.
    func testRelativePathsResolveAgainstTheGivenDirectory() {
        XCTAssertTrue(FileBrowser.stat(["main.ts"], base: root.appendingPathComponent("src").path)[0].exists)
        XCTAssertFalse(FileBrowser.stat(["main.ts"], base: root.path)[0].exists)
    }

    func testAbsolutePathsIgnoreTheBase() {
        let absolute = root.appendingPathComponent("src/main.ts").path
        XCTAssertTrue(FileBrowser.stat([absolute], base: "/nowhere")[0].exists)
    }

    func testAnswersEveryQuestionInOrder() {
        let asked = ["src", "missing", "src/main.ts"]
        let stats = FileBrowser.stat(asked, base: root.path)
        XCTAssertEqual(stats.map(\.requested), asked)
    }

    /// A path may contain any byte but NUL, so a stat must not choke on the
    /// characters a shell will happily put in a filename.
    func testHandlesAwkwardNames() throws {
        let odd = root.appendingPathComponent("a b&c=d.txt")
        try "x".write(to: odd, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileBrowser.stat(["a b&c=d.txt"], base: root.path)[0].exists)
    }
}

/// `?path=a&path=b` is the only way to pass a list of paths, because no
/// delimiter is safe: any character a separator could use may appear in a real
/// filename.
final class RepeatedQueryValueTests: XCTestCase {
    func testCollectsEveryValueInOrder() {
        let uri = "/api/files/stat?path=src%2Fa.ts&session=x&path=%2Ftmp%2Fb"
        XCTAssertEqual(
            DaemonServer.queryValues("path", fromRequestURI: uri),
            ["src/a.ts", "/tmp/b"]
        )
    }

    func testIsEmptyWhenNothingWasAsked() {
        XCTAssertTrue(DaemonServer.queryValues("path", fromRequestURI: "/api/files/stat").isEmpty)
    }

    func testDropsEmptyValuesRatherThanStattingTheCwd() {
        XCTAssertEqual(
            DaemonServer.queryValues("path", fromRequestURI: "/api/files/stat?path=&path=a"),
            ["a"]
        )
    }

    func testSingleValueReaderStillWorksAlongside() {
        let uri = "/api/files/stat?path=a&path=b"
        XCTAssertEqual(DaemonServer.queryValue("path", fromRequestURI: uri), "a")
    }
}
