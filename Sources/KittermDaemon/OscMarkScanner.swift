import Foundation
import KittermProtocol

/// Finds shell-integration marks in the raw PTY stream.
///
/// Marks used to be reported by the browser: xterm parsed OSC 133/633 and sent
/// them back over the wire. That made every mark-derived feature — the fleet
/// view's state, `lastExit`, `/api/sessions/<id>/commands` and its output
/// ranges — conditional on a human having the session open in a tab. A session
/// driven by an orchestrator recorded nothing at all.
///
/// So the daemon reads them itself. **This is a deliberate, bounded amendment
/// to the "daemon never parses ANSI" rule**: the daemon still does not emulate
/// a terminal — no grid, no cursor, no CSI or SGR handling, no character sets,
/// no idea what the screen looks like. It matches two OSC ids and their
/// terminators, and nothing else. Screen state remains entirely the client's
/// business.
///
/// Not a trust boundary: marks have always been asserted by whatever runs in
/// the shell, and the browser believed them just as readily. Reading them here
/// changes who parses, not who is trusted.
///
/// Loop-confined — only `PtySession.handleRead` feeds it, always on the daemon's
/// single event-loop thread, so it needs no lock.
struct OscMarkScanner {
    /// A mark and where it belongs in the session log.
    struct Hit {
        let offset: UInt64
        let kind: MarkKind
        let exit: Int32?
        let command: String?
    }

    /// Bounded so a program emitting `ESC ] 133 ;` and then megabytes without a
    /// terminator cannot grow this without limit. Comfortably above the 2 KiB
    /// command line a 633;E may carry.
    private static let maxPayloadBytes = 4096

    private enum State {
        case idle
        /// Saw `ESC`, waiting to see whether `]` follows.
        case escape
        /// Inside `ESC ] … `, collecting the payload.
        case payload
        /// Saw `ESC` inside a payload — `\` makes it the ST terminator.
        case payloadEscape
    }

    private var state: State = .idle
    private var payload: [UInt8] = []
    /// Absolute log offset of the `ESC` that opened the current sequence, kept
    /// across chunk boundaries so a split sequence still reports truthfully.
    private var sequenceStart: UInt64 = 0
    /// Overflowed the cap; swallow bytes until the terminator, then drop.
    private var overflowed = false
    /// Absolute offset of an `ESC` seen inside a payload. If it turns out not to
    /// be the start of ST, it is itself a fresh escape — kept across chunks so a
    /// sequence that begins right after a malformed one is still found.
    private var payloadEscapeAt: UInt64 = 0
    /// A 633;E command line waiting for the next `preExec` mark, mirroring the
    /// client: the text is attached to the mark that starts the command rather
    /// than reported on its own.
    private var pendingCommand: String?

    /// Scan a chunk of PTY output. `baseOffset` is the absolute log offset the
    /// chunk's first byte will occupy.
    ///
    /// Only the bytes after an `ESC` are examined at all: the fast path is one
    /// `memchr` per chunk, so a flood carrying no escape sequences costs a
    /// single vectorised scan rather than a per-byte loop.
    mutating func scan(_ chunk: Data, baseOffset: UInt64) -> [Hit] {
        guard !chunk.isEmpty else { return [] }
        var hits: [Hit] = []

        chunk.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = raw.count
            var i = 0

            while i < count {
                switch state {
                case .idle:
                    // Jump straight to the next escape byte; everything before
                    // it is ordinary output we have no interest in.
                    guard let found = memchr(bytes + i, 0x1B, count - i) else {
                        i = count
                        continue
                    }
                    let index = UnsafeRawPointer(found)
                        .assumingMemoryBound(to: UInt8.self) - bytes
                    sequenceStart = baseOffset + UInt64(index)
                    state = .escape
                    i = index + 1

                case .escape:
                    if bytes[i] == 0x5D {  // ']' — an OSC is opening
                        state = .payload
                        payload.removeAll(keepingCapacity: true)
                        overflowed = false
                        i += 1
                    } else if bytes[i] == 0x1B {
                        // Another escape; treat this one as the opener instead.
                        sequenceStart = baseOffset + UInt64(i)
                        i += 1
                    } else {
                        state = .idle
                        i += 1
                    }

                case .payload:
                    let byte = bytes[i]
                    if byte == 0x07 {  // BEL terminator
                        finish(at: baseOffset + UInt64(i) + 1, into: &hits)
                        i += 1
                    } else if byte == 0x1B {
                        payloadEscapeAt = baseOffset + UInt64(i)
                        state = .payloadEscape
                        i += 1
                    } else {
                        if payload.count < Self.maxPayloadBytes {
                            payload.append(byte)
                        } else {
                            overflowed = true
                        }
                        i += 1
                    }

                case .payloadEscape:
                    if bytes[i] == 0x5C {  // ST terminator: ESC \
                        finish(at: baseOffset + UInt64(i) + 1, into: &hits)
                        i += 1
                    } else {
                        // Not ST, so the sequence is malformed and ends here.
                        // The `ESC` we consumed is itself a fresh escape, so
                        // hand this byte to the `.escape` case rather than
                        // eating it — otherwise a well-formed sequence starting
                        // immediately after a broken one is lost.
                        reset()
                        sequenceStart = payloadEscapeAt
                        state = .escape
                    }
                }
            }
        }
        return hits
    }

    private mutating func reset() {
        state = .idle
        payload.removeAll(keepingCapacity: true)
        overflowed = false
    }

    /// `sequenceEnd` is the offset just past the terminator.
    private mutating func finish(at sequenceEnd: UInt64, into hits: inout [Hit]) {
        defer { reset() }
        guard !overflowed, !payload.isEmpty else { return }
        guard let text = String(bytes: payload, encoding: .utf8) else { return }

        // `<id>;<params>` — anything else is not a sequence we index.
        guard let separator = text.firstIndex(of: ";") else { return }
        let id = String(text[text.startIndex..<separator])
        let params = String(text[text.index(after: separator)...])
        guard id == "133" || id == "633" else { return }

        if id == "633", params.hasPrefix("E") {
            pendingCommand = Self.commandLine(fromOsc633: params)
            return
        }

        guard let parsed = Self.mark(fromParams: params) else { return }

        // A command's output starts after the sequence that announced it and
        // ends where the sequence closing it begins, so the two kinds anchor to
        // opposite ends. That keeps `/commands/<n>/output` ranges tight —
        // better than the client's old receive-side count, which could
        // overshoot by a whole frame.
        let offset = parsed.kind == .commandEnd ? sequenceStart : sequenceEnd

        var command: String?
        if parsed.kind == .preExec, let pending = pendingCommand {
            pendingCommand = nil
            // Oversized text is dropped rather than losing the mark with it.
            if pending.utf8.count <= KittermConstants.maxMarkCommandBytes {
                command = pending
            }
        }
        hits.append(Hit(offset: offset, kind: parsed.kind, exit: parsed.exit, command: command))
    }

    // MARK: - Payload parsing
    //
    // Deliberately mirrors `Web/terminal/src/command-marks.ts`; the test suite
    // runs that file's own corpus against this implementation so the two cannot
    // drift on what counts as a mark.

    static func mark(fromParams params: String) -> (kind: MarkKind, exit: Int32?)? {
        let fields = params.split(separator: ";", omittingEmptySubsequences: false)
        guard let letter = fields.first else { return nil }
        let kind: MarkKind
        switch letter {
        case "A": kind = .promptStart
        case "B": kind = .commandStart
        case "C": kind = .preExec
        case "D": kind = .commandEnd
        default: return nil
        }
        var exit: Int32?
        if kind == .commandEnd, fields.count > 1, !fields[1].isEmpty {
            exit = Int32(fields[1])
        }
        return (kind, exit)
    }

    /// `E;<cmdline>[;<nonce>]`. The nonce authenticates the report against
    /// spoofing by command output; we drop it and keep the text.
    static func commandLine(fromOsc633 params: String) -> String? {
        guard let separator = params.firstIndex(of: ";") else { return nil }
        let rest = String(params[params.index(after: separator)...])
        let raw: String
        if let nonce = rest.lastIndex(of: ";") {
            raw = String(rest[rest.startIndex..<nonce])
        } else {
            raw = rest
        }
        let command = unescape633(raw)
        return command.isEmpty ? nil : command
    }

    /// Undo 633;E's encoding: `\\` for a literal backslash, `\xAB` hex pairs.
    static func unescape633(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "\\" else {
                out.append(value[index])
                index = value.index(after: index)
                continue
            }
            let afterSlash = value.index(after: index)
            guard afterSlash < value.endIndex else {
                out.append("\\")
                break
            }
            if value[afterSlash] == "\\" {
                out.append("\\")
                index = value.index(after: afterSlash)
                continue
            }
            if value[afterSlash] == "x" {
                let hexStart = value.index(after: afterSlash)
                if let hexEnd = value.index(hexStart, offsetBy: 2, limitedBy: value.endIndex),
                   let code = UInt8(value[hexStart..<hexEnd], radix: 16),
                   let scalar = Unicode.Scalar(UInt32(code)) {
                    out.append(Character(scalar))
                    index = hexEnd
                    continue
                }
            }
            out.append(value[index])
            index = afterSlash
        }
        return out
    }
}
