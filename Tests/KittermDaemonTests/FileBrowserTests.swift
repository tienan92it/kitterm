import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// Browsing exists so a caller can hand something a real path instead of a
/// copy. The arithmetic that matters is turning what was asked for into a
/// directory, and reporting it in an order a person can scan.
final class FileBrowserTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-browse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("beta.txt"))
        try Data("xx".utf8).write(to: root.appendingPathComponent("alpha.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testListsDirectoriesFirstThenFilesAlphabetically() throws {
        let listing = try FileBrowser.list(root)
        XCTAssertEqual(listing.entries.map(\.name), ["src", "alpha.txt", "beta.txt"])
        XCTAssertTrue(listing.entries[0].isDirectory)
        XCTAssertEqual(listing.entries[1].size, 2)
        XCTAssertNil(listing.entries[0].size, "a directory has no size worth reporting")
    }

    func testHiddenFilesAreOptional() throws {
        XCTAssertFalse(try FileBrowser.list(root).entries.contains { $0.name == ".hidden" })
        XCTAssertTrue(
            try FileBrowser.list(root, includeHidden: true).entries.contains { $0.name == ".hidden" }
        )
    }

    func testParentIsReportedSoTheCallerCanWalkUp() throws {
        XCTAssertEqual(try FileBrowser.list(root).parent, root.deletingLastPathComponent().path)
        XCTAssertNil(try FileBrowser.list(URL(fileURLWithPath: "/")).parent, "root has no parent")
    }

    func testAFileIsNotADirectory() {
        XCTAssertThrowsError(try FileBrowser.list(root.appendingPathComponent("alpha.txt")))
    }

    // MARK: - resolving what was asked for

    func testRelativePathsResolveAgainstTheSessionDirectory() {
        let resolved = FileBrowser.resolve("src", base: root.path)
        XCTAssertEqual(resolved.path, root.appendingPathComponent("src").resolvingSymlinksInPath().path)
    }

    func testTildeMeansHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        XCTAssertEqual(FileBrowser.resolve("~", base: nil).path, home)
        XCTAssertEqual(FileBrowser.resolve("~/Documents", base: nil).path, home + "/Documents")
    }

    func testNothingAskedForMeansTheSessionDirectory() {
        XCTAssertEqual(FileBrowser.resolve(nil, base: root.path).path, root.standardizedFileURL.path)
        XCTAssertEqual(FileBrowser.resolve("", base: root.path).path, root.standardizedFileURL.path)
    }

    /// Absolute paths are honoured as given. There is no allowlist by design:
    /// anyone who can reach this can already type `ls` into the session, and
    /// the daemon runs as the user, so the OS decides what is readable.
    func testAbsolutePathsAreHonoured() {
        XCTAssertEqual(FileBrowser.resolve("/usr", base: root.path).path, "/usr")
        XCTAssertEqual(FileBrowser.resolve("../..", base: root.path).path,
                       root.deletingLastPathComponent().deletingLastPathComponent()
                           .standardizedFileURL.path)
    }
}
