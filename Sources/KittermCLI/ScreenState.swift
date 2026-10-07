import Foundation

/// Pure rules over a rendered screen (`read_screen`'s `lines` and `cursor`)
/// plus the session's `foregroundProgram`, answering what a crew pane shows
/// — issue #171's eight states, with no I/O and no invented probability.
///
/// Check order, and why: a dialog can sit over a screen that otherwise looks
/// like a normal prompt — `trust-dialog-1` and the permission-dialog
/// fixtures both put "❯" on an unrelated row as a menu marker, not the
/// input box — so the two dialogs are checked first. A turn in progress
/// leaves the prompt row itself looking exactly like an empty prompt
/// (`working-1`, `working-2`, and `waiting-on-own-job-1` all show a bare
/// "❯" at the cursor), so `working` and `waiting-on-own-job` are checked
/// next, before anything looks at the cursor row. `agent-exited` is checked
/// before the prompt states, not after: many shells (Starship,
/// Powerlevel10k, pure) draw their own prompt with "❯", so once `claude`
/// has exited a shell's own prompt can look exactly like an empty Claude
/// Code prompt, and a foreman reading it as `prompt-empty` would type into
/// a bare shell. `agent-exited` needs no screen marker, only the absence of
/// `claude` from `foregroundProgram`, so it answers as soon as no dialog or
/// working marker matched; the prompt states run last, once the program is
/// known to be `claude`, and `unknown` is the final fallback.
enum ScreenState {
    enum Value: String, Equatable {
        case promptEmpty = "prompt-empty"
        case promptHasText = "prompt-has-text"
        case working
        case waitingOnOwnJob = "waiting-on-own-job"
        case trustDialog = "trust-dialog"
        case permissionDialog = "permission-dialog"
        case agentExited = "agent-exited"
        case unknown
    }

    /// The row a rule matched: `index` is the position in `lines`.
    struct Line: Equatable {
        let index: Int
        let text: String
    }

    struct Cursor: Equatable {
        let row: Int
        let col: Int
        let visible: Bool
    }

    struct Result: Equatable {
        let state: Value
        /// Names the rule that matched, for a foreman reading the answer and
        /// for a test pinning it. `"unknown: no rule matched"` when nothing did.
        let rule: String
        let line: Line?
    }

    static func evaluate(lines: [String], cursor: Cursor, foregroundProgram: String?) -> Result {
        if let hit = firstMatch(dialogRules, in: lines) {
            return Result(state: hit.rule.state, rule: hit.rule.name, line: hit.line)
        }
        if let hit = firstMatch(workingRules, in: lines) {
            return Result(state: hit.rule.state, rule: hit.rule.name, line: hit.line)
        }
        if let hit = firstMatch(ownJobRules, in: lines) {
            return Result(state: hit.rule.state, rule: hit.rule.name, line: hit.line)
        }
        if !programIsClaude(foregroundProgram) {
            let line = lines.indices.contains(cursor.row) ? Line(index: cursor.row, text: lines[cursor.row]) : nil
            return Result(state: .agentExited, rule: Self.agentExitedRuleName, line: line)
        }
        if let result = promptResult(lines: lines, cursor: cursor) {
            return result
        }
        return Result(state: .unknown, rule: "unknown: no rule matched", line: nil)
    }

    // MARK: - dialogs, working, waiting-on-own-job

    private struct Rule: Sendable {
        let state: Value
        let name: String
        let test: @Sendable (String) -> Bool
    }

    /// `trust-dialog-1`: "No, exit" sits selected above "Yes, I trust this
    /// folder", so the match is the trust sentence, not the selection.
    private static let dialogRules: [Rule] = [
        Rule(
            state: .trustDialog,
            name: "trust-dialog: \"Yes, I trust this folder\"",
            test: { $0.contains("Yes, I trust this folder") }
        ),
        Rule(
            state: .permissionDialog,
            name: "permission-dialog: \"Do you want to proceed\"",
            test: { $0.contains("Do you want to proceed") }
        ),
    ]

    /// `working-1` and `working-2`: Claude Code 2.1.292 never printed "esc to
    /// interrupt" (round 1's reflection), so a turn in progress is read from
    /// its own two shapes instead — a spinner line ("Boogieing… (7s · ↓ 186
    /// tokens)", "Churning… (2s · thinking)") and a `⏺` tool call still
    /// counting ("Waiting for 6 seconds · 4s"). Both carry a live elapsed
    /// count; a finished line reads "done" or ends in a period instead.
    private static let workingRules: [Rule] = [
        Rule(
            state: .working,
            name: "working: a spinner line, an elapsed count after \"…\"",
            test: { matches(spinnerPattern, $0) }
        ),
        Rule(
            state: .working,
            name: "working: a \"⏺\" tool call still counting",
            test: { matches(pendingToolCallPattern, $0) }
        ),
    ]

    /// `waiting-on-own-job-1`: the status bar prints "· 1 shell · ← 2
    /// agents" once a background job outlives the turn. The same screen's
    /// scrollback also carries "· done 12:54 PM · 1 shell still running" —
    /// and so does `unknown-1`, `unknown-2`, and `permission-dialog-1`,
    /// none of which are waiting on their own job — so the rule requires a
    /// "·" on both sides of the count, the status bar's own shape, not the
    /// looser "shell still running" sentence that a finished turn leaves
    /// behind in scrollback.
    private static let ownJobRules: [Rule] = [
        Rule(
            state: .waitingOnOwnJob,
            name: "waiting-on-own-job: the shell count in the status bar",
            test: { matches(ownJobPattern, $0) }
        ),
    ]

    private static func firstMatch(_ rules: [Rule], in lines: [String]) -> (rule: Rule, line: Line)? {
        for (index, text) in lines.enumerated() {
            for rule in rules where rule.test(text) {
                return (rule, Line(index: index, text: text))
            }
        }
        return nil
    }

    private static let spinnerPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "…\\s?\\(\\d+s")
    }()
    private static let pendingToolCallPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^⏺\\s.*\\d+s$")
    }()
    private static let ownJobPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "·\\s*\\d+\\s+shells?\\s*·")
    }()

    private static func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
        let whole = NSRange(line.startIndex..., in: line)
        return pattern.firstMatch(in: line, range: whole) != nil
    }

    // MARK: - the prompt states

    /// `prompt-empty-1` and `prompt-has-text-1`: issue #171 names the marker
    /// as "❯ on the cursor row", so only the cursor's own row counts — a "❯"
    /// elsewhere is a dialog's selection arrow or an earlier turn's own
    /// message, both already resolved above. A `{dim}…{/dim}` run filling
    /// the whole remainder is Claude Code's ghost suggestion, not typed
    /// text, and reads as empty, as `read_screen`'s own styling intends.
    private static func promptResult(lines: [String], cursor: Cursor) -> Result? {
        guard lines.indices.contains(cursor.row), let remainder = promptRemainder(of: lines[cursor.row]) else {
            return nil
        }
        let line = Line(index: cursor.row, text: lines[cursor.row])
        if remainder.isEmpty || isDimPlaceholder(remainder) {
            return Result(
                state: .promptEmpty,
                rule: "prompt-empty: \"❯\" at the cursor, empty or a dim placeholder",
                line: line
            )
        }
        return Result(
            state: .promptHasText,
            rule: "prompt-has-text: \"❯\" at the cursor with typed text",
            line: line
        )
    }

    /// Nil when the row is not a prompt row at all (no leading "❯"); the
    /// text after "❯" and the one space that follows it otherwise, which is
    /// empty for a bare "❯".
    private static func promptRemainder(of line: String) -> String? {
        guard line.hasPrefix("❯") else { return nil }
        var rest = line.dropFirst()
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return String(rest)
    }

    private static func isDimPlaceholder(_ remainder: String) -> Bool {
        remainder.hasPrefix("{dim}") && remainder.hasSuffix("{/dim}")
    }

    // MARK: - agent-exited

    private static let agentExitedRuleName = "agent-exited: no claude in foregroundProgram"

    private static func programIsClaude(_ foregroundProgram: String?) -> Bool {
        guard let foregroundProgram else { return false }
        return foregroundProgram.lowercased().contains("claude")
    }
}
