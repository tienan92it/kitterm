import Foundation
import XCTest

@testable import KittermCLI

/// The `read_screen` result: the tail route's bytes rendered at the size the
/// route reports, as JSON a foreman reads.
final class ScreenReportTests: XCTestCase {
    private let headers = [
        "X-Kitterm-Cols": "40", "X-Kitterm-Rows": "5",
        "X-Kitterm-Start": "0", "X-Kitterm-Head": "30",
    ]

    private func report(
        _ text: String,
        headers: [String: String]? = nil,
        options: MCPTools.ScreenOptions = .init(styles: true)
    ) throws -> [String: Any] {
        let json = try ScreenReport.text(data: Data(text.utf8), headers: headers ?? self.headers, options: options)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testRendersAtThePaneSizeFromTheHeaders() throws {
        let result = try report("❯ \u{1b}[2mTry \"refactor\"\u{1b}[22m\r\n\u{1b}[?25h")
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["cols"] as? Int, 40)
        XCTAssertEqual(result["rows"] as? Int, 5)
        XCTAssertEqual(result["lines"] as? [String], ["❯ {dim}Try \"refactor\"{/dim}"])
        let cursor = try XCTUnwrap(result["cursor"] as? [String: Any])
        XCTAssertEqual(cursor["row"] as? Int, 1)
        XCTAssertEqual(cursor["col"] as? Int, 0)
        XCTAssertEqual(cursor["visible"] as? Bool, true)
        XCTAssertNotNil(result["legend"] as? String)
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let lower = ["x-kitterm-cols": "8", "x-kitterm-rows": "2"]
        let result = try report("0123456789", headers: lower)
        XCTAssertEqual(result["lines"] as? [String], ["01234567", "89"])
    }

    func testOptionsOverrideTheSizeAndSwitchStylesOff() throws {
        let result = try report(
            "\u{1b}[2mghost\u{1b}[22m",
            options: .init(cols: 3, rows: 2, styles: false)
        )
        XCTAssertEqual(result["cols"] as? Int, 3)
        XCTAssertEqual(result["lines"] as? [String], ["gho", "st"])
        XCTAssertNil(result["legend"])
    }

    func testACutTailIsAlignedFromTheStartHeader() throws {
        let cut = ["X-Kitterm-Cols": "20", "X-Kitterm-Rows": "3", "X-Kitterm-Start": "500"]
        let result = try report("1;1Hjunk\u{1b}[2;1Hreal", headers: cut)
        XCTAssertEqual(result["lines"] as? [String], ["", "real"])
    }

    func testAnOldDaemonWithoutSizeHeadersIsAnError() {
        XCTAssertThrowsError(
            try ScreenReport.text(data: Data(), headers: [:], options: .init(styles: true))
        ) { error in
            XCTAssertEqual(error as? ScreenReport.Failure, .missingSize)
        }
    }
}
