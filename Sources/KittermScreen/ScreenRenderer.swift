import Foundation

/// A bounded VT100/xterm renderer: applies a byte stream to a cols × rows
/// grid and reports the text a person would see.
///
/// This lives in the MCP bridge, never in the daemon (ADR 0001). The subset
/// is fixed and the tests pin it: cursor moves, erase, insert and delete,
/// scroll regions, the alternate screen, autowrap, and the SGR attributes
/// dim and inverse. Colours are consumed and forgotten. Any sequence
/// outside the subset is parsed and dropped, never echoed as text.
public enum ScreenRenderer {
    /// A rendered grid.
    public struct Screen: Sendable, Equatable {
        public let cols: Int
        public let rows: Int
        /// Zero-based.
        public let cursorRow: Int
        public let cursorCol: Int
        public let cursorVisible: Bool
        /// The cells, `rows` arrays of `cols` cells.
        public let cells: [[Cell]]

        /// The rows as text, trailing spaces removed, trailing blank rows
        /// removed. Row `i` of the result is grid row `i`, so `cursorRow`
        /// still indexes it (a cursor past the end sits on a blank row).
        ///
        /// With `styles`, a run of dim cells is wrapped in `{dim}…{/dim}`
        /// and a run of inverse cells in `{inv}…{/inv}`. A dim space carries
        /// no marker: it is invisible either way. An inverse space does: a
        /// highlighted menu row is visible as a bar.
        public func lines(styles: Bool) -> [String] {
            var out: [String] = []
            for row in cells {
                out.append(Self.text(of: row, styles: styles))
            }
            while let last = out.last, last.isEmpty { out.removeLast() }
            return out
        }

        private static func text(of row: [Cell], styles: Bool) -> String {
            // Trim at the last visible cell so a marker never wraps trailing
            // blanks.
            var end = row.count
            while end > 0 {
                let cell = row[end - 1]
                if cell.continuation || (cell.text == " " && !(styles && cell.inverse)) {
                    end -= 1
                } else {
                    break
                }
            }
            var out = ""
            var dim = false
            var inverse = false
            let visible = row[..<end]
            for (index, cell) in visible.enumerated() where !cell.continuation {
                if styles {
                    // A dim space keeps a run open between two dim words and
                    // never starts or ends one.
                    var wantDim = cell.dim
                    if wantDim, cell.text == " " {
                        wantDim = dim && Self.nextVisibleIsDim(in: visible, after: index)
                    }
                    let wantInverse = cell.inverse
                    if dim != wantDim || inverse != wantInverse {
                        // Close in the reverse order of opening, then reopen.
                        if inverse { out += "{/inv}" }
                        if dim { out += "{/dim}" }
                        dim = wantDim
                        inverse = wantInverse
                        if dim { out += "{dim}" }
                        if inverse { out += "{inv}" }
                    }
                }
                out += cell.text
            }
            if inverse { out += "{/inv}" }
            if dim { out += "{/dim}" }
            return out
        }

        private static func nextVisibleIsDim(in cells: ArraySlice<Cell>, after index: Int) -> Bool {
            for cell in cells.dropFirst(index + 1) where !cell.continuation {
                if cell.text == " " {
                    if !cell.dim { return false }
                    continue
                }
                return cell.dim
            }
            return false
        }
    }

    public struct Cell: Sendable, Equatable {
        /// A scalar plus any combining marks; a space when blank.
        public var text: String = " "
        /// The right half of a wide character. Skipped when printing.
        public var continuation = false
        public var dim = false
        public var inverse = false

        static let blank = Cell()
    }

    /// Render `bytes` onto a blank `cols` × `rows` grid.
    ///
    /// `streamStart` is the absolute offset of `bytes[0]`. When it is not
    /// zero the bytes begin at an arbitrary cut — inside an escape sequence,
    /// inside a UTF-8 sequence, mid-frame — so rendering begins at the first
    /// point where the cursor is known: see `alignedStart`.
    public static func render(
        _ bytes: Data,
        cols: Int,
        rows: Int,
        streamStart: UInt64 = 0
    ) -> Screen {
        let terminal = Terminal(cols: cols, rows: rows)
        let start = streamStart == 0 ? 0 : alignedStart(of: bytes)
        terminal.feed(bytes[bytes.startIndex.advanced(by: start)...])
        return terminal.screen()
    }

    /// Where rendering of a cut tail begins.
    ///
    /// The first sequence that fixes the cursor absolutely — `CUP` (`ESC[H`,
    /// `ESC[r;cH`), a full erase (`ESC[2J`), a reset (`ESC c`), or a switch
    /// to the alternate screen — is the first point from which every later
    /// byte lands where the pane put it. A TUI starts each frame with one,
    /// so text from a partial frame before it never lands on a wrong row.
    /// With none in the tail (plain scrolling output), the first `ESC` or
    /// the byte after the first LF is the fallback, and leading UTF-8
    /// continuation bytes are dropped either way.
    static func alignedStart(of bytes: Data) -> Int {
        let count = bytes.count
        let at = { (i: Int) -> UInt8 in bytes[bytes.startIndex + i] }
        var index = 0
        while index < count, at(index) & 0xC0 == 0x80 { index += 1 }
        var firstEscape: Int?
        var firstNewline: Int?
        var i = index
        while i < count {
            let b = at(i)
            if b == 0x0A, firstNewline == nil { firstNewline = i }
            if b == 0x1B {
                if firstEscape == nil { firstEscape = i }
                if fixesCursor(bytes, at: i) { return i }
            }
            i += 1
        }
        if let esc = firstEscape { return esc }
        if let nl = firstNewline { return nl + 1 }
        return index
    }

    /// Whether the escape sequence at `index` is one of the anchors
    /// `alignedStart` looks for.
    private static func fixesCursor(_ bytes: Data, at index: Int) -> Bool {
        let count = bytes.count
        let at = { (i: Int) -> UInt8 in bytes[bytes.startIndex + i] }
        guard index + 1 < count else { return false }
        let next = at(index + 1)
        if next == 0x63 { return true }  // ESC c
        guard next == 0x5B else { return false }  // ESC [
        var i = index + 2
        var params: [UInt8] = []
        while i < count, params.count < 16 {
            let b = at(i)
            switch b {
            case 0x30...0x39, 0x3B, 0x3F:
                params.append(b)
                i += 1
            case 0x48, 0x66:  // H f
                return params.allSatisfy { $0 != 0x3F }
            case 0x4A:  // J
                return params == [0x32] || params == [0x33]
            case 0x68:  // h
                return params == Array("?1049".utf8) || params == Array("?1047".utf8)
                    || params == Array("?47".utf8)
            default:
                return false
            }
        }
        return false
    }

    public static let minCols = 1
    public static let minRows = 1
    public static let maxCols = 1000
    public static let maxRows = 1000
}

// MARK: - Terminal state machine

final class Terminal {
    typealias Cell = ScreenRenderer.Cell

    let cols: Int
    let rows: Int

    private var grid: [[Cell]]
    private var savedGrid: [[Cell]]?  // the main screen while the alternate is active
    private var row = 0
    private var col = 0
    private var pendingWrap = false
    private var cursorVisible = true
    private var autowrap = true
    private var scrollTop = 0
    private var scrollBottom: Int
    private var attrs = Cell()
    private var saved: (row: Int, col: Int, attrs: Cell)?

    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csi
        case osc
        case oscEscape  // saw ESC inside an OSC: ST if the next byte is `\`
        case string  // DCS / SOS / PM / APC, until ST
        case stringEscape
    }

    private var state = State.ground
    private var csiBytes: [UInt8] = []

    // Incremental UTF-8: the scalar under construction.
    private var utf8Pending: UInt32 = 0
    private var utf8Remaining = 0

    init(cols: Int, rows: Int) {
        self.cols = max(ScreenRenderer.minCols, min(cols, ScreenRenderer.maxCols))
        self.rows = max(ScreenRenderer.minRows, min(rows, ScreenRenderer.maxRows))
        grid = Array(repeating: Array(repeating: .blank, count: self.cols), count: self.rows)
        scrollBottom = self.rows - 1
    }

    func screen() -> ScreenRenderer.Screen {
        ScreenRenderer.Screen(
            cols: cols,
            rows: rows,
            cursorRow: row,
            cursorCol: col,
            cursorVisible: cursorVisible,
            cells: grid
        )
    }

    func feed(_ bytes: Data) {
        for byte in bytes { consume(byte) }
    }

    // MARK: byte dispatch

    private func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte < 0x20 || byte == 0x7F {
                utf8Remaining = 0
                control(byte)
            } else {
                decodeUTF8(byte)
            }
        case .escape:
            escape(byte)
        case .escapeIntermediate:
            // A charset designation or DECALN: one final byte, dropped.
            if controlInsideSequence(byte) { return }
            if byte >= 0x30 { state = .ground }
        case .csi:
            csi(byte)
        case .osc:
            if byte == 0x07 { state = .ground } else if byte == 0x1B { state = .oscEscape }
        case .oscEscape:
            state = byte == 0x5C ? .ground : .osc
        case .string:
            if byte == 0x1B { state = .stringEscape }
        case .stringEscape:
            state = byte == 0x5C ? .ground : .string
        }
    }

    /// Controls that arrive inside an ESC or CSI sequence still execute
    /// (xterm does this too). CAN and SUB abort the sequence; ESC restarts it.
    /// Returns true when the byte was a control.
    private func controlInsideSequence(_ byte: UInt8) -> Bool {
        guard byte < 0x20 || byte == 0x7F else { return false }
        switch byte {
        case 0x18, 0x1A: state = .ground
        case 0x1B: state = .escape
        default: control(byte)
        }
        return true
    }

    private func control(_ byte: UInt8) {
        switch byte {
        case 0x08: // BS
            col = max(0, col - 1)
            pendingWrap = false
        case 0x09: // HT
            col = min(cols - 1, (col / 8 + 1) * 8)
            pendingWrap = false
        case 0x0A, 0x0B, 0x0C: // LF VT FF
            lineFeed()
        case 0x0D: // CR
            col = 0
            pendingWrap = false
        case 0x1B:
            state = .escape
        default:
            break  // BEL, NUL, SO/SI, DEL: dropped
        }
    }

    private func decodeUTF8(_ byte: UInt8) {
        if utf8Remaining > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Pending = (utf8Pending << 6) | UInt32(byte & 0x3F)
                utf8Remaining -= 1
                if utf8Remaining == 0 { print(scalar: utf8Pending) }
                return
            }
            // A truncated sequence: emit a replacement, then treat this byte
            // as a fresh start.
            utf8Remaining = 0
            print(scalar: 0xFFFD)
        }
        switch byte {
        case 0x00...0x7F:
            print(scalar: UInt32(byte))
        case 0xC2...0xDF:
            utf8Pending = UInt32(byte & 0x1F)
            utf8Remaining = 1
        case 0xE0...0xEF:
            utf8Pending = UInt32(byte & 0x0F)
            utf8Remaining = 2
        case 0xF0...0xF4:
            utf8Pending = UInt32(byte & 0x07)
            utf8Remaining = 3
        default:
            print(scalar: 0xFFFD)
        }
    }

    // MARK: printing

    private func print(scalar value: UInt32) {
        guard let scalar = Unicode.Scalar(value) else { return print(scalar: 0xFFFD) }
        // A one-column grid cannot hold a wide character's second half.
        let width = cols >= 2 ? CharWidth.width(scalar) : min(1, CharWidth.width(scalar))
        if width == 0 {
            // Attach to the cell before the cursor (the cell just written).
            let target = pendingWrap ? cols - 1 : col - 1
            if target >= 0 {
                var cell = grid[row][target]
                if cell.continuation, target > 0 {
                    grid[row][target - 1].text.unicodeScalars.append(scalar)
                } else if cell.text != " " {
                    cell.text.unicodeScalars.append(scalar)
                    grid[row][target] = cell
                }
            }
            return
        }
        if pendingWrap {
            if autowrap {
                col = 0
                lineFeed()
            }
            pendingWrap = false
        }
        if width == 2, col == cols - 1 {
            // No room for the second half: wrap first (xterm), or overwrite
            // the last column with a blank when wrapping is off.
            if autowrap {
                put(.blank, at: col)
                col = 0
                lineFeed()
            } else {
                put(.blank, at: col)
                pendingWrap = true
                return
            }
        }
        var cell = attrs
        // A no-break space is a space to a reader: Claude Code prints one
        // after its `❯`, and a foreman matching "❯ " must not miss it.
        cell.text = scalar.value == 0xA0 ? " " : String(scalar)
        put(cell, at: col)
        if width == 2 {
            var half = attrs
            half.continuation = true
            put(half, at: col + 1)
        }
        col += width
        if col >= cols {
            col = cols - 1
            pendingWrap = true
        }
    }

    /// Write one cell, keeping a wide character whole: overwriting either
    /// half blanks the other.
    private func put(_ cell: Cell, at column: Int) {
        let existing = grid[row][column]
        if existing.continuation, column > 0 {
            grid[row][column - 1] = .blank
        }
        if column + 1 < cols, grid[row][column + 1].continuation, !cell.continuation {
            grid[row][column + 1] = .blank
        }
        grid[row][column] = cell
    }

    private func lineFeed() {
        pendingWrap = false
        if row == scrollBottom {
            scrollUp(1)
        } else if row < rows - 1 {
            row += 1
        }
    }

    private func reverseIndex() {
        pendingWrap = false
        if row == scrollTop {
            scrollDown(1)
        } else if row > 0 {
            row -= 1
        }
    }

    private func scrollUp(_ n: Int) {
        let n = min(max(1, n), scrollBottom - scrollTop + 1)
        grid.removeSubrange(scrollTop..<(scrollTop + n))
        grid.insert(contentsOf: blankRows(n), at: scrollBottom - n + 1)
    }

    private func scrollDown(_ n: Int) {
        let n = min(max(1, n), scrollBottom - scrollTop + 1)
        grid.removeSubrange((scrollBottom - n + 1)...scrollBottom)
        grid.insert(contentsOf: blankRows(n), at: scrollTop)
    }

    private func blankRows(_ n: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: .blank, count: cols), count: n)
    }

    // MARK: ESC

    private func escape(_ byte: UInt8) {
        if controlInsideSequence(byte) { return }
        state = .ground
        switch byte {
        case 0x5B: // [
            csiBytes.removeAll(keepingCapacity: true)
            state = .csi
        case 0x5D: // ]
            state = .osc
        case 0x50, 0x58, 0x5E, 0x5F: // P X ^ _
            state = .string
        case 0x37: // 7
            saveCursor()
        case 0x38: // 8
            restoreCursor()
        case 0x44: // D
            lineFeed()
        case 0x45: // E
            col = 0
            lineFeed()
        case 0x4D: // M
            reverseIndex()
        case 0x63: // c
            reset()
        case 0x20...0x2F:
            // ( ) * + - . / # and SP: one more byte follows.
            state = .escapeIntermediate
        default:
            break  // = > < ~ } | N O and the rest: dropped
        }
    }

    private func saveCursor() {
        saved = (row, col, attrs)
        pendingWrap = false
    }

    private func restoreCursor() {
        pendingWrap = false
        guard let saved else {
            row = 0
            col = 0
            return
        }
        row = min(saved.row, rows - 1)
        col = min(saved.col, cols - 1)
        attrs = saved.attrs
    }

    private func reset() {
        grid = blankRows(rows)
        savedGrid = nil
        row = 0
        col = 0
        pendingWrap = false
        cursorVisible = true
        autowrap = true
        scrollTop = 0
        scrollBottom = rows - 1
        attrs = Cell()
        saved = nil
    }

    // MARK: CSI

    private func csi(_ byte: UInt8) {
        if controlInsideSequence(byte) { return }
        switch byte {
        case 0x20...0x3F:
            // Parameters and intermediates. A runaway sequence keeps its
            // first 64 bytes and drops the rest; it still ends at its final
            // byte, so its parameters never print as text.
            if csiBytes.count < 64 { csiBytes.append(byte) }
        case 0x40...0x7E:
            state = .ground
            dispatchCSI(final: byte)
        default:
            state = .ground
        }
    }

    private struct CSIParams {
        var privateMarker: UInt8?
        var intermediate: UInt8?
        /// Each `;`-separated parameter's leading integer; nil when empty.
        var values: [Int?]
        /// Which parameters carried `:` sub-parameters (the colon SGR form).
        var hasSubparams: [Bool]

        func value(_ index: Int, default fallback: Int) -> Int {
            guard index < values.count, let v = values[index] else { return fallback }
            return v
        }
    }

    private func parseParams() -> CSIParams {
        var params = CSIParams(values: [], hasSubparams: [])
        var bytes = csiBytes[...]
        if let first = bytes.first, (0x3C...0x3F).contains(first) {
            params.privateMarker = first
            bytes = bytes.dropFirst()
        }
        if let last = bytes.last, (0x20...0x2F).contains(last) {
            params.intermediate = last
            bytes = bytes.dropLast()
        }
        var current: Int?
        var inSub = false
        var sub = false
        for b in bytes {
            switch b {
            case 0x30...0x39:
                if !inSub {
                    let digit = Int(b - 0x30)
                    current = min((current ?? 0) * 10 + digit, 65535)
                }
            case 0x3A:  // :
                inSub = true
                sub = true
            case 0x3B:  // ;
                params.values.append(current)
                params.hasSubparams.append(sub)
                current = nil
                inSub = false
                sub = false
            default:
                break  // an intermediate in the middle: ignored
            }
        }
        params.values.append(current)
        params.hasSubparams.append(sub)
        return params
    }

    private func dispatchCSI(final: UInt8) {
        let p = parseParams()
        if p.intermediate != nil {
            // `ESC[>0q`, `ESC[ q` and the like: queries and cursor shapes.
            return
        }
        if let marker = p.privateMarker {
            if marker == 0x3F { privateMode(p, set: final == 0x68, final: final) }
            return
        }
        let n = max(1, p.value(0, default: 1))
        switch final {
        case 0x41: // A up
            moveRow(by: -n)
        case 0x42, 0x65: // B e down
            moveRow(by: n)
        case 0x43, 0x61: // C a right
            col = min(cols - 1, col + n)
            pendingWrap = false
        case 0x44: // D left
            col = max(0, col - n)
            pendingWrap = false
        case 0x45: // E next line
            moveRow(by: n)
            col = 0
        case 0x46: // F previous line
            moveRow(by: -n)
            col = 0
        case 0x47, 0x60: // G ` column
            col = min(cols - 1, n - 1)
            pendingWrap = false
        case 0x48, 0x66: // H f position
            row = min(rows - 1, n - 1)
            col = min(cols - 1, max(1, p.value(1, default: 1)) - 1)
            pendingWrap = false
        case 0x64: // d row
            row = min(rows - 1, n - 1)
            pendingWrap = false
        case 0x49: // I forward tab
            for _ in 0..<n { control(0x09) }
        case 0x5A: // Z back tab
            for _ in 0..<n { col = max(0, (col - 1) / 8 * 8) }
            pendingWrap = false
        case 0x4A: // J erase in display
            eraseInDisplay(p.value(0, default: 0))
        case 0x4B: // K erase in line
            eraseInLine(p.value(0, default: 0))
        case 0x4C: // L insert lines
            insertLines(n)
        case 0x4D: // M delete lines
            deleteLines(n)
        case 0x40: // @ insert chars
            let n = min(n, cols - col)
            grid[row].removeSubrange((cols - n)..<cols)
            grid[row].insert(contentsOf: Array(repeating: .blank, count: n), at: col)
            pendingWrap = false
        case 0x50: // P delete chars
            let n = min(n, cols - col)
            grid[row].removeSubrange(col..<(col + n))
            grid[row].append(contentsOf: Array(repeating: .blank, count: n))
            pendingWrap = false
        case 0x58: // X erase chars
            for c in col..<min(cols, col + n) { grid[row][c] = .blank }
            pendingWrap = false
        case 0x53: // S scroll up
            scrollUp(n)
        case 0x54: // T scroll down
            scrollDown(n)
        case 0x72: // r scroll region
            let top = max(1, p.value(0, default: 1)) - 1
            let bottom = min(rows, p.value(1, default: rows)) - 1
            if top < bottom {
                scrollTop = top
                scrollBottom = bottom
            } else {
                scrollTop = 0
                scrollBottom = rows - 1
            }
            row = 0
            col = 0
            pendingWrap = false
        case 0x73: // s
            saveCursor()
        case 0x75: // u
            restoreCursor()
        case 0x6D: // m
            sgr(p)
        default:
            break  // h l n t c q and the rest: dropped
        }
    }

    /// A relative move stops at the scroll region's edge when the cursor
    /// starts inside it, and at the screen's edge otherwise.
    private func moveRow(by delta: Int) {
        let top = row >= scrollTop ? scrollTop : 0
        let bottom = row <= scrollBottom ? scrollBottom : rows - 1
        row = min(bottom, max(top, row + delta))
        pendingWrap = false
    }

    private func eraseInDisplay(_ mode: Int) {
        pendingWrap = false
        switch mode {
        case 0:
            eraseInLine(0)
            for r in (row + 1)..<max(row + 1, rows) { grid[r] = blankRows(1)[0] }
        case 1:
            eraseInLine(1)
            for r in 0..<row { grid[r] = blankRows(1)[0] }
        case 2, 3:
            grid = blankRows(rows)
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        pendingWrap = false
        switch mode {
        case 0:
            for c in col..<cols { grid[row][c] = .blank }
        case 1:
            for c in 0...min(col, cols - 1) { grid[row][c] = .blank }
        case 2:
            grid[row] = blankRows(1)[0]
        default:
            break
        }
    }

    private func insertLines(_ n: Int) {
        guard row >= scrollTop, row <= scrollBottom else { return }
        let n = min(n, scrollBottom - row + 1)
        grid.removeSubrange((scrollBottom - n + 1)...scrollBottom)
        grid.insert(contentsOf: blankRows(n), at: row)
        col = 0
        pendingWrap = false
    }

    private func deleteLines(_ n: Int) {
        guard row >= scrollTop, row <= scrollBottom else { return }
        let n = min(n, scrollBottom - row + 1)
        grid.removeSubrange(row..<(row + n))
        grid.insert(contentsOf: blankRows(n), at: scrollBottom - n + 1)
        col = 0
        pendingWrap = false
    }

    private func privateMode(_ p: CSIParams, set: Bool, final: UInt8) {
        guard final == 0x68 || final == 0x6C else { return }  // h / l only
        for value in p.values {
            switch value {
            case 7:
                autowrap = set
            case 25:
                cursorVisible = set
            case 47, 1047:
                switchScreen(alternate: set, clear: false)
            case 1048:
                if set { saveCursor() } else { restoreCursor() }
            case 1049:
                if set {
                    saveCursor()
                    switchScreen(alternate: true, clear: true)
                } else {
                    switchScreen(alternate: false, clear: false)
                    restoreCursor()
                }
            default:
                break  // 1, 12, 1000-1006, 2004, 2031, and the rest: dropped
            }
        }
    }

    private func switchScreen(alternate: Bool, clear: Bool) {
        if alternate {
            guard savedGrid == nil else { return }
            savedGrid = grid
            if clear { grid = blankRows(rows) }
        } else {
            guard let main = savedGrid else { return }
            grid = main
            savedGrid = nil
        }
        pendingWrap = false
    }

    private func sgr(_ p: CSIParams) {
        var i = 0
        while i < p.values.count {
            defer { i += 1 }
            let value = p.values[i] ?? 0
            switch value {
            case 0:
                attrs = Cell()
            case 2:
                attrs.dim = true
            case 7:
                attrs.inverse = true
            case 22:
                attrs.dim = false
            case 27:
                attrs.inverse = false
            case 38, 48, 58:
                // An extended colour. The colon form is one parameter and
                // already consumed; the semicolon form spends 1 (256-colour)
                // or 3 (truecolour) more.
                if p.hasSubparams[i] { continue }
                if i + 1 < p.values.count {
                    switch p.values[i + 1] {
                    case 5: i += 2
                    case 2: i += 4
                    default: break
                    }
                }
            default:
                break  // colours, underline, blink, italic: dropped
            }
        }
    }
}
