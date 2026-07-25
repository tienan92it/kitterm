import Foundation
import XCTest

@testable import KittermDaemon

final class SessionProfilesTests: XCTestCase {
    private var tempFile: URL!

    override func setUpWithError() throws {
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-profiles-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFile)
    }

    private func write(_ json: String) throws {
        try json.write(to: tempFile, atomically: true, encoding: .utf8)
    }

    func testLoadsValidProfiles() throws {
        try write(
            #"""
            { "profiles": [
              { "name": "vm", "command": "ssh dev-vm", "cwd": "~/Workspace" },
              { "name": "agents.1", "command": "docker exec -it agents bash" }
            ] }
            """#
        )
        let profiles = SessionProfiles.load(from: tempFile)
        XCTAssertEqual(profiles, [
            SessionProfile(name: "vm", command: "ssh dev-vm", cwd: "~/Workspace"),
            SessionProfile(name: "agents.1", command: "docker exec -it agents bash"),
        ])
    }

    func testMissingFileIsEmpty() {
        XCTAssertEqual(SessionProfiles.load(from: tempFile), [])
    }

    func testMalformedFileIsEmpty() throws {
        try write("not json at all")
        XCTAssertEqual(SessionProfiles.load(from: tempFile), [])
        try write(#"{ "profiles": "nope" }"#)
        XCTAssertEqual(SessionProfiles.load(from: tempFile), [])
    }

    func testInvalidEntriesAreSkippedNotFatal() throws {
        // Path-traversal name, multi-line command, missing fields, and one
        // valid entry — only the valid one survives.
        try write(
            #"""
            { "profiles": [
              { "name": "../evil", "command": "rm -rf /" },
              { "name": "multiline", "command": "ssh a\nrm -rf /" },
              { "name": "empty", "command": "" },
              { "command": "no name" },
              { "name": "ok", "command": "ssh vm" }
            ] }
            """#
        )
        XCTAssertEqual(
            SessionProfiles.load(from: tempFile),
            [SessionProfile(name: "ok", command: "ssh vm")]
        )
    }

    func testDuplicateNamesFirstWins() throws {
        try write(
            #"""
            { "profiles": [
              { "name": "vm", "command": "ssh first" },
              { "name": "vm", "command": "ssh second" }
            ] }
            """#
        )
        XCTAssertEqual(
            SessionProfiles.load(from: tempFile),
            [SessionProfile(name: "vm", command: "ssh first")]
        )
    }

    func testCommandLengthCap() throws {
        let long = String(repeating: "x", count: SessionProfiles.maxCommandBytes + 1)
        try write(#"{ "profiles": [ { "name": "long", "command": "\#(long)" } ] }"#)
        XCTAssertEqual(SessionProfiles.load(from: tempFile), [])
    }

    func testNameValidation() {
        XCTAssertTrue(SessionProfiles.isValidName("vm-1.agents_x"))
        XCTAssertFalse(SessionProfiles.isValidName(""))
        XCTAssertFalse(SessionProfiles.isValidName("has space"))
        XCTAssertFalse(SessionProfiles.isValidName("slash/name"))
        XCTAssertFalse(SessionProfiles.isValidName(String(repeating: "a", count: 65)))
    }

    func testFind() throws {
        try write(#"{ "profiles": [ { "name": "vm", "command": "ssh vm" } ] }"#)
        XCTAssertEqual(
            SessionProfiles.find("vm", from: tempFile),
            SessionProfile(name: "vm", command: "ssh vm")
        )
        XCTAssertNil(SessionProfiles.find("nope", from: tempFile))
    }
}
