import Foundation
import XCTest

@testable import KittermCLI

/// `kitterm skills install --dir <tmp>` and `kitterm skills list`.
final class SkillsInstallTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-skills-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func run(_ args: [String]) throws -> [String] {
        var lines: [String] = []
        try SkillsCommand.run(args) { lines.append($0) }
        return lines
    }

    private func path(_ name: String) -> String {
        dir.appendingPathComponent(name).appendingPathComponent("SKILL.md").path
    }

    private func files() throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: dir.path))
        var result: [String: Data] = [:]
        for case let relative as String in enumerator {
            let full = dir.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                result[relative] = try Data(contentsOf: full)
            }
        }
        return result
    }

    private func modificationDates() throws -> [String: Date] {
        var dates: [String: Date] = [:]
        for (name, _) in ForemanSkills.files {
            let attributes = try FileManager.default.attributesOfItem(atPath: path(name))
            dates[name] = try XCTUnwrap(attributes[.modificationDate] as? Date)
        }
        return dates
    }

    /// The first run creates the directory and writes three files, each
    /// equal to its embedded skill.
    func testInstallWritesEverySkill() throws {
        let lines = try run(["install", "--dir", dir.path])
        XCTAssertEqual(lines, ForemanSkills.files.map { "wrote \(path($0.name))" })
        let written = try files()
        XCTAssertEqual(Set(written.keys), Set(ForemanSkills.files.map { "\($0.name)/SKILL.md" }))
        for (name, contents) in ForemanSkills.files {
            XCTAssertEqual(written["\(name)/SKILL.md"], Data(contents.utf8), name)
        }
    }

    /// A second run prints `unchanged` for every file and rewrites nothing.
    func testSecondRunIsUnchanged() throws {
        try run(["install", "--dir", dir.path])
        let before = try files()
        let dates = try modificationDates()

        let lines = try run(["install", "--dir", dir.path])
        XCTAssertEqual(lines, ForemanSkills.files.map { "unchanged \(path($0.name))" })
        XCTAssertEqual(try files(), before)
        XCTAssertEqual(try modificationDates(), dates, "an unchanged file keeps its mtime")
    }

    /// An edited copy is replaced and reported as `updated`; the others stay
    /// `unchanged`.
    func testEditedCopyIsUpdated() throws {
        try run(["install", "--dir", dir.path])
        let edited = URL(fileURLWithPath: path("review-crew"))
        try Data("# mine\n".utf8).write(to: edited)

        let lines = try run(["install", "--dir", dir.path])
        XCTAssertEqual(
            lines,
            [
                "unchanged \(path("foreman-loop"))",
                "updated \(path("review-crew"))",
                "unchanged \(path("triage"))",
            ]
        )
        XCTAssertEqual(try Data(contentsOf: edited), Data(ForemanSkills.reviewCrew.utf8))
    }

    /// `--dir` is honoured in both spellings, and a relative path is taken
    /// from the cwd.
    func testDirOption() throws {
        let equals = dir.appendingPathComponent("equals", isDirectory: true)
        try run(["install", "--dir=\(equals.path)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: equals.appendingPathComponent("triage/SKILL.md").path))

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cwd = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(cwd) }
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(dir.path))
        let lines = try run(["install", "--dir", "relative"])
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("wrote ") }, "\(lines)")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("relative/foreman-loop/SKILL.md").path
            )
        )
    }

    func testListPrintsNamesAndDescriptions() throws {
        let lines = try run(["list"])
        XCTAssertEqual(lines.count, ForemanSkills.files.count)
        for (line, skill) in zip(lines, ForemanSkills.files) {
            XCTAssertEqual(line, "\(skill.name)\t\(ForemanSkills.description(of: skill.contents))")
            XCTAssertTrue(line.count > skill.name.count + 20, "the description is on the line: \(line)")
        }
    }

    func testUsageRefusals() {
        XCTAssertThrowsError(try run([]))
        XCTAssertThrowsError(try run(["bogus"]))
        XCTAssertThrowsError(try run(["install", "--dir"]))
        XCTAssertThrowsError(try run(["install", "--bogus"]))
        XCTAssertThrowsError(try run(["list", "extra"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
