import Foundation
import XCTest

/// The deadline on every subprocess wait (`ProcessWaitTestSupport.swift`),
/// proved two ways: a subprocess stalled on purpose fails its test inside
/// the deadline, at the call site, with the test's name, the pid and the
/// last output; and no test source waits without one.
final class ProcessWaitTests: XCTestCase {
    private var stateDir: URL!
    private var captured: [XCTIssue] = []
    private var capturing = false

    /// While `capturing`, the failure the helper records lands here instead
    /// of on this test, so the test can read it back.
    override func record(_ issue: XCTIssue) {
        if capturing { captured.append(issue) } else { super.record(issue) }
    }

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-process-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    /// A process that prints why and then never exits, the way a stalled
    /// `serve` would. The failure arrives at the deadline, not after, at the
    /// line of the wait, and says which test, which pid, and what the
    /// process last wrote to its `server.log`.
    func testAStalledProcessFailsInsideTheDeadlineNamingTheTest() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", #"printf 'stalling on purpose\n' >> "$KITTERM_STATE_DIR/server.log"; exec sleep 300"#,
        ]
        process.environment = ["KITTERM_STATE_DIR": stateDir.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        let pid = process.processIdentifier
        let log = stateDir.appendingPathComponent("server.log")
        try poll("the stall to log why") { (try? String(contentsOf: log, encoding: .utf8))?.contains("purpose") == true }

        let started = Date()
        capturing = true
        let callLine = #line + 1
        let exited = waitForExit(of: process, within: 1)
        capturing = false
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(exited)
        XCTAssertLessThan(elapsed, 3, "the failure arrives at the deadline, not after it")
        XCTAssertEqual(captured.count, 1, captured.map(\.compactDescription).joined(separator: "\n"))
        let issue = try XCTUnwrap(captured.first)
        let message = issue.compactDescription
        XCTAssertTrue(message.contains(name), "names the test: \(message)")
        XCTAssertTrue(message.contains("pid \(pid)"), "names the pid: \(message)")
        XCTAssertTrue(message.contains("did not exit within 1.0 s"), message)
        XCTAssertTrue(message.contains("stalling on purpose"), "carries the last output: \(message)")
        XCTAssertEqual(issue.sourceCodeContext.location?.lineNumber, callLine, "points at the call site")
        XCTAssertEqual(issue.sourceCodeContext.location?.fileURL.lastPathComponent, "ProcessWaitTests.swift")
        try poll("the helper to reap the stall") { !process.isRunning }
    }

    /// A process that exits passes the wait and leaves its status readable.
    func testAnExitedProcessPassesWithItsStatus() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 3"]
        try process.run()
        XCTAssertTrue(waitForExit(of: process))
        XCTAssertEqual(process.terminationStatus, 3)
    }

    /// Completion condition 1 of `docs/goals/steady-suite/goal.md`: no test
    /// source calls the bare Foundation wait. Every hit is one failure that
    /// names the file and the line. A comment may mention the call; a
    /// symlink is the shared support file seen twice and is skipped.
    func testNoTestSourceWaitsWithoutADeadline() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // KittermDaemonTests
            .deletingLastPathComponent()  // Tests
        // In pieces, so this file does not match itself.
        let bare = "." + "waitUntil" + "Exit("
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: tests.path))
        var scanned = 0
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let file = tests.appendingPathComponent(relative)
            let type = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink { continue }
            scanned += 1
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, text) in lines.enumerated() where text.contains(bare) {
                if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                XCTFail("Tests/\(relative):\(index + 1) waits without a deadline; use waitForExit(of:)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan reached the test sources under \(tests.path)")
    }

    private func poll(
        _ what: String, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        throw CancellationError()
    }
}
