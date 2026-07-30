import Foundation
import XCTest

@testable import KittermDaemon

final class SessionLabelsTests: XCTestCase {
    func testParsesPairs() {
        let labels = SessionLabels.parse("run:abc123,node:build,attempt:2")
        XCTAssertEqual(labels["run"], "abc123")
        XCTAssertEqual(labels["node"], "build")
        XCTAssertEqual(labels["attempt"], "2")
    }

    func testKeysAreCaseInsensitive() {
        XCTAssertEqual(SessionLabels.parse("Run:abc")["run"], "abc")
    }

    func testEmptyInputIsEmpty() {
        XCTAssertTrue(SessionLabels.parse(nil).isEmpty)
        XCTAssertTrue(SessionLabels.parse("").isEmpty)
    }

    /// A malformed tag must cost a filter, not the connection.
    func testMalformedPairsAreSkippedNotFatal() {
        let labels = SessionLabels.parse("noseparator,run:ok,:novalue,key:,ok2:yes")
        XCTAssertEqual(labels.values, ["run": "ok", "ok2": "yes"])
    }

    func testRejectsHostileKeysAndValues() {
        XCTAssertTrue(SessionLabels.parse("run space:v").isEmpty)
        XCTAssertTrue(SessionLabels.parse(#"run:va"lue"#).isEmpty, "must not admit quote chars into JSON")
        XCTAssertTrue(SessionLabels.parse("run:new\nline").isEmpty)
        XCTAssertTrue(SessionLabels.parse("ru<n>:v").isEmpty)
    }

    func testCaps() {
        let many = (0..<40).map { "k\($0):v" }.joined(separator: ",")
        XCTAssertEqual(SessionLabels.parse(many).values.count, SessionLabels.maxCount)
        let longKey = String(repeating: "k", count: SessionLabels.maxKeyLength + 1)
        XCTAssertTrue(SessionLabels.parse("\(longKey):v").isEmpty)
        let longValue = String(repeating: "v", count: SessionLabels.maxValueLength + 1)
        XCTAssertTrue(SessionLabels.parse("k:\(longValue)").isEmpty)
    }

    /// A W3C traceparent has to survive intact — it is how a caller correlates
    /// a session's commands with a span it owns.
    func testTraceparentSurvivesVerbatim() {
        let tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        let labels = SessionLabels.parse("\(SessionLabels.traceparentKey):\(tp)")
        XCTAssertEqual(labels[SessionLabels.traceparentKey], tp)
    }

    func testFilterMatching() {
        let labels = SessionLabels.parse("run:abc,node:build")
        XCTAssertTrue(labels.matches(filter: "run:abc"))
        XCTAssertTrue(labels.matches(filter: "Run:abc"))
        XCTAssertFalse(labels.matches(filter: "run:other"))
        XCTAssertFalse(labels.matches(filter: "missing:abc"))
        XCTAssertFalse(labels.matches(filter: "malformed"))
    }
}
