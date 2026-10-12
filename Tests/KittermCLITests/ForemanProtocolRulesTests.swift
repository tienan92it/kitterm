import Foundation
import XCTest

@testable import KittermCLI

/// The foreman protocol — a task list beside the package, a note's first
/// line naming its kind, the `FOREMAN:` prefix on every message into a crew
/// pane, and the one-automatic-continue stall rule (`foreman-protocol`,
/// capability 1). The rule is written once and read in three places: the
/// skill, its embedded copy, and `docs/foreman.md`, where it states the
/// rule. Each sentence below must be held whole; only the line breaks may
/// differ, the pattern of `LoopScopeRulesTests`.
final class ForemanProtocolRulesTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    static let protocolRules: [(rule: String, sentence: String)] = [
        (
            "a task's subject names the project, the slug, the round or chore, and the pull request",
            """
            One task per open round or chore, subject `<project> / <slug> round
            <n>: <queue item> · PR #N` (a chore: `<project> / chore <slug>: <what>
            · PR #N`), with an `activeForm`.
            """
        ),
        (
            "a crew note's first line names its kind, one of four",
            """
            Every crew note's first line is `<KIND> <slug> r<n>: <one line>` (a
            chore writes `<KIND> <slug>: <one line>`), and `KIND` is one of
            `PLAN`, `PROGRESS`, `BLOCKER`, or `DONE`
            """
        ),
        (
            "every message into a crew pane starts with the FOREMAN: prefix",
            """
            Every message the foreman types into a crew pane starts with
            `FOREMAN:` and carries one instruction. The crew treats `FOREMAN:`
            text as the foreman's word.
            """
        ),
        (
            "one automatic continue per round, then the human's word",
            """
            One automatic continue per round. A second stall in the round: report
            it to the human at once and wait for the human's word.
            """
        ),
    ]

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func files() throws -> [(name: String, text: String)] {
        [
            ("examples/foreman/foreman-loop.md", try read("examples/foreman/foreman-loop.md")),
            ("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop),
            ("docs/foreman.md", try read("docs/foreman.md")),
        ]
    }

    func testEveryFileCarriesTheProtocolRules() throws {
        for (name, text) in try Self.files() {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.protocolRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(sentence)")
            }
        }
    }

    /// The skill's own copy and the embedded one cannot drift; `ForemanSkillsTests`
    /// pins the whole file equal, this pins the rule inside it.
    func testTheSkillAndItsEmbeddedCopyAgree() throws {
        let onDisk = try Self.read("examples/foreman/foreman-loop.md")
        XCTAssertEqual(onDisk, ForemanSkills.foremanLoop)
    }
}
