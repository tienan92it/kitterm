import Foundation
import XCTest

/// `AGENTS.md` is what every agent loads at session start, so it stays
/// short (goal `lean-context`, condition 1): 200 lines or fewer, no line
/// over 500 characters, and every `docs/` file it names exists, because the
/// specification it once held lives there now, one file per surface.
final class AgentsFileTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    static let maxLines = 200
    static let maxLineLength = 500

    private static func agents() throws -> String {
        try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    }

    func testAgentsFileIsShort() throws {
        let lines = try Self.agents().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertLessThanOrEqual(lines.count, Self.maxLines, "AGENTS.md has \(lines.count) lines")
        for (offset, line) in lines.enumerated() where line.count > Self.maxLineLength {
            XCTFail("AGENTS.md:\(offset + 1) is \(line.count) characters long")
        }
    }

    /// Every `docs/…` path the file names is a file or a directory in the
    /// checkout, so the index cannot point at a file a later move renamed.
    func testEveryDocsPathItNamesExists() throws {
        let text = try Self.agents()
        let pattern = try NSRegularExpression(pattern: #"docs/[A-Za-z0-9_./-]*"#)
        let range = NSRange(text.startIndex..., in: text)
        let paths = Set(pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        })
        XCTAssertTrue(paths.contains("docs/product-shape.md"), "AGENTS.md names the product shape file")
        XCTAssertTrue(paths.contains("docs/control-plane.md"), "AGENTS.md names the control plane file")
        for path in paths.sorted() {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(path).path),
                "AGENTS.md names `\(path)`, which does not exist"
            )
        }
    }
}
