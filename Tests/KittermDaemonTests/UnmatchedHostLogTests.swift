import XCTest

@testable import KittermDaemon

/// One line per unmatched name, the words an operator reads in `server.log`.
final class UnmatchedHostLogTests: XCTestCase {
    func testFirstReportPerNameIsOneLineNamingBothSides() {
        let log = UnmatchedHostLog(trustedHosts: ["mac.tailnet.ts.nett", "alt.example"])
        XCTAssertEqual(
            log.line(for: "Mac.Tailnet.ts.net:443"),
            "warning: a loopback peer named Host \"mac.tailnet.ts.net\", which matches no "
                + "--trusted-host (alt.example, mac.tailnet.ts.nett); if a proxy forwarded it, "
                + "that proxy is not a boundary and its callers get full access with no token\n"
        )
        XCTAssertNil(log.line(for: "mac.tailnet.ts.net"), "the same name, once")
        XCTAssertNotNil(log.line(for: "other.example"))
    }

    func testTheCapStopsAScanFromFillingTheLog() {
        nonisolated(unsafe) var lines: [String] = []
        let log = UnmatchedHostLog(trustedHosts: [], sink: { lines.append($0) })
        for n in 0..<(UnmatchedHostLog.maxNames + 10) {
            log.report("host\(n).example")
        }
        XCTAssertEqual(lines.count, UnmatchedHostLog.maxNames)
        XCTAssertTrue(lines[0].contains("(none)"), lines[0])
    }
}
