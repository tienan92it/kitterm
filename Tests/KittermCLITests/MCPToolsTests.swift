import Foundation
import XCTest

@testable import KittermCLI

/// The MCP tool layer maps each tool call to the exact HTTP request the daemon
/// serves. These pin that mapping and the argument validation — the bridge's
/// stdio loop is a thin frame around this.
final class MCPToolsTests: XCTestCase {
    private func call(_ name: String, _ arguments: [String: Any]) throws -> MCPTools.Call {
        try MCPTools.call(named: name, arguments: arguments)
    }

    // MARK: - schema

    func testEverySchemaHasNameAndInputSchema() {
        let schemas = MCPTools.schemas()
        XCTAssertEqual(schemas.count, 15)
        let names = Set(schemas.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: [
            "list_sessions", "spawn_session", "send_input", "wait_for_command",
            "wait_for_events", "post_note", "kill_session", "archive_session", "list_archives",
            "read_screen",
        ]))
        // Deciding is a human privilege: no approve/deny tool is exposed.
        XCTAssertFalse(names.contains("approve"))
        XCTAssertFalse(names.contains("deny"))
        for schema in schemas {
            XCTAssertNotNil(schema["name"] as? String)
            XCTAssertNotNil(schema["description"] as? String)
            XCTAssertNotNil(schema["inputSchema"] as? [String: Any])
        }
    }

    // MARK: - mapping

    func testListSessionsWithAndWithoutFilter() throws {
        XCTAssertEqual(try call("list_sessions", [:]).path, "/api/sessions")
        let filtered = try call("list_sessions", ["label": "crew:alpha"])
        XCTAssertEqual(filtered.method, "GET")
        XCTAssertEqual(filtered.path, "/api/sessions?label=crew:alpha")
    }

    func testSpawnBuildsAPost() throws {
        let c = try call("spawn_session", [
            "name": "crew-1", "input": "claude\n", "labels": ["crew": "alpha"],
        ])
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.path, "/api/sessions")
        XCTAssertEqual(c.jsonBody?["name"] as? String, "crew-1")
        XCTAssertEqual(c.jsonBody?["input"] as? String, "claude\n")
        XCTAssertEqual((c.jsonBody?["labels"] as? [String: Any])?["crew"] as? String, "alpha")
    }

    /// The bridge never picks the Enter byte itself: it asks the daemon to
    /// press Enter, and the daemon sends what the session's foreground reads
    /// (a line feed for the shell, a carriage return for a claude).
    func testSendInputAsksTheDaemonToPressEnterByDefault() throws {
        let run = try call("send_input", ["session": deadbeef, "text": "ls"])
        XCTAssertEqual(run.method, "POST")
        XCTAssertEqual(run.path, "/api/sessions/\(deadbeef)/input?enter=1")
        XCTAssertEqual(run.rawBody.map { String(decoding: $0, as: UTF8.self) }, "ls")

        // A trailing newline is the caller's own Enter: folded into the
        // request, never sent as a bare line feed a TUI would keep as text.
        let line = try call("send_input", ["session": deadbeef, "text": "fix the bug\n"])
        XCTAssertEqual(line.path, "/api/sessions/\(deadbeef)/input?enter=1")
        XCTAssertEqual(line.rawBody.map { String(decoding: $0, as: UTF8.self) }, "fix the bug")

        // Enter alone answers a dialog.
        let confirm = try call("send_input", ["session": deadbeef, "text": ""])
        XCTAssertEqual(confirm.path, "/api/sessions/\(deadbeef)/input?enter=1")
        XCTAssertEqual(confirm.rawBody, Data())

        // enter:false sends keystrokes as-is — a Ctrl-C, say.
        let keys = try call("send_input", ["session": deadbeef, "text": "\u{03}", "enter": false])
        XCTAssertEqual(keys.path, "/api/sessions/\(deadbeef)/input")
        XCTAssertEqual(keys.rawBody.map { String(decoding: $0, as: UTF8.self) }, "\u{03}")
        XCTAssertThrowsError(try call("send_input", ["session": deadbeef, "text": "", "enter": false]))
    }

    func testWaitForCommandCarriesTimeout() throws {
        let c = try call("wait_for_command", ["session": deadbeef, "command": 3, "timeout": 60])
        XCTAssertEqual(c.path, "/api/sessions/\(deadbeef)/commands/3/wait?timeout=60")
    }

    func testWaitForEventsDefaultsSinceToZero() throws {
        XCTAssertEqual(try call("wait_for_events", [:]).path, "/api/events?since=0")
        let c = try call("wait_for_events", ["since": 12, "session": deadbeef, "timeout": 20])
        XCTAssertEqual(c.path, "/api/events?since=12&timeout=20&session=\(deadbeef)")
        let e = try call("wait_for_events", ["since": 12, "epoch": "abc-123"])
        XCTAssertEqual(e.path, "/api/events?since=12&epoch=abc-123")
    }

    func testReadScreenFetchesTheSessionTailAndRendersIt() throws {
        let c = try call("read_screen", ["session": deadbeef])
        XCTAssertEqual(c.method, "GET")
        XCTAssertEqual(c.path, "/api/sessions/\(deadbeef)/output")
        // The bridge renders; the daemon only serves bytes. Styles are on
        // unless switched off, so a ghost suggestion reads as dim.
        XCTAssertEqual(c.screen, MCPTools.ScreenOptions(cols: nil, rows: nil, styles: true))

        let sized = try call("read_screen", [
            "session": deadbeef, "tail": 4096, "cols": 80, "rows": 24, "styles": false,
        ])
        XCTAssertEqual(sized.path, "/api/sessions/\(deadbeef)/output?tail=4096")
        XCTAssertEqual(sized.screen, MCPTools.ScreenOptions(cols: 80, rows: 24, styles: false))

        XCTAssertThrowsError(try call("read_screen", ["session": deadbeef, "tail": 0]))
        XCTAssertThrowsError(try call("read_screen", ["session": deadbeef, "cols": 0]))
        XCTAssertThrowsError(try call("read_screen", ["session": deadbeef, "rows": 5000]))
        XCTAssertThrowsError(try call("read_screen", ["session": deadbeef, "cols": "wide"]))
        // Every other tool returns the daemon's body as-is.
        XCTAssertNil(try call("read_output", ["session": deadbeef, "command": 1]).screen)
    }

    func testKillIsADelete() throws {
        let c = try call("kill_session", ["session": deadbeef])
        XCTAssertEqual(c.method, "DELETE")
        XCTAssertEqual(c.path, "/api/sessions/\(deadbeef)")
    }

    func testPostNoteBuildsAnEvent() throws {
        let c = try call("post_note", ["session": deadbeef, "message": "plan ready"])
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.path, "/api/sessions/\(deadbeef)/events")
        XCTAssertEqual(c.jsonBody?["message"] as? String, "plan ready")
    }

    // MARK: - validation

    func testMissingRequiredArgumentsThrow() {
        XCTAssertThrowsError(try call("get_session", [:]))
        XCTAssertThrowsError(try call("send_input", ["session": deadbeef]))  // no text
        XCTAssertThrowsError(try call("wait_for_command", ["session": deadbeef]))  // no command
        XCTAssertThrowsError(try call("post_note", ["session": deadbeef, "message": ""]))
        XCTAssertThrowsError(try call("nonexistent_tool", [:]))
    }

    /// A crafted session id must not escape the route path.
    func testSessionIdIsPathSafe() {
        XCTAssertThrowsError(try call("get_session", ["session": "../../etc/passwd"]))
        XCTAssertThrowsError(try call("get_session", ["session": "abc/def"]))
        XCTAssertThrowsError(try call("kill_session", ["session": "a b"]))
        // A real UUID is accepted.
        XCTAssertNoThrow(try call("get_session", ["session": deadbeef]))
    }

    private let deadbeef = "DEADBEEF-0000-4000-8000-000000000000"
}
