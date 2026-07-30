import Foundation
import KittermProtocol
import XCTest

@testable import KittermDaemon

/// The daemon is now the only thing that indexes marks, so it has to agree with
/// the browser's parser about what counts as one. The first group is the corpus
/// from `Web/terminal/src/command-marks.test.ts`, case for case, so the two
/// implementations cannot drift on that question. The rest covers what a byte
/// scanner has to handle and an xterm OSC handler never saw: split sequences,
/// both terminators, and hostile payloads.
final class OscMarkScannerTests: XCTestCase {
    private func scan(_ text: String, baseOffset: UInt64 = 0) -> [OscMarkScanner.Hit] {
        var scanner = OscMarkScanner()
        return scanner.scan(Data(text.utf8), baseOffset: baseOffset)
    }

    private func esc(_ payload: String, st: Bool = false) -> String {
        st ? "\u{1b}]\(payload)\u{1b}\\" : "\u{1b}]\(payload)\u{07}"
    }

    // MARK: - Corpus shared with the client parser

    func testParsesTheSharedLetters() {
        XCTAssertEqual(OscMarkScanner.mark(fromParams: "A")?.kind, .promptStart)
        XCTAssertEqual(OscMarkScanner.mark(fromParams: "B")?.kind, .commandStart)
        XCTAssertEqual(OscMarkScanner.mark(fromParams: "C")?.kind, .preExec)
        let end = OscMarkScanner.mark(fromParams: "D;0")
        XCTAssertEqual(end?.kind, .commandEnd)
        XCTAssertEqual(end?.exit, 0)
        XCTAssertEqual(OscMarkScanner.mark(fromParams: "D;130")?.exit, 130)
    }

    func testIgnoresExtensionParametersOnA() {
        // `A;special_key=1` is still a prompt start, not something unknown.
        XCTAssertEqual(OscMarkScanner.mark(fromParams: "A;special_key=1")?.kind, .promptStart)
    }

    func testUnknownLettersAreNotMarks() {
        XCTAssertNil(OscMarkScanner.mark(fromParams: "Z"))
        XCTAssertNil(OscMarkScanner.mark(fromParams: ""))
        XCTAssertNil(OscMarkScanner.mark(fromParams: "P;Cwd=/tmp"))
    }

    func testCommandEndWithoutAnExitCode() {
        let end = OscMarkScanner.mark(fromParams: "D")
        XCTAssertEqual(end?.kind, .commandEnd)
        XCTAssertNil(end?.exit)
    }

    func testParsesEIntoACommandLine() {
        XCTAssertEqual(OscMarkScanner.commandLine(fromOsc633: "E;ls -la;abc123"), "ls -la")
    }

    func testParsesEWithoutANonce() {
        XCTAssertEqual(OscMarkScanner.commandLine(fromOsc633: "E;ls -la"), "ls -la")
    }

    func testUnescapesHexEscapesInE() {
        // `;` and newlines are hex-escaped so they cannot terminate the payload.
        XCTAssertEqual(
            OscMarkScanner.commandLine(fromOsc633: #"E;echo a\x3b b"#),
            "echo a; b"
        )
        XCTAssertEqual(
            OscMarkScanner.commandLine(fromOsc633: #"E;line1\x0aline2"#),
            "line1\nline2"
        )
    }

    func testHandlesBackslashAndHexPairs() {
        XCTAssertEqual(OscMarkScanner.commandLine(fromOsc633: #"E;a\\b"#), #"a\b"#)
    }

    func testIgnoresEmptyE() {
        XCTAssertNil(OscMarkScanner.commandLine(fromOsc633: "E;"))
        XCTAssertNil(OscMarkScanner.commandLine(fromOsc633: "E"))
    }

    // MARK: - Scanning the stream

    func testFindsMarksAmongOrdinaryOutput() {
        let hits = scan("hello\(esc("133;A"))prompt$ \(esc("133;C"))output\(esc("133;D;1"))")
        XCTAssertEqual(hits.map(\.kind), [.promptStart, .preExec, .commandEnd])
        XCTAssertEqual(hits.last?.exit, 1)
    }

    func testAcceptsBothTerminators() {
        XCTAssertEqual(scan(esc("133;A")).count, 1)
        XCTAssertEqual(scan(esc("133;A", st: true)).count, 1)
    }

    func testAttaches633CommandLineToTheNextPreExec() {
        let hits = scan("\(esc("633;E;git status;nonce"))\(esc("133;C"))")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].kind, .preExec)
        XCTAssertEqual(hits[0].command, "git status")
    }

    func testCommandLineIsConsumedOnlyOnce() {
        let hits = scan("\(esc("633;E;ls"))\(esc("133;C"))x\(esc("133;D;0"))\(esc("133;C"))")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].command, "ls")
        XCTAssertNil(hits[2].command, "a second command must not inherit the first one's text")
    }

    func testOversizedCommandLineKeepsTheMarkAndDropsTheText() {
        let long = String(repeating: "x", count: KittermConstants.maxMarkCommandBytes + 1)
        let hits = scan("\(esc("633;E;\(long)"))\(esc("133;C"))")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].kind, .preExec)
        XCTAssertNil(hits[0].command)
    }

    /// Output arrives in arbitrary chunks, so every sequence has to survive
    /// being cut at any byte. This is the failure mode a per-chunk parser has
    /// and the client's OSC handler never did.
    func testSurvivesSplittingAtEveryOffset() {
        let stream = "before\(esc("633;E;make test"))\(esc("133;C"))out\(esc("133;D;2"))after"
        let bytes = Array(stream.utf8)
        for cut in 1..<bytes.count {
            var scanner = OscMarkScanner()
            var hits = scanner.scan(Data(bytes[0..<cut]), baseOffset: 0)
            hits += scanner.scan(Data(bytes[cut...]), baseOffset: UInt64(cut))
            XCTAssertEqual(
                hits.map(\.kind), [.preExec, .commandEnd],
                "split at \(cut) lost or duplicated a mark"
            )
            XCTAssertEqual(hits[0].command, "make test", "split at \(cut) lost the command text")
            XCTAssertEqual(hits[1].exit, 2, "split at \(cut) lost the exit code")
        }
    }

    func testOffsetsBracketACommandsOutput() {
        // The output of a command lies between the C mark and the D mark, so
        // those anchor to opposite ends of their own sequences.
        let prefix = "$ "
        let start = esc("133;C")
        let body = "hello\n"
        let stream = prefix + start + body + esc("133;D;0")
        let hits = scan(stream)
        XCTAssertEqual(hits.count, 2)
        let expectedStart = UInt64((prefix + start).utf8.count)
        let expectedEnd = UInt64((prefix + start + body).utf8.count)
        XCTAssertEqual(hits[0].offset, expectedStart, "output starts after the C sequence")
        XCTAssertEqual(hits[1].offset, expectedEnd, "output ends where the D sequence begins")
    }

    func testOffsetsAreAbsolute() {
        let hits = scan(esc("133;A"), baseOffset: 1_000_000)
        XCTAssertEqual(hits.count, 1)
        XCTAssertGreaterThan(hits[0].offset, 1_000_000)
    }

    // MARK: - Hostile and malformed input

    func testUnterminatedSequenceCannotGrowWithoutBound() {
        var scanner = OscMarkScanner()
        // Open a sequence, then flood without ever terminating it.
        _ = scanner.scan(Data("\u{1b}]133;".utf8), baseOffset: 0)
        for i in 0..<64 {
            let flood = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
            let hits = scanner.scan(flood, baseOffset: UInt64(i) * 65536)
            XCTAssertTrue(hits.isEmpty)
        }
        // The abandoned sequence must not poison what follows.
        let after = scanner.scan(Data("\u{07}\(esc("133;A"))".utf8), baseOffset: 9_000_000)
        XCTAssertEqual(after.map(\.kind), [.promptStart])
    }

    func testOtherOscSequencesAreIgnored() {
        // Notifications, titles and cwd reports are the client's business.
        let hits = scan("\(esc("9;done"))\(esc("777;notify;a;b"))\(esc("7;file:///tmp"))\(esc("0;title"))")
        XCTAssertTrue(hits.isEmpty)
    }

    func testMalformedSequencesProduceNothing() {
        XCTAssertTrue(scan("\u{1b}]133").isEmpty, "no terminator")
        XCTAssertTrue(scan("\u{1b}[133;A\u{07}").isEmpty, "CSI, not OSC")
        XCTAssertTrue(scan("\u{1b}]133;A").isEmpty, "unterminated")
        XCTAssertTrue(scan("]133;A\u{07}").isEmpty, "no escape")
        XCTAssertTrue(scan("\u{1b}]\u{07}").isEmpty, "empty payload")
    }

    func testEscapeInsideAPayloadAbortsItAndCanOpenTheNext() {
        // `ESC` that is not part of ST ends the sequence; if it is the start of
        // a real one, that one still gets found.
        let hits = scan("\u{1b}]133;A\u{1b}]133;C\u{07}")
        XCTAssertEqual(hits.map(\.kind), [.preExec])
    }

    func testCsiInterleavedWithMarksDoesNotConfuseTheScanner() {
        let colour = "\u{1b}[31m"
        let reset = "\u{1b}[0m"
        let hits = scan("\(colour)red\(reset)\(esc("133;A"))\(colour)$\(reset)\(esc("133;C"))")
        XCTAssertEqual(hits.map(\.kind), [.promptStart, .preExec])
    }
}
