import Foundation
import XCTest

@testable import KittermCLI

/// The project tools of the MCP bridge: the `list_projects` schema as a
/// client caches it, the requests the project tools turn into, and the
/// `list_sessions` schema's project filter.
final class MCPProjectToolsTests: XCTestCase {
    private func schema(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(MCPTools.schemas().first { ($0["name"] as? String) == name })
    }

    /// The golden: what `tools/list` says about `list_projects`.
    func testListProjectsSchema() throws {
        let schema = try schema("list_projects")
        let description = try XCTUnwrap(schema["description"] as? String)
        for term in ["projects.json", "kitterm project add", ".git", "registered", "knowledge", "docs/goals", "STATE.md"] {
            XCTAssertTrue(description.contains(term), "description names \(term)")
        }
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        XCTAssertEqual(input["type"] as? String, "object")
        XCTAssertEqual((input["properties"] as? [String: Any])?.count, 0, "no arguments")
        XCTAssertNil(input["required"])
    }

    func testListProjectsIsAGet() throws {
        let call = try MCPTools.call(named: "list_projects", arguments: [:])
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.path, "/api/projects")
        XCTAssertNil(call.jsonBody)
    }

    /// `list_sessions` takes the project filter beside the label filter.
    func testListSessionsFiltersByProject() throws {
        let schema = try schema("list_sessions")
        let properties = try XCTUnwrap((schema["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(properties["project"])

        XCTAssertEqual(
            try MCPTools.call(named: "list_sessions", arguments: ["project": "kitterm"]).path,
            "/api/sessions?project=kitterm"
        )
        XCTAssertEqual(
            try MCPTools.call(named: "list_sessions", arguments: ["label": "crew:alpha", "project": "kitterm"]).path,
            "/api/sessions?label=crew:alpha&project=kitterm"
        )
        XCTAssertEqual(
            try MCPTools.call(named: "list_sessions", arguments: ["project": "a&b=c"]).path,
            "/api/sessions?project=a%26b%3Dc",
            "a value cannot split the query"
        )
    }
}
