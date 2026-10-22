import Foundation
import XCTest

@testable import KittermCLI

/// `ScreenStateCapture`, the opt-in local capture of `unknown` screens
/// (`screen-state` capability 5). Every test points the switch and the
/// directory at a scratch folder, so the real `~/.kitterm` is never touched.
final class ScreenStateCaptureTests: XCTestCase {
    private var dir: URL!
    private var settingsFile: URL!
    private var samplesDir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-screen-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsFile = dir.appendingPathComponent("screen-state.json")
        samplesDir = dir.appendingPathComponent("screen-unknown", isDirectory: true)
    }

    override func tearDownWithError() throws {
        // A read-only directory a test left behind must be writable to go.
        if let samplesDir, FileManager.default.fileExists(atPath: samplesDir.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: samplesDir.path)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000.5)

    private func sample(
        state: ScreenState.Value = .unknown,
        session: String = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        at: Date = fixedDate,
        lines: [String] = ["a line the rules did not match", "another"]
    ) -> ScreenStateCapture.Sample {
        ScreenStateCapture.Sample(
            at: at, session: session, state: state,
            rule: state == .unknown ? "unknown: no rule matched" : "working: a spinner",
            foregroundProgram: "claude", cols: 120, rows: 40, lines: lines
        )
    }

    private func files() throws -> [String] {
        guard FileManager.default.fileExists(atPath: samplesDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: samplesDir.path).sorted()
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func capture(_ sample: ScreenStateCapture.Sample) {
        ScreenStateCapture.capture(sample, settingsFile: settingsFile, directory: samplesDir)
    }

    // MARK: - the switch

    func testTheSwitchIsOffWithNoFile() {
        XCTAssertEqual(ScreenStateCapture.Settings.read(from: settingsFile), .off)
    }

    func testTheSwitchIsOffWhenTheFileSaysOff() throws {
        try Data("{\"captureUnknown\": false}".utf8).write(to: settingsFile)
        XCTAssertFalse(ScreenStateCapture.Settings.read(from: settingsFile).captureUnknown)
    }

    func testTheSwitchIsOffWhenTheFileIsUnreadable() throws {
        try Data("not json".utf8).write(to: settingsFile)
        XCTAssertFalse(ScreenStateCapture.Settings.read(from: settingsFile).captureUnknown)
        try Data("{\"captureUnknown\": \"yes\"}".utf8).write(to: settingsFile)
        XCTAssertFalse(ScreenStateCapture.Settings.read(from: settingsFile).captureUnknown)
        // A directory at the path is not readable as a file either.
        try FileManager.default.removeItem(at: settingsFile)
        try FileManager.default.createDirectory(at: settingsFile, withIntermediateDirectories: false)
        XCTAssertFalse(ScreenStateCapture.Settings.read(from: settingsFile).captureUnknown)
    }

    func testTheSwitchRoundTripsAt0600() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        XCTAssertTrue(ScreenStateCapture.Settings.read(from: settingsFile).captureUnknown)
        XCTAssertEqual(try mode(of: settingsFile), 0o600)
        let text = try String(contentsOf: settingsFile, encoding: .utf8)
        XCTAssertEqual(text, "{\"captureUnknown\":true}")

        try ScreenStateCapture.Settings(captureUnknown: false).write(to: settingsFile)
        XCTAssertFalse(ScreenStateCapture.Settings.read(from: settingsFile).captureUnknown)
        XCTAssertEqual(try mode(of: settingsFile), 0o600)
    }

    // MARK: - off writes nothing

    func testNoFileWhileTheSwitchFileIsMissing() throws {
        capture(sample())
        XCTAssertEqual(try files(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: samplesDir.path))
    }

    func testNoFileWhileTheSwitchIsOff() throws {
        try ScreenStateCapture.Settings(captureUnknown: false).write(to: settingsFile)
        capture(sample())
        XCTAssertEqual(try files(), [])
    }

    func testNoFileWhileTheSwitchIsUnreadable() throws {
        try Data("{".utf8).write(to: settingsFile)
        capture(sample())
        XCTAssertEqual(try files(), [])
    }

    // MARK: - on writes one file per unknown

    func testOneFilePerUnknownWithTheModesAndTheHeader() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        capture(sample())
        let names = try files()
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names[0], "20270115T080000.500Z-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.txt")
        XCTAssertEqual(try mode(of: samplesDir), 0o700)
        let fileURL = samplesDir.appendingPathComponent(names[0])
        XCTAssertEqual(try mode(of: fileURL), 0o600)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let expected = """
            kitterm screen-unknown sample
            at: 2027-01-15T08:00:00.500Z
            session: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
            program: claude
            size: 120x40
            rule: unknown: no rule matched

            a line the rules did not match
            another

            """
        XCTAssertEqual(text, expected)
    }

    func testTwoUnknownsAreTwoFiles() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        capture(sample(at: Self.fixedDate))
        capture(sample(at: Self.fixedDate.addingTimeInterval(1)))
        XCTAssertEqual(try files().count, 2)
    }

    /// The same session twice in one millisecond: the second file gets a
    /// `-2` suffix instead of failing on `O_EXCL`.
    func testASecondSampleInTheSameMillisecondGetsASuffix() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        capture(sample())
        capture(sample())
        XCTAssertEqual(try files(), [
            "20270115T080000.500Z-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE-2.txt",
            "20270115T080000.500Z-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.txt",
        ])
    }

    func testAKnownStateWritesNothingEvenWhileOn() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        for state in [ScreenState.Value.promptEmpty, .promptHasText, .working, .waitingOnOwnJob,
                      .trustDialog, .permissionDialog, .agentExited] {
            capture(sample(state: state))
        }
        XCTAssertEqual(try files(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: samplesDir.path))
    }

    func testAProgramOfNoneAndASanitisedSessionInTheName() throws {
        let odd = ScreenStateCapture.Sample(
            at: Self.fixedDate, session: "../x/../y", state: .unknown, rule: "unknown: no rule matched",
            foregroundProgram: nil, cols: 80, rows: 24, lines: []
        )
        XCTAssertEqual(ScreenStateCapture.fileName(for: odd), "20270115T080000.500Z-xy.txt")
        XCTAssertTrue(ScreenStateCapture.contents(of: odd).contains("\nprogram: none\n"))
        let empty = ScreenStateCapture.Sample(
            at: Self.fixedDate, session: "///", state: .unknown, rule: "r",
            foregroundProgram: nil, cols: 80, rows: 24, lines: []
        )
        XCTAssertEqual(ScreenStateCapture.fileName(for: empty), "20270115T080000.500Z-session.txt")
    }

    // MARK: - the caps

    func testTheFileCapKeepsTheNewestFifty() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        for second in 0..<55 {
            capture(sample(at: Self.fixedDate.addingTimeInterval(Double(second))))
        }
        let names = try files()
        XCTAssertEqual(names.count, ScreenStateCapture.maxFiles)
        // Seconds 5 … 54 remain: the five oldest went.
        XCTAssertTrue(names.first!.hasPrefix("20270115T080005.500Z"), names.first!)
        XCTAssertTrue(names.last!.hasPrefix("20270115T080054.500Z"), names.last!)
    }

    func testTheByteCapKeepsTheNewest() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        // Each file is about 600 KiB, so the fourth pushes the total over 2 MiB.
        let bigLines = Array(repeating: String(repeating: "x", count: 1023), count: 600)
        for second in 0..<4 {
            capture(sample(at: Self.fixedDate.addingTimeInterval(Double(second)), lines: bigLines))
        }
        let entries = try ScreenStateCapture.samples(in: samplesDir)
        XCTAssertEqual(entries.count, 3)
        XCTAssertLessThanOrEqual(entries.reduce(0) { $0 + $1.bytes }, ScreenStateCapture.maxBytes)
        XCTAssertTrue(entries.first!.name.hasPrefix("20270115T080003.500Z"), entries.first!.name)
        XCTAssertTrue(entries.last!.name.hasPrefix("20270115T080001.500Z"), entries.last!.name)
    }

    /// One sample over the cap on its own is still kept: the newest file
    /// is never the one removed.
    func testTheNewestFileSurvivesAloneOverTheByteCap() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        let huge = Array(repeating: String(repeating: "x", count: 1023), count: 2100)
        capture(sample(lines: huge))
        XCTAssertEqual(try files().count, 1)
    }

    // MARK: - a failed write never fails the tool

    func testAWriteIntoAReadOnlyDirectoryDoesNotThrowOrChangeTheAnswer() throws {
        try XCTSkipIf(geteuid() == 0, "root writes into a read-only directory")
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        try FileManager.default.createDirectory(
            at: samplesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500]
        )
        // The answer the bridge already sent, from a real render of a screen
        // with no marker.
        let answer = try ScreenStateReport.answer(
            data: Data("nothing the rules know".utf8),
            headers: ["X-Kitterm-Cols": "40", "X-Kitterm-Rows": "5", "X-Kitterm-Start": "0"],
            options: .init(styles: true), foregroundProgram: "claude"
        )
        XCTAssertEqual(answer.result.state, .unknown)
        let textBefore = answer.text
        let sample = ScreenStateCapture.Sample(
            at: Self.fixedDate, session: "S1", state: answer.result.state, rule: answer.result.rule,
            foregroundProgram: "claude", cols: answer.cols, rows: answer.rows, lines: answer.lines
        )
        capture(sample)  // must not throw, must not trap
        XCTAssertEqual(try files(), [])
        XCTAssertEqual(answer.text, textBefore)
        XCTAssertThrowsError(try ScreenStateCapture.write(sample, in: samplesDir))
    }

    // MARK: - reading back

    func testSamplesListNewestFirstWithTheHeaderFacts() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        capture(sample(session: "S-OLD", at: Self.fixedDate))
        capture(sample(session: "S-NEW", at: Self.fixedDate.addingTimeInterval(60)))
        let entries = try ScreenStateCapture.samples(in: samplesDir)
        XCTAssertEqual(entries.map(\.session), ["S-NEW", "S-OLD"])
        XCTAssertEqual(entries[0].at, Self.fixedDate.addingTimeInterval(60))
        XCTAssertEqual(entries[0].program, "claude")
        XCTAssertEqual(entries[0].size, "120x40")
        XCTAssertEqual(entries[0].bytes, ScreenStateCapture.contents(of: sample(session: "S-NEW")).utf8.count)
    }

    func testSamplesOfAMissingDirectoryIsEmpty() throws {
        XCTAssertEqual(try ScreenStateCapture.samples(in: samplesDir), [])
    }

    func testClearRemovesEveryFileAndCountsThem() throws {
        try ScreenStateCapture.Settings(captureUnknown: true).write(to: settingsFile)
        capture(sample(at: Self.fixedDate))
        capture(sample(at: Self.fixedDate.addingTimeInterval(1)))
        XCTAssertEqual(try ScreenStateCapture.clear(in: samplesDir), 2)
        XCTAssertEqual(try files(), [])
        XCTAssertEqual(try ScreenStateCapture.clear(in: samplesDir), 0)
    }
}
