import XCTest

@testable import KittermCLI

/// `kitterm edit [path]` (`code-editor` round 7): the path it resolves, the
/// URL it opens, and the error for a path that is not there. No browser is
/// opened here; `openInBrowser` is the one line the tests leave alone.
final class EditCommandTests: XCTestCase {
    func testResolvesLikeOpenRelativeTildeAndAbsolute() {
        let cwd = "/Users/an/Workspace/kitterm"
        let home = "/Users/an"
        XCTAssertEqual(EditCommand.resolve(nil, cwd: cwd, home: home), cwd)
        XCTAssertEqual(EditCommand.resolve(".", cwd: cwd, home: home), cwd)
        XCTAssertEqual(EditCommand.resolve("src/../README.md", cwd: cwd, home: home), cwd + "/README.md")
        XCTAssertEqual(EditCommand.resolve("Web/terminal/", cwd: cwd, home: home), cwd + "/Web/terminal")
        XCTAssertEqual(EditCommand.resolve("~", cwd: cwd, home: home), home)
        XCTAssertEqual(EditCommand.resolve("~/notes.md", cwd: cwd, home: home), home + "/notes.md")
        XCTAssertEqual(EditCommand.resolve("/tmp/x/./y", cwd: cwd, home: home), "/tmp/x/y")
    }

    func testTheURLIsTheEditPageOnKittermLocalhostWithThePathEncoded() {
        XCTAssertEqual(
            EditCommand.url(port: 3418, path: "/Users/an/Workspace/kitterm"),
            "http://kitterm.localhost:3418/edit?path=/Users/an/Workspace/kitterm"
        )
        // A space, a `+` and a `&` must come back as themselves from
        // `URLSearchParams`, so none of them stays bare.
        XCTAssertEqual(
            EditCommand.url(port: 3500, path: "/tmp/a b/c+d&e=f#g"),
            "http://kitterm.localhost:3500/edit?path=/tmp/a%20b/c%2Bd%26e%3Df%23g"
        )
        XCTAssertEqual(EditCommand.percentEncoded("é"), "%C3%A9")
    }

    func testAMissingPathIsTheErrorTheCLIPrints() throws {
        let present = NSTemporaryDirectory()
        XCTAssertEqual(try EditCommand.existing(present), present)
        let missing = present + "/kitterm-edit-missing-\(UUID().uuidString)"
        XCTAssertThrowsError(try EditCommand.existing(missing)) { error in
            XCTAssertEqual(error.localizedDescription, "no such file or directory: \(missing)")
        }
    }
}
