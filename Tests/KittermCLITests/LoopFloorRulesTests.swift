import Foundation
import XCTest

@testable import KittermCLI

/// The pull request's CI is the second floor (`foreman-flow` round 3,
/// capability 3). The foreman skips a local floor the world already
/// proved, and reads the pull request's checks instead of rerunning
/// `swift test` and the Linux pipe itself. The rule is written once and
/// read in five places: the three copies of `LOOP.md` carry the contract
/// (with placeholders in the generic template for the checks
/// `plan.md` names), the two copies of the foreman skill carry the
/// procedure, and `docs/foreman.md` names both. Each sentence below must
/// be held whole; only the line breaks may differ, as `GoalsLayoutDocsTests`
/// checks for the older rules.
final class LoopFloorRulesTests: XCTestCase {
    private static let root = CLIFixture.repositoryRoot

    /// These sentences carry no repository-specific command name (`swift
    /// test`, `ci.yml`, `Linux`), so the generic template and the concrete
    /// file hold them word for word; only the bullet about the crew's own
    /// checks differs, because that bullet names the checks `plan.md`
    /// lists for this repository.
    static let loopRules: [(rule: String, sentence: String)] = [
        (
            "the pull request's CI run is part of the floor once it opens",
            """
            `plan.md` names the floor's checks. From the round the pull request opens,
            its CI run is part of the floor: a green run already proves the base sha.
            """
        ),
        (
            "a green run on either the base sha or the pull request skips the floor",
            """
            Either green skips the floor, and the foreman
            writes which run it relied on in the round record's `Floor` "before"
            line. Neither green: the foreman runs the floor as before the round.
            """
        ),
        (
            "the foreman does not rerun what the crew or the pull request's CI already proved",
            """
            After the crew, the foreman does not rerun a check the crew already ran
            or a check the pull request's CI already proves. It reads the diff and
            sorts the paths into the Authority table below, then waits on
            `gh pr checks <N>` for the crew's head sha; it writes the round record
            and `STATE.md` while that check runs, and pushes them once the check is
            green. A red check is the round's gap, and the one correction goes to
            the crew, like any other gap.
            """
        ),
    ]

    static let skillRules: [(rule: String, sentence: String)] = [
        (
            "the foreman checks the world before it runs the floor itself",
            """
            Either
            green skips the floor; write which run you relied on in the round
            record's `Floor` "before" line. Neither green: run the floor from
            `plan.md` in that shell, one check per call:
            """
        ),
        (
            "the foreman does not rerun a check inside Collect",
            """
            Do not rerun a check the crew already ran, or a
            check the pull request's continuous integration already proves
            (`LOOP.md`, "The floor").
            """
        ),
        (
            "the foreman waits on the pull request's checks and writes while they run",
            """
            Wait on `gh pr checks <N>` for the crew's head sha; do not rerun the
            checks yourself. Write the round record and `STATE.md` while that check
            runs (steps 7 and 8), and push them once it is green. A red check is
            the round's gap, like a red floor was before.
            """
        ),
        (
            "the push waits for the pull request's checks to go green",
            """
            Push the branch once the pull request's continuous integration on the
            crew's head sha is green (step 4): write and commit while it runs, and
            push after.
            """
        ),
    ]

    /// The wording capability 3 retired: the foreman used to run the floor
    /// itself before every round, and to rerun it after the crew, whatever
    /// the base sha's or the pull request's own CI already showed.
    static let retiredWordings = [
        "The shell sits at its prompt. Run the floor from `plan.md`",
        "Run the floor again in the repository root on the\ncrew's branch and compare the result with the note",
        "Floor green and the diff holds the check: mark the",
    ]

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func loopFiles() throws -> [(name: String, text: String)] {
        [
            ("docs/goals/LOOP.md", try read("docs/goals/LOOP.md")),
            ("examples/goals/LOOP.md", try read("examples/goals/LOOP.md")),
            ("GoalsTemplates.loop", GoalsTemplates.loop),
        ]
    }

    private static func skillFiles() throws -> [(name: String, text: String)] {
        [
            ("examples/foreman/foreman-loop.md", try read("examples/foreman/foreman-loop.md")),
            ("ForemanSkills.foremanLoop", ForemanSkills.foremanLoop),
        ]
    }

    func testTheLoopFilesCarryTheFloorRules() throws {
        for (name, text) in try Self.loopFiles() {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.loopRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(sentence)")
            }
        }
    }

    /// The generic template's crew bullet names the checks `plan.md` lists
    /// instead of `swift test` or the Linux pipe; the concrete files name
    /// them. Both still say the crew runs its own checks once, then pushes,
    /// and does not run a check the pull request's CI proves instead.
    func testTheCrewBulletNamesItsOwnChecksInEveryCopy() throws {
        for (name, text) in try Self.loopFiles() {
            let oneLine = Self.oneLine(text)
            XCTAssertTrue(
                oneLine.contains(Self.oneLine("once, after its")) || oneLine.contains(Self.oneLine("once, after its change, then pushes")),
                "\(name) says the crew runs its checks once, then pushes"
            )
            XCTAssertTrue(
                oneLine.contains(Self.oneLine("not the crew's to run again")),
                "\(name) says a check the pull request's CI proves is not rerun"
            )
        }
    }

    func testTheSkillCarriesTheFloorProcedure() throws {
        for (name, text) in try Self.skillFiles() {
            let oneLine = Self.oneLine(text)
            for (rule, sentence) in Self.skillRules where !oneLine.contains(Self.oneLine(sentence)) {
                XCTFail("\(name) does not carry the rule that \(rule), in these words: \(sentence)")
            }
        }
    }

    func testNoCopyStillRerunsTheFloorItself() throws {
        for (name, text) in try Self.loopFiles() + Self.skillFiles() {
            let oneLine = Self.oneLine(text)
            for retired in Self.retiredWordings where oneLine.contains(Self.oneLine(retired)) {
                XCTFail("\(name) still carries the wording capability 3 retired: `\(retired)`")
            }
        }
    }

    /// `docs/foreman.md` names the same practice in "Delegate".
    func testTheManualNamesTheFloorPractice() throws {
        let manual = Self.oneLine(try Self.read("docs/foreman.md"))
        for phrase in [
            "The foreman skips the floor before a round",
            "waits on the pull request's checks instead of rerunning them itself",
            "pushes it once the check is green",
        ] {
            XCTAssertTrue(manual.contains(Self.oneLine(phrase)), "docs/foreman.md names \(phrase)")
        }
    }
}
