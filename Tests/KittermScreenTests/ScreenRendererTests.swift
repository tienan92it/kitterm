import Foundation
import XCTest

@testable import KittermScreen

/// The renderer's contract: the bounded VT subset in ADR 0001, pinned on
/// hand-written sequences here and on real Claude Code pane logs in
/// `ClaudePaneFixtureTests`.
final class ScreenRendererTests: XCTestCase {
    private func render(_ text: String, cols: Int = 10, rows: Int = 4) -> ScreenRenderer.Screen {
        ScreenRenderer.render(Data(text.utf8), cols: cols, rows: rows)
    }

    private func lines(_ text: String, cols: Int = 10, rows: Int = 4, styles: Bool = false) -> [String] {
        render(text, cols: cols, rows: rows).lines(styles: styles)
    }

    // MARK: - text and controls

    func testPlainTextAndNewlines() {
        XCTAssertEqual(lines("hello\r\nworld"), ["hello", "world"])
        // A bare LF keeps the column, as a terminal does.
        XCTAssertEqual(lines("ab\ncd"), ["ab", "  cd"])
    }

    func testCarriageReturnOverwrites() {
        // The spinner idiom: redraw the same line in place.
        XCTAssertEqual(lines("⠋ working\r⠙ working\r✓ done   "), ["✓ done"])
    }

    func testBackspaceAndTab() {
        XCTAssertEqual(lines("abc\u{8}X"), ["abX"])
        XCTAssertEqual(lines("a\tb", cols: 20), ["a       b"])
    }

    func testAutowrapAtTheLastColumn() {
        XCTAssertEqual(lines("0123456789abc", cols: 10), ["0123456789", "abc"])
        // A wrap is pending after the last column, so a CR there stays on
        // the same row instead of wrapping first.
        XCTAssertEqual(lines("0123456789\rX", cols: 10), ["X123456789"])
    }

    func testAutowrapOffOverwritesTheLastColumn() {
        XCTAssertEqual(lines("\u{1b}[?7l0123456789abc", cols: 10), ["012345678c"])
    }

    func testScrollsWhenTheBottomRowFeeds() {
        XCTAssertEqual(lines("1\r\n2\r\n3\r\n4\r\n5", rows: 4), ["2", "3", "4", "5"])
    }

    // MARK: - escapes never leak

    func testUnknownSequencesAreDroppedNotPrinted() {
        // Queries, cursor-shape, bracketed paste, focus events, OSC titles,
        // DCS strings, charset designations — everything Claude Code and a
        // shell emit around the text.
        let noise = "\u{1b}[>0q\u{1b}[c\u{1b}[?2004h\u{1b}[?1004h\u{1b}]0;title\u{7}"
            + "\u{1b}]1337;RemoteHost=x\u{7}\u{1b}]133;A\u{1b}\\\u{1b}P+q544e\u{1b}\\\u{1b}(B\u{1b}=\u{1b}[ q"
        XCTAssertEqual(lines(noise + "ok"), ["ok"])
    }

    func testColoursAreConsumed() {
        let coloured = "\u{1b}[38;2;255;193;7m\u{1b}[48;5;236m\u{1b}[38:2:1:2:3mred\u{1b}[39m\u{1b}[0m"
        XCTAssertEqual(lines(coloured, styles: true), ["red"])
    }

    // MARK: - cursor moves and erase

    func testAbsolutePositionAndEraseToEnd() {
        let s = "line one\r\nline two\u{1b}[1;6Hxxx\u{1b}[K"
        XCTAssertEqual(lines(s, cols: 20), ["line xxx", "line two"])
    }

    func testCursorUpRedrawIdiom() {
        // Ink's redraw: move up over the old frame and rewrite it.
        let s = "a\r\nb\r\nc\u{1b}[2A\rX\u{1b}[K\u{1b}[1BY"
        XCTAssertEqual(lines(s), ["X", "bY", "c"])
    }

    func testColumnAbsoluteAndRelativeMoves() {
        XCTAssertEqual(lines("\u{1b}[5Gx\u{1b}[2Cy\u{1b}[3Dz", cols: 20), ["    xz y"])
        XCTAssertEqual(lines("\u{1b}[H\u{1b}[3C\u{1b}[2Bq"), ["", "", "   q"])
    }

    func testEraseInDisplay() {
        let s = "aaaa\r\nbbbb\r\ncccc\u{1b}[2;3H\u{1b}[J"
        XCTAssertEqual(lines(s), ["aaaa", "bb"])
        XCTAssertEqual(lines("aaaa\r\nbbbb\u{1b}[2J"), [])
        XCTAssertEqual(lines("aaaa\r\nbbbb\u{1b}[2;2H\u{1b}[1J"), ["", "  bb"])
    }

    func testEraseInLineModes() {
        XCTAssertEqual(lines("abcdef\u{1b}[3G\u{1b}[1K"), ["   def"])
        XCTAssertEqual(lines("abcdef\u{1b}[2K"), [])
    }

    func testInsertAndDeleteCharacters() {
        XCTAssertEqual(lines("abcdef\u{1b}[3G\u{1b}[2@"), ["ab  cdef"])
        XCTAssertEqual(lines("abcdef\u{1b}[3G\u{1b}[2P"), ["abef"])
        XCTAssertEqual(lines("abcdef\u{1b}[3G\u{1b}[2X"), ["ab  ef"])
    }

    func testInsertAndDeleteLines() {
        XCTAssertEqual(lines("1\r\n2\r\n3\u{1b}[2;1H\u{1b}[L"), ["1", "", "2", "3"])
        XCTAssertEqual(lines("1\r\n2\r\n3\u{1b}[2;1H\u{1b}[M"), ["1", "3"])
    }

    func testScrollRegion() {
        // Rows 2–3 form the region; feeding at its bottom scrolls only it.
        let s = "top\r\n\r\n\r\nbottom\u{1b}[2;3r\u{1b}[3;1Hx\r\ny\r\nz"
        XCTAssertEqual(lines(s, rows: 4), ["top", "y", "z", "bottom"])
    }

    func testSaveAndRestoreCursor() {
        XCTAssertEqual(lines("ab\u{1b}7\r\nxyz\u{1b}8Q"), ["abQ", "xyz"])
        XCTAssertEqual(lines("ab\u{1b}[s\r\nxyz\u{1b}[uQ"), ["abQ", "xyz"])
    }

    func testReverseIndexAtTheTopScrollsDown() {
        XCTAssertEqual(lines("a\u{1b}Mb"), [" b", "a"])
    }

    func testAlternateScreenRestoresTheMainOne() {
        let s = "main\u{1b}[?1049halt screen\u{1b}[?1049l"
        XCTAssertEqual(lines(s, cols: 20), ["main"])
        // The switch keeps the cursor where it was; a program homes it itself.
        XCTAssertEqual(lines("main\u{1b}[?1049h\u{1b}[Halt", cols: 20), ["alt"])
    }

    func testResetClearsEverything() {
        XCTAssertEqual(lines("abc\u{1b}[2mdim\u{1b}cok", styles: true), ["ok"])
    }

    // MARK: - styles

    func testDimAndInverseRunsAreMarked() {
        let s = "> \u{1b}[2mTry \"refactor\"\u{1b}[22m"
        XCTAssertEqual(lines(s, cols: 40, styles: true), ["> {dim}Try \"refactor\"{/dim}"])
        XCTAssertEqual(lines(s, cols: 40, styles: false), ["> Try \"refactor\""])
        XCTAssertEqual(lines("\u{1b}[7m Yes \u{1b}[27m No", cols: 20, styles: true), ["{inv} Yes {/inv} No"])
    }

    func testSGRResetEndsARun() {
        XCTAssertEqual(lines("\u{1b}[2ma\u{1b}[0mb", styles: true), ["{dim}a{/dim}b"])
    }

    func testDimSpacesNeverStartOrEndARun() {
        XCTAssertEqual(lines("\u{1b}[2m  a  \u{1b}[22mb", styles: true), ["  {dim}a{/dim}  b"])
        // Between two dim words the space stays inside the run.
        XCTAssertEqual(lines("\u{1b}[2ma b\u{1b}[22m c", styles: true), ["{dim}a b{/dim} c"])
    }

    // MARK: - width

    func testWideCharactersTakeTwoCells() {
        let screen = render("日本x", cols: 10)
        XCTAssertEqual(screen.lines(styles: false), ["日本x"])
        XCTAssertEqual(screen.cursorCol, 5)
        // Overwriting one half blanks the other.
        XCTAssertEqual(lines("日本\u{1b}[2GX", cols: 10), [" X本"])
    }

    func testWideCharacterWrapsWhenOnlyOneCellIsLeft() {
        XCTAssertEqual(lines("abc日", cols: 4), ["abc", "日"])
    }

    func testCombiningMarksAttachToTheCellBefore() {
        let screen = render("e\u{301}x", cols: 10)
        XCTAssertEqual(screen.lines(styles: false), ["e\u{301}x"])
        XCTAssertEqual(screen.cursorCol, 2)
    }

    func testEmojiPresentationIsWide() {
        XCTAssertEqual(render("🚀x", cols: 10).cursorCol, 3)
        // Box drawing and block elements stay narrow.
        XCTAssertEqual(render("─▐▛x", cols: 10).cursorCol, 4)
    }

    func testNoBreakSpaceRendersAsASpace() {
        XCTAssertEqual(lines("❯\u{a0}x\u{a0}"), ["❯ x"])
    }

    func testInvalidUTF8BecomesReplacement() {
        XCTAssertEqual(ScreenRenderer.render(Data([0x61, 0xFF, 0x62]), cols: 10, rows: 1).lines(styles: false), ["a\u{FFFD}b"])
        // A sequence cut short by a control byte.
        XCTAssertEqual(ScreenRenderer.render(Data([0xE2, 0x94, 0x0A, 0x62]), cols: 10, rows: 2).lines(styles: false), ["", "b"])
    }

    // MARK: - cursor report and bounds

    func testCursorPositionAndVisibility() {
        let screen = render("ab\u{1b}[?25l")
        XCTAssertEqual(screen.cursorRow, 0)
        XCTAssertEqual(screen.cursorCol, 2)
        XCTAssertFalse(screen.cursorVisible)
        XCTAssertTrue(render("\u{1b}[?25h").cursorVisible)
    }

    func testMovesClampToTheGrid() {
        let screen = render("\u{1b}[99;99H\u{1b}[99A\u{1b}[99D\u{1b}[99C\u{1b}[99B")
        XCTAssertEqual(screen.cursorRow, 3)
        XCTAssertEqual(screen.cursorCol, 9)
    }

    func testSizeIsClamped() {
        let screen = ScreenRenderer.render(Data(), cols: 0, rows: 5000)
        XCTAssertEqual(screen.cols, 1)
        XCTAssertEqual(screen.rows, 1000)
        // A one-column grid still takes a wide character.
        XCTAssertEqual(ScreenRenderer.render(Data("日".utf8), cols: 1, rows: 1).lines(styles: false), ["日"])
    }

    func testTrailingBlankRowsAndSpacesAreTrimmed() {
        XCTAssertEqual(lines("a   \r\n\r\n\r\n"), ["a"])
        let screen = render("\u{1b}[4;1Hx")
        XCTAssertEqual(screen.lines(styles: false), ["", "", "", "x"])
    }

    // MARK: - a cut tail

    func testACutTailSkipsToTheFirstEscapeOrLine() {
        // Mid-sequence bytes before the first ESC would print as text.
        let cut = Data("31;1Hjunk\u{1b}[2;1Hreal".utf8)
        XCTAssertEqual(ScreenRenderer.render(cut, cols: 10, rows: 3, streamStart: 500).lines(styles: false), ["", "real"])
        // From offset zero nothing is skipped.
        XCTAssertEqual(ScreenRenderer.render(cut, cols: 20, rows: 3, streamStart: 0).lines(styles: false)[0], "31;1Hjunk")
        // With no ESC the partial first line is dropped.
        XCTAssertEqual(ScreenRenderer.render(Data("tial\r\nwhole".utf8), cols: 10, rows: 3, streamStart: 9).lines(styles: false), ["whole"])
    }

    func testACutTailDropsLeadingContinuationBytes() {
        var cut = Data("日".utf8)
        cut.removeFirst()
        cut.append(contentsOf: Data("ok".utf8))
        XCTAssertEqual(ScreenRenderer.alignedStart(of: cut), 2)
        XCTAssertEqual(ScreenRenderer.render(cut, cols: 10, rows: 1, streamStart: 7).lines(styles: false), ["ok"])
    }

    func testRunawayCSIParametersAreDroppedNotPrinted() {
        let runaway = "\u{1b}[" + String(repeating: "1;", count: 100) + "mok"
        XCTAssertEqual(lines(runaway), ["ok"])
    }
}

extension ScreenRendererTests {
    func testACutTailStartsAtTheFirstAbsoluteCursorPosition() {
        // Text from a partial frame before the anchor would land on a wrong
        // row; only what follows the anchor is placed as the pane placed it.
        let cut = Data("\u{1b}[Kstale\u{1b}[1Bstale2\u{1b}[H\u{1b}[2Bfresh".utf8)
        XCTAssertEqual(
            ScreenRenderer.render(cut, cols: 20, rows: 4, streamStart: 100).lines(styles: false),
            ["", "", "fresh"]
        )
        XCTAssertEqual(ScreenRenderer.alignedStart(of: Data("ab\u{1b}[2Jx".utf8)), 2)
        XCTAssertEqual(ScreenRenderer.alignedStart(of: Data("ab\u{1b}cx".utf8)), 2)
        XCTAssertEqual(ScreenRenderer.alignedStart(of: Data("ab\u{1b}[?1049hx".utf8)), 2)
        // A private-mode or partial-erase sequence is not an anchor.
        XCTAssertEqual(ScreenRenderer.alignedStart(of: Data("ab\u{1b}[?25h\u{1b}[Jx".utf8)), 2)
        XCTAssertEqual(ScreenRenderer.alignedStart(of: Data("ab\u{1b}[?25h\u{1b}[3;4fx".utf8)), 8)
    }
}
