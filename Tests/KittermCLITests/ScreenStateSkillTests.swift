import Foundation
import XCTest

@testable import KittermCLI

/// "Read before you type" step 1 now calls `screen_state` first
/// (`goal.md` condition 6, capability 3): `prompt-empty` types at once,
/// a dialog/`working`/`waiting-on-own-job` falls through to the existing
/// steps, and `unknown`/`agent-exited`/anything else still calls
/// `read_screen`. Pinned in both the on-disk example and its embedded
/// `ForemanSkills` copy, for every skill that carries the shared section
/// (`ForemanSkillsTests.testReadBeforeYouTypeIsShared` keeps the three
/// equal to each other).
final class ScreenStateSkillTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    private static let newStep1Sentences = [
        "Call `screen_state` first.",
        "On `prompt-empty`, type the message now and",
        "skip to step 4.",
        "`waiting-on-own-job`, act as step 3 says, and call `read_screen` before",
        "any keystroke into a dialog.",
        "On `unknown`, `agent-exited`, or anything",
        "find the row the cursor is on, and follow the",
    ]

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func exampleFiles() throws -> [(name: String, text: String)] {
        [
            ("examples/foreman/foreman-loop.md", try read("examples/foreman/foreman-loop.md")),
            ("examples/foreman/review-crew.md", try read("examples/foreman/review-crew.md")),
            ("examples/foreman/triage.md", try read("examples/foreman/triage.md")),
        ]
    }

    private static func embeddedCopies() -> [(name: String, text: String)] {
        ForemanSkills.files.map { ($0.name, $0.contents) }
    }

    /// Every on-disk example calls `screen_state` first in its step 1.
    func testEveryExampleFileCallsScreenStateFirst() throws {
        for (name, text) in try Self.exampleFiles() {
            for sentence in Self.newStep1Sentences {
                XCTAssertTrue(text.contains(sentence), "\(name) is missing: \(sentence)")
            }
        }
    }

    /// The golden test (`ForemanSkillsTests`) keeps `ForemanSkills.files`
    /// byte-equal to the files on disk; this pins the same new sentences
    /// in the embedded copy too, so a future edit to one without the other
    /// fails here before it fails the golden test.
    func testEveryEmbeddedCopyCallsScreenStateFirst() {
        for (name, text) in Self.embeddedCopies() {
            for sentence in Self.newStep1Sentences {
                XCTAssertTrue(text.contains(sentence), "ForemanSkills.\(name) is missing: \(sentence)")
            }
        }
    }

    /// Steps 2 through 5 are untouched: added to, not rewritten.
    func testTheRemainingStepsAreUnchanged() throws {
        let preserved = [
            "Type only when the prompt is at the cursor and the input box is empty: the",
            "Trust dialog — \"Is this a project you created or one you trust?\" with",
            "Permission dialog — \"Do you want to proceed?\" or a numbered choice with",
            "In-progress turn — a spinner line with \"esc to interrupt\", or a `⏺`",
            "Send the message with `send_input`. Send one dialog keystroke per call, and",
            "Call `read_screen` again. Confirm the text you typed now appears above the",
        ]
        for (name, text) in try Self.exampleFiles() + Self.embeddedCopies() {
            for sentence in preserved {
                XCTAssertTrue(text.contains(sentence), "\(name) is missing: \(sentence)")
            }
        }
    }

    /// Step 1 no longer opens with the retired, screen-blind sentence.
    func testTheOldStep1SentenceIsGone() throws {
        let retired = "1. Call `read_screen`. Find the row the cursor is on.\n"
        for (name, text) in try Self.exampleFiles() + Self.embeddedCopies() {
            XCTAssertFalse(text.contains(retired), "\(name) still opens step 1 with the retired sentence")
        }
    }
}
