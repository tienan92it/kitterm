/// How many cells a scalar occupies on a terminal grid: 0, 1, or 2.
///
/// An approximation, not a Unicode width table. It agrees with xterm.js on
/// what a coding agent's TUI prints: box drawing and block elements are
/// narrow, CJK and emoji-presentation scalars are wide, and combining marks,
/// ZWJ, and variation selectors attach to the cell before them.
enum CharWidth {
    static func width(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x20 || v == 0x7f { return 0 }
        if v < 0x300 { return 1 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }
        // Hangul jamo medial vowels and final consonants compose into the
        // syllable before them.
        if (0x1160...0x11FF).contains(v) || v == 0x200B { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }
        for range in wideRanges where range.contains(v) { return 2 }
        return 1
    }

    /// East Asian Wide and Fullwidth blocks.
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,
        0x2E80...0x303E,
        0x3041...0x33FF,
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xA000...0xA4CF,
        0xAC00...0xD7A3,
        0xF900...0xFAFF,
        0xFE30...0xFE4F,
        0xFF00...0xFF60,
        0xFFE0...0xFFE6,
        0x20000...0x2FFFD,
        0x30000...0x3FFFD,
    ]
}
