import Foundation

/// When a session's own work changes its repository's pull requests, the
/// daemon reads them at once instead of at the next interval
/// (`sessions-workflow` round 8, option 2 of `corpus/03-faster-pull-sync.md`).
/// Two pure matchers decide what counts, and `PullNudger` carries a match
/// to `PullRequestStatus.nudge` off the event loop.
public enum PullNudge {
    /// The `gh pr` subcommands that change a pull request's state or list.
    public static let pullSubcommands: Set<String> = ["create", "merge", "ready", "close", "edit", "review"]

    /// True when a shell command line pushes or changes a pull request:
    /// `git push …` or `gh pr create|merge|ready|close|edit|review …` as a
    /// command of the line, so `git commit -m x && git push` matches and
    /// `echo gh pr create` or `git pushd` does not. The line is split into
    /// commands on `&&`, `||`, `;` and `|` and into words on blanks, a
    /// single or double quote keeping what it encloses together; each
    /// command's leading `VAR=value` words are skipped, and the first words
    /// are compared whole.
    public static func commandNudges(line: String) -> Bool {
        for command in commands(of: line) {
            var words = command[...]
            while let first = words.first, isAssignment(first) { words = words.dropFirst() }
            guard let first = words.first else { continue }
            switch first {
            case "git":
                if words.dropFirst().first == "push" { return true }
            case "gh":
                let rest = words.dropFirst()
                if rest.first == "pr", let sub = rest.dropFirst().first, pullSubcommands.contains(sub) { return true }
            default:
                continue
            }
        }
        return false
    }

    /// The commands of a line, each as its words; a separator or a blank
    /// inside quotes splits nothing. Not a shell: no escapes, no subshells,
    /// no expansion.
    static func commands(of line: String) -> [[String]] {
        var commands: [[String]] = [], words: [String] = [], word = ""
        var quote: Character?
        func endWord() {
            if !word.isEmpty { words.append(word) }
            word = ""
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "&" || character == "|" || character == ";" {
                endCommand()
            } else if character == " " || character == "\t" {
                endWord()
            } else {
                word.append(character)
            }
        }
        endCommand()
        return commands
    }

    /// True when a crew note's first line starts with `PROGRESS ` or
    /// `DONE `, the two kinds of `docs/foreman.md`'s protocol that follow a
    /// push.
    public static func noteNudges(message: String) -> Bool {
        let first = message.prefix { $0 != "\n" && $0 != "\r" }
        return first.hasPrefix("PROGRESS ") || first.hasPrefix("DONE ")
    }

    /// `VAR=value`, an environment word before a command.
    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let head = name.first, head.isLetter || head == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// Carries a command's end or a note from a session to a nudge of its
/// repository. The matcher runs where the event lands (the event loop for a
/// command, the handler for a note: a string scan); the rest runs on
/// `RemoteOrigins.queue`, where the session's project is resolved when it
/// is not cached yet and the `origin` remote is read, and the read itself
/// on `PullRequestStatus.queue`. A session outside every project, or in one
/// with no GitHub remote, nudges nothing.
public final class PullNudger: @unchecked Sendable {
    private let status: PullRequestStatus
    private let origins: RemoteOrigins

    public init(status: PullRequestStatus, origins: RemoteOrigins) {
        self.status = status
        self.origins = origins
    }

    /// A command ended in `session`; one with no known command line nudges
    /// nothing.
    public func commandEnded(in session: PtySession, command: SessionCommand) {
        guard let line = command.command, PullNudge.commandNudges(line: line) else { return }
        nudge(session: session)
    }

    /// `session` posted a note on `POST /api/sessions/<id>/events`.
    public func noted(in session: PtySession, message: String) {
        guard PullNudge.noteNudges(message: message) else { return }
        nudge(session: session)
    }

    private func nudge(session: PtySession) {
        RemoteOrigins.queue.async { [status, origins] in
            let project = session.project ?? session.project(forCwd: session.liveCwd)
            guard let root = project?.root,
                  let base = origins.pullRequestBase(root: root),
                  let repository = PullRequestStatus.repository(pullRequestBase: base)
            else { return }
            status.nudge(repository: repository)
        }
    }
}
