import Foundation
import XCTest

@testable import KittermCLI

/// The three homes of the loop's rules stay short (`one-rule-one-place`,
/// completion condition 1): `docs/goals/LOOP.md`, the skill
/// `examples/foreman/foreman-loop.md` and `docs/foreman.md` hold 11,500
/// words or fewer together, counted as `wc -w` counts them. A round that
/// adds a rule trims a duplicate in the same commit.
final class LoopWordCeilingTests: XCTestCase {
    static let ceiling = 11_500
    static let documents = ["docs/goals/LOOP.md", "examples/foreman/foreman-loop.md", "docs/foreman.md"]

    /// Words as `wc -w` counts them: runs of characters between whitespace.
    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    func testTheThreeDocumentsStayUnderTheCeiling() throws {
        var counts: [String: Int] = [:]
        for path in Self.documents {
            let url = CLIFixture.repositoryRoot.appendingPathComponent(path)
            counts[path] = Self.words(try String(contentsOf: url, encoding: .utf8))
        }
        let total = counts.values.reduce(0, +)
        XCTAssertLessThanOrEqual(total, Self.ceiling, "words per document: \(counts)")
    }

    func testWordsCountsLikeWc() {
        XCTAssertEqual(Self.words("a  b\n\tc — `d`\n"), 5)
        XCTAssertEqual(Self.words(""), 0)
    }

    /// The goal template's next action opens the round with the command,
    /// not by a hand spawn.
    func testTheStateTemplateNamesRoundOpen() throws {
        let file = try String(
            contentsOf: CLIFixture.repositoryRoot.appendingPathComponent("examples/goals/goal/STATE.md"),
            encoding: .utf8
        )
        for text in [file, GoalsTemplates.state] {
            XCTAssertTrue(text.contains("`kitterm round open <root> <goal slug> --task <item>`"))
            XCTAssertFalse(text.contains("Spawn one crew session"))
        }
    }
}
