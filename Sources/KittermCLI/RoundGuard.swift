import Foundation
import KittermDaemon

/// `kitterm round guard` — the `PreToolUse` hook of a crew session
/// (`examples/foreman/crew-settings.json`). It refuses what a permission
/// rule cannot match by prefix: a `git push` to the base branch or with
/// force, and `kitterm start|stop|restart` run by a path or by `swift run`.
/// It reads past the keywords of a compound command (`then`, `do`, `{`,
/// `!`), a wrapper (`timeout`, `sudo`, `nohup`, `env`, `xargs`, ...), the
/// global options of `git`, a substitution, the string of `sh -c` and
/// `eval`, and a here-document that a shell reads. A push whose destination
/// a substitution or an `xargs` builds is refused, because it cannot be
/// known. The base branch is `KnowledgeBase.baseBranch` in the command's
/// directory.
///
/// Input: the hook JSON on stdin (`tool_name`, `tool_input.command`,
/// `cwd`). Output: exit 0 to let the call run; exit 2 with the reason on
/// stderr to refuse it, which Claude Code shows to the model. Input it
/// cannot read is refused too, so a broken hook is loud, not open.
/// `--check` prints one line and exits 0, so the foreman can see at start
/// that the installed build has the guard.
enum RoundGuard {
    static let usage = "usage: kitterm round guard [--check]   (reads a Claude Code PreToolUse hook JSON on stdin)"

    /// Runs `git` with `args` in a directory and returns its trimmed stdout,
    /// or nil when git fails.
    typealias Git = @Sendable (_ args: [String], _ directory: String) -> String?

    /// The exit code. `input` reads stdin, and only the hook path calls it,
    /// so `--check` never waits on a terminal; `out` and `err` take the
    /// lines for stdout and stderr.
    static func run(
        _ args: [String], input: () -> Data, git: Git = defaultGit,
        out: (String) -> Void, err: (String) -> Void
    ) -> Int32 {
        if args == ["--check"] {
            out("kitterm round guard: ready")
            return 0
        }
        guard args.isEmpty else {
            err(usage)
            return 2
        }
        guard let object = try? JSONSerialization.jsonObject(with: input()) as? [String: Any],
              let tool = object["tool_name"] as? String
        else {
            err("kitterm round guard: cannot read the hook input (no tool_name); the call is refused")
            return 2
        }
        guard tool == "Bash" else { return 0 }
        guard let command = (object["tool_input"] as? [String: Any])?["command"] as? String,
              let cwd = object["cwd"] as? String
        else {
            err("kitterm round guard: the Bash hook input has no tool_input.command or cwd; the call is refused")
            return 2
        }
        if let reason = refusal(command: command, cwd: cwd, git: git) {
            err("kitterm round guard refused: \(reason). A crew session never does this; "
                + "post a BLOCKER note if the round needs it.")
            return 2
        }
        return 0
    }

    /// The reason to refuse `command` run in `cwd`, or nil.
    static func refusal(command: String, cwd: String, git: Git) -> String? {
        var directory = cwd
        for words in simpleCommands(command) {
            let (words, viaXargs) = stripPrefix(words)
            guard let program = words.first else { continue }
            let name = (program as NSString).lastPathComponent
            if name == "cd", words.count == 2 {
                directory = resolve(words[1], from: directory)
            } else if let script = shellScript(words) {
                if let reason = refusal(command: script, cwd: directory, git: git) { return reason }
            } else if name == "git", let reason = gitRefusal(Array(words.dropFirst()), viaXargs: viaXargs, directory: directory, git: git) {
                return reason
            } else if let reason = kittermRefusal(words, viaXargs: viaXargs) {
                return reason
            }
        }
        return nil
    }

    /// The shells whose `-c` string and here-document the guard reads as
    /// commands.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    /// The command line a simple command runs as a string: the word after a
    /// `-c` flag of a shell (`-c`, `-lc`, `-ec`), or the words of `eval`.
    private static func shellScript(_ words: [String]) -> String? {
        let name = (words[0] as NSString).lastPathComponent
        if name == "eval" { return words.dropFirst().joined(separator: " ") }
        guard shells.contains(name) else { return nil }
        var index = 1
        while index < words.count, words[index].hasPrefix("-") {
            if !words[index].hasPrefix("--"), words[index].dropFirst().contains("c") {
                return index + 1 < words.count ? words[index + 1] : nil
            }
            index += 1
        }
        return nil
    }

    // MARK: - git push

    /// The global options of `git` that take their value as the next word.
    private static let gitValuedOptions: Set<String> = [
        "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env",
    ]

    private static func gitRefusal(_ args: [String], viaXargs: Bool, directory: String, git: Git) -> String? {
        var directory = directory
        var index = 0
        // Global options before the subcommand; `-C`, `--git-dir` and
        // `--work-tree` move the directory the base is read in.
        while index < args.count, args[index].hasPrefix("-") {
            let option = args[index]
            if gitValuedOptions.contains(option), index + 1 < args.count {
                if ["-C", "--git-dir", "--work-tree"].contains(option) {
                    directory = resolve(args[index + 1], from: directory)
                }
                index += 2
            } else {
                index += 1
            }
        }
        guard index < args.count, args[index] == "push" else { return nil }
        if viaXargs {
            return "a push whose arguments xargs builds, so its destination cannot be known; write the push out"
        }
        var positional: [String] = []
        var rest = args[(index + 1)...].makeIterator()
        while let arg = rest.next() {
            if ["--force", "--mirror", "--force-if-includes"].contains(arg) || arg.hasPrefix("--force-with-lease") {
                return "a force push (\(arg))"
            }
            if arg == "--all" || arg == "--branches" {
                return "a push of every branch (\(arg)), the base branch with them"
            }
            if arg == "-o" || arg == "--push-option" || arg == "--repo" {
                _ = rest.next()
            } else if arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.dropFirst().contains("f") {
                return "a force push (\(arg))"
            } else if !arg.hasPrefix("-") {
                positional.append(arg)
            }
        }
        let refspecs = positional.dropFirst()
        if let forced = refspecs.first(where: { $0.hasPrefix("+") }) {
            return "a force push (\(forced))"
        }
        if let built = refspecs.first(where: { destination(of: $0).contains("$") || destination(of: $0).contains("`") }) {
            return "a push whose destination a substitution builds (\(built)), so it cannot be known; "
                + "write the branch name"
        }
        let base = baseBranch(in: directory, git: git)
        let current = git(["symbolic-ref", "--short", "HEAD"], directory)
        if refspecs.isEmpty {
            return current == base ? "a push from the base branch \(base)" : nil
        }
        for refspec in refspecs {
            var destination = destination(of: refspec)
            if destination == "HEAD" { destination = current ?? "HEAD" }
            if destination.hasPrefix("refs/heads/") { destination.removeFirst("refs/heads/".count) }
            if destination == base { return "a push to the base branch \(base) (\(refspec))" }
        }
        return nil
    }

    /// The part of a refspec after its last `:`, or the whole refspec.
    private static func destination(of refspec: String) -> String {
        refspec.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? refspec
    }

    /// The base branch by the rule `kitterm round open` uses.
    private static func baseBranch(in directory: String, git: Git) -> String {
        KnowledgeBase.baseBranch { git($0, directory) }
    }

    // MARK: - kitterm start, stop, restart

    private static let daemonVerbs: Set<String> = ["start", "stop", "restart"]

    /// `kitterm <verb>` by any path, and `swift run [options] kitterm <verb>`.
    private static func kittermRefusal(_ words: [String], viaXargs: Bool) -> String? {
        if viaXargs, words.count == 1, (words[0] as NSString).lastPathComponent == "kitterm" {
            return "kitterm with a verb xargs builds, so it cannot be known; write the command out"
        }
        var index = 0
        if words.first.map({ ($0 as NSString).lastPathComponent }) == "swift", words.count > 1, words[1] == "run" {
            guard let product = words.dropFirst(2).firstIndex(of: "kitterm") else { return nil }
            index = product
        }
        guard index + 1 < words.count,
              (words[index] as NSString).lastPathComponent == "kitterm",
              daemonVerbs.contains(words[index + 1])
        else { return nil }
        return "kitterm \(words[index + 1]), which acts on the human's daemon"
    }

    // MARK: - words

    /// The shell words that open a compound command and run the next word
    /// as a command.
    private static let keywords: Set<String> = ["if", "then", "elif", "else", "while", "until", "do", "{", "!"]

    /// The commands that run their arguments as a command, and the options
    /// of each that take the next word as their value.
    private static let wrappers: [String: Set<String>] = [
        "env": ["-u", "--unset", "-C", "--chdir"],
        "command": [],
        "exec": ["-a"],
        "time": [],
        "nohup": [],
        "nice": ["-n", "--adjustment"],
        "sudo": ["-u", "--user", "-g", "--group", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-R", "-T"],
        "timeout": ["-s", "--signal", "-k", "--kill-after"],
        "xargs": ["-n", "-I", "-i", "-L", "-P", "-d", "-E", "-s", "-a", "--max-args", "--max-procs", "--delimiter", "--arg-file"],
    ]

    /// Drop what runs before the command itself: `VAR=value` words, the
    /// keywords of a compound command, and each wrapper with its options
    /// (and `timeout`'s duration). `viaXargs` says an `xargs` adds words
    /// the guard cannot see.
    private static func stripPrefix(_ words: [String]) -> (words: [String], viaXargs: Bool) {
        var rest = words[...]
        var viaXargs = false
        while let first = rest.first {
            let name = (first as NSString).lastPathComponent
            if keywords.contains(first) {
                rest = rest.dropFirst()
            } else if let valued = wrappers[name] {
                rest = rest.dropFirst()
                if name == "xargs" { viaXargs = true }
                while let option = rest.first, option.hasPrefix("-") {
                    rest = rest.dropFirst()
                    if option == "--" { break }
                    if valued.contains(option) { rest = rest.dropFirst() }
                }
                if name == "timeout" { rest = rest.dropFirst() }
            } else if let equals = first.firstIndex(of: "="), !first.hasPrefix("-"),
                      first[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                rest = rest.dropFirst()
            } else {
                break
            }
        }
        return (Array(rest), viaXargs)
    }

    /// Split a shell line into simple commands of unquoted words: `&&`,
    /// `||`, `;`, `|`, `&`, a newline, and parentheses end a command.
    /// Quotes and a backslash keep their text in one word. A `$( )` or a
    /// backtick substitution adds its own commands to the list and leaves
    /// `$(…)` in the word that holds it, so a refspec stays one word. A
    /// here-document's body is skipped, unless a shell reads it: then its
    /// lines are commands too. It is a tokenizer, not a shell: it does not
    /// expand variables.
    static func simpleCommands(_ line: String) -> [[String]] {
        /// What a substitution interrupts, restored at its end.
        struct Outer {
            var words: [String]
            var word: String
            var inWord: Bool
            var quote: Character?
            var backtick: Bool
            var parens: Int
        }
        let characters = Array(line)
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var stack: [Outer] = []
        var parens = 0
        var heredocs: [(delimiter: String, dash: Bool, shell: Bool)] = []
        var index = 0
        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }
        func openSubstitution(backtick: Bool) {
            stack.append(Outer(words: words, word: word, inWord: true, quote: quote, backtick: backtick, parens: parens))
            words = []; word = ""; inWord = false; quote = nil; parens = 0
        }
        func closeSubstitution() {
            endCommand()
            let outer = stack.removeLast()
            words = outer.words; word = outer.word + "$(…)"; inWord = true; quote = outer.quote; parens = outer.parens
        }
        /// Consume each pending here-document's body, from `index` on.
        func readHeredocs() {
            for heredoc in heredocs {
                var body: [String] = []
                while index < characters.count {
                    var end = index
                    while end < characters.count, characters[end] != "\n" { end += 1 }
                    let text = String(characters[index..<end])
                    index = min(end + 1, characters.count)
                    let line = heredoc.dash ? String(text.drop { $0 == "\t" }) : text
                    if line == heredoc.delimiter { break }
                    body.append(text)
                }
                if heredoc.shell { commands += simpleCommands(body.joined(separator: "\n")) }
            }
            heredocs = []
        }
        while index < characters.count {
            let character = characters[index]
            index += 1
            let next: Character? = index < characters.count ? characters[index] : nil
            if let open = quote {
                if character == open {
                    quote = nil
                } else if open == "\"", character == "$", next == "(" {
                    index += 1
                    openSubstitution(backtick: false)
                } else if open == "\"", character == "`" {
                    openSubstitution(backtick: true)
                } else if character == "\\", open == "\"", let next {
                    index += 1
                    word.append(next)
                } else {
                    word.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                inWord = true
            case "\\":
                if let next {
                    index += 1
                    if next != "\n" { word.append(next); inWord = true }
                }
            case " ", "\t":
                endWord()
            case "$" where next == "(":
                index += 1
                openSubstitution(backtick: false)
            case "`":
                if stack.last?.backtick == true { closeSubstitution() } else { openSubstitution(backtick: true) }
            case "(":
                parens += 1
                endCommand()
            case ")":
                if parens == 0, let last = stack.last, !last.backtick { closeSubstitution() } else { parens = max(0, parens - 1); endCommand() }
            case "<" where next == "<" && (index + 1 >= characters.count || characters[index + 1] != "<"):
                index += 1
                var dash = false
                if index < characters.count, characters[index] == "-" { dash = true; index += 1 }
                while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
                var delimiter = ""
                while index < characters.count, !" \t\n;&|<>()".contains(characters[index]) {
                    if characters[index] != "'", characters[index] != "\"", characters[index] != "\\" {
                        delimiter.append(characters[index])
                    }
                    index += 1
                }
                endWord()
                let program = stripPrefix(words).words.first.map { ($0 as NSString).lastPathComponent }
                heredocs.append((delimiter, dash, program.map(shells.contains) ?? false))
            case "\n":
                endCommand()
                if !heredocs.isEmpty { readHeredocs() }
            case ";", "&", "|":
                endCommand()
            default:
                word.append(character)
                inWord = true
            }
        }
        while !stack.isEmpty { closeSubstitution() }
        endCommand()
        return commands
    }

    private static func resolve(_ path: String, from directory: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "~" || path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst() }
        return (directory as NSString).appendingPathComponent(path)
    }

    static let defaultGit: Git = { args, directory in
        guard let result = RoundCommand.defaultRunner("git", ["-C", directory] + args, directory),
              result.status == 0
        else { return nil }
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
