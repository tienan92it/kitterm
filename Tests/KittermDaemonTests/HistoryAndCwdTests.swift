import Darwin
import Foundation
import XCTest

@testable import KittermDaemon

/// Per-pane history-file key sanitization and the `proc_pidinfo` cwd read.
final class HistoryAndCwdTests: XCTestCase {
    // MARK: - historyFile(for:) sanitization

    func testAcceptsUUIDLikeKeys() {
        let path = WebSocketSessionHandler.historyFile(for: "9f1c0b2a-4d3e-4f5a-8b6c-1d2e3f4a5b6c")
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.hasPrefix(DaemonPaths.historyDirectory.path + "/"))
    }

    func testRejectsPathTraversal() {
        XCTAssertNil(WebSocketSessionHandler.historyFile(for: "../../etc/passwd"))
        XCTAssertNil(WebSocketSessionHandler.historyFile(for: "a/b"))
        XCTAssertNil(WebSocketSessionHandler.historyFile(for: "with space"))
        XCTAssertNil(WebSocketSessionHandler.historyFile(for: "dot.dot"))
    }

    func testRejectsEmptyOrNilOrOverlong() {
        XCTAssertNil(WebSocketSessionHandler.historyFile(for: nil))
        XCTAssertNil(WebSocketSessionHandler.historyFile(for: ""))
        XCTAssertNil(WebSocketSessionHandler.historyFile(for: String(repeating: "a", count: 129)))
    }

    func testAcceptsMaxLengthKey() {
        XCTAssertNotNil(WebSocketSessionHandler.historyFile(for: String(repeating: "a", count: 128)))
    }

    // MARK: - seedHistoryFile

    func testSeedsFromGlobalOnceAndDoesNotOverwrite() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let perPane = dir.appendingPathComponent("p1").path
        // No global to copy from → an empty file is created, not an error.
        PtySession.seedHistoryFile(perPane, shell: "/bin/zsh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: perPane))

        // A second call must not clobber the pane's accumulated history.
        try "pane command\n".write(toFile: perPane, atomically: true, encoding: .utf8)
        PtySession.seedHistoryFile(perPane, shell: "/bin/zsh")
        XCTAssertEqual(try String(contentsOfFile: perPane, encoding: .utf8), "pane command\n")
    }

    // MARK: - proc_pidinfo cwd read

    func testReadsAProcessWorkingDirectory() {
        // Our own process cwd is a real directory we can compare against.
        let path = PtySession.currentDirectory(ofPID: getpid())
        XCTAssertNotNil(path)
        // proc returns the resolved real path; compare resolved forms.
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().path
        XCTAssertEqual(URL(fileURLWithPath: path!).resolvingSymlinksInPath().path, expected)
    }

    func testReturnsNilForAReapedPid() {
        // PID 2^31-1 is not a live process; the read must fail gracefully.
        XCTAssertNil(PtySession.currentDirectory(ofPID: pid_t(Int32.max)))
    }
}
