import Foundation
import XCTest

@testable import KittermCLI

/// The embedded templates equal the files under `examples/goals/` byte for
/// byte, so the two cannot drift. Edit the file, then paste it into
/// `GoalsTemplates.swift`.
final class GoalsTemplatesTests: XCTestCase {
    private static let examples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // KittermCLITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("examples/goals", isDirectory: true)

    func testEveryTemplateMatchesItsExampleFile() throws {
        for (path, contents) in GoalsTemplates.files {
            let file = Self.examples.appendingPathComponent(path)
            let onDisk = try Data(contentsOf: file)
            XCTAssertEqual(onDisk, Data(contents.utf8), "examples/goals/\(path) differs from GoalsTemplates")
        }
    }

    /// Every file under `examples/goals/` is embedded; nothing is left behind.
    func testEveryExampleFileIsEmbedded() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: Self.examples.path))
        var onDisk = Set<String>()
        for case let relative as String in enumerator {
            var isDirectory: ObjCBool = false
            let full = Self.examples.appendingPathComponent(relative).path
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue {
                onDisk.insert(relative)
            }
        }
        XCTAssertEqual(onDisk, Set(GoalsTemplates.files.map(\.path)))
    }

    func testPackageShape() {
        XCTAssertEqual(
            GoalsTemplates.files.map(\.path),
            ["goal.md", "facts.md", "plan.md", "LOOP.md", "STATE.md", "corpus/.gitkeep", "rounds/.gitkeep"]
        )
        for (path, contents) in GoalsTemplates.files where !path.hasSuffix(".gitkeep") {
            XCTAssertTrue(contents.hasPrefix("# "), "\(path) starts with a title")
            XCTAssertTrue(contents.hasSuffix("\n"), "\(path) ends with a newline")
        }
    }
}
