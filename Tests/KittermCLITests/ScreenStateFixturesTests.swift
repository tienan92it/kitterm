import Foundation
import XCTest

@testable import KittermCLI

/// The fixtures under `Fixtures/screen-state/` are real `read_screen` answers,
/// recorded from scratch Claude Code panes, one file per screen. Issue #171
/// names eight states a rule must tell apart; this test proves every fixture
/// parses as a `read_screen` answer, names one of the eight states, and that
/// every one of the eight states has at least one fixture — the proof row of
/// `plan.md` capability 1. It fixes no rule: `ScreenState` (capability 2)
/// reads these same files to prove its own answers against real screens.
final class ScreenStateFixturesTests: XCTestCase {
    /// The eight states of issue #171, in the order its table lists them.
    static let issueStates: Set<String> = [
        "prompt-empty",
        "prompt-has-text",
        "working",
        "waiting-on-own-job",
        "trust-dialog",
        "permission-dialog",
        "agent-exited",
        "unknown",
    ]

    private var fixturesURL: URL {
        CLIFixture.repositoryRoot
            .appendingPathComponent("Tests")
            .appendingPathComponent("KittermCLITests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("screen-state")
    }

    private func fixtureFiles() throws -> [String: Data] {
        try CLIFixture.files(under: fixturesURL)
    }

    func testEveryFixtureParsesAsAReadScreenAnswer() throws {
        let files = try fixtureFiles()
        XCTAssertFalse(files.isEmpty, "no fixtures found under \(fixturesURL.path)")
        for (name, data) in files {
            guard name.hasSuffix(".json") else { continue }
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any],
                "\(name) is not a JSON object"
            )
            XCTAssertEqual(object["ok"] as? Bool, true, "\(name) is not an ok read_screen answer")
            XCTAssertNotNil(object["cols"] as? Int, "\(name) has no cols")
            XCTAssertNotNil(object["rows"] as? Int, "\(name) has no rows")
            let cursor = try XCTUnwrap(object["cursor"] as? [String: Any], "\(name) has no cursor")
            XCTAssertNotNil(cursor["row"] as? Int, "\(name)'s cursor has no row")
            XCTAssertNotNil(cursor["col"] as? Int, "\(name)'s cursor has no col")
            XCTAssertNotNil(cursor["visible"] as? Bool, "\(name)'s cursor has no visible")
            XCTAssertNotNil(object["lines"] as? [String], "\(name) has no lines")
        }
    }

    func testEveryFixtureNamesAStateFromTheIssuesList() throws {
        let files = try fixtureFiles()
        for (name, data) in files {
            guard name.hasSuffix(".json") else { continue }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let state = try XCTUnwrap(object["state"] as? String, "\(name) names no state")
            XCTAssertTrue(
                Self.issueStates.contains(state),
                "\(name) names state \"\(state)\", not one of \(Self.issueStates.sorted())"
            )
        }
    }

    func testEveryFixtureCarriesTheClaudeCodeVersionAndTheRecordingDate() throws {
        let files = try fixtureFiles()
        for (name, data) in files {
            guard name.hasSuffix(".json") else { continue }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(object["claudeCodeVersion"] as? String, "\(name) has no claudeCodeVersion")
            XCTAssertNotNil(object["recordedAt"] as? String, "\(name) has no recordedAt")
            XCTAssertNotNil(object["method"] as? String, "\(name) has no method")
        }
    }

    func testEveryIssueStateHasAtLeastOneFixture() throws {
        let files = try fixtureFiles()
        var seen: Set<String> = []
        for (name, data) in files {
            guard name.hasSuffix(".json") else { continue }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if let state = object["state"] as? String {
                seen.insert(state)
            }
        }
        for state in Self.issueStates {
            XCTAssertTrue(seen.contains(state), "no fixture names state \"\(state)\"")
        }
    }
}
