import Foundation
import XCTest

@testable import KittermCLI

/// The embedded skills equal the files under `examples/foreman/` byte for
/// byte, so the two cannot drift. Edit the file, then paste it into
/// `ForemanSkills.swift`.
final class ForemanSkillsTests: XCTestCase {
    private static let examples = CLIFixture.repositoryRoot
        .appendingPathComponent("examples/foreman", isDirectory: true)

    func testEverySkillMatchesItsExampleFile() throws {
        for (name, contents) in ForemanSkills.files {
            let file = Self.examples.appendingPathComponent("\(name).md")
            let onDisk = try Data(contentsOf: file)
            XCTAssertEqual(onDisk, Data(contents.utf8), "examples/foreman/\(name).md differs from ForemanSkills")
        }
    }

    /// Every file under `examples/foreman/` is embedded; nothing is left behind.
    func testEveryExampleFileIsEmbedded() throws {
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: Self.examples.path)
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(".md".count)) }
        XCTAssertEqual(Set(onDisk), Set(ForemanSkills.files.map(\.name)))
    }

    /// The frontmatter `name:` is the directory the skill installs into, and
    /// every skill carries a description for `kitterm skills list`.
    func testFrontmatter() {
        XCTAssertEqual(ForemanSkills.files.map(\.name), ["foreman-loop", "review-crew", "triage"])
        for (name, contents) in ForemanSkills.files {
            XCTAssertTrue(contents.hasPrefix("---\nname: \(name)\n"), "\(name) frontmatter names itself")
            XCTAssertFalse(ForemanSkills.description(of: contents).isEmpty, "\(name) has a description")
            XCTAssertTrue(contents.hasSuffix("\n"), "\(name) ends with a newline")
        }
        XCTAssertEqual(ForemanSkills.description(of: "---\nname: x\ndescription:  Do x. \n---\n# x\n"), "Do x.")
        XCTAssertEqual(ForemanSkills.description(of: "# no frontmatter\n"), "")
    }

    /// The shared "Read before you type" text is the same in every skill.
    func testReadBeforeYouTypeIsShared() throws {
        func section(_ contents: String) -> Substring? {
            guard let start = contents.range(of: "## Read before you type\n") else { return nil }
            let rest = contents[start.upperBound...]
            guard let end = rest.range(of: "\n## ") else { return nil }
            return rest[..<end.lowerBound]
        }
        let sections = try ForemanSkills.files.map { try XCTUnwrap(section($0.contents), $0.name) }
        for other in sections.dropFirst() {
            XCTAssertEqual(sections[0], other)
        }
        XCTAssertTrue(sections[0].contains("cooked reader"))
        // The trust dialog is answered with the toolset alone: `keys`, not a
        // shell that pipes raw bytes into the input route.
        XCTAssertFalse(sections[0].contains("curl"))
        XCTAssertTrue(sections[0].contains("send_input keys=[\"down\"]"))
        XCTAssertTrue(sections[0].contains("send_input keys=[\"enter\"]"))
    }
}
