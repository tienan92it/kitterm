import Foundation
import KittermDaemon

/// `kitterm round guard` — the `PreToolUse` hook of a crew session
/// (`examples/foreman/crew-settings.json`). It refuses what a permission
/// rule cannot match by prefix: a `git push` to the base branch or with
/// force, and `kitterm start|stop|restart` run by a path or by `swift run`.
/// The base branch is `KnowledgeBase.baseBranch` in the command's directory.
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

    /// The exit code. `input` is stdin; `out` and `err` take the lines for
    /// stdout and stderr.
    static func run(
        _ args: [String], input: Data, git: Git = defaultGit,
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
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
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
            let words = stripPrefix(words)
            guard let program = words.first else { continue }
            let name = (program as NSString).lastPathComponent
            if name == "cd", words.count == 2 {
                directory = resolve(words[1], from: directory)
            } else if name == "git", let reason = gitRefusal(Array(words.dropFirst()), directory: directory, git: git) {
                return reason
            } else if let reason = kittermRefusal(words) {
                return reason
            }
        }
        return nil
    }

    // MARK: - git push

    private static func gitRefusal(_ args: [String], directory: String, git: Git) -> String? {
        var directory = directory
        var index = 0
        // Global options before the subcommand; `-C` moves the directory.
        while index < args.count, args[index].hasPrefix("-") {
            if args[index] == "-C", index + 1 < args.count {
                directory = resolve(args[index + 1], from: directory)
                index += 2
            } else if args[index] == "-c" {
                index += 2
            } else {
                index += 1
            }
        }
        guard index < args.count, args[index] == "push" else { return nil }
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
        let base = baseBranch(in: directory, git: git)
        let current = git(["symbolic-ref", "--short", "HEAD"], directory)
        if refspecs.isEmpty {
            return current == base ? "a push from the base branch \(base)" : nil
        }
        for refspec in refspecs {
            var destination = refspec.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? refspec
            if destination == "HEAD" { destination = current ?? "HEAD" }
            if destination.hasPrefix("refs/heads/") { destination.removeFirst("refs/heads/".count) }
            if destination == base { return "a push to the base branch \(base) (\(refspec))" }
        }
        return nil
    }

    /// The base branch by the rule `kitterm round open` uses.
    private static func baseBranch(in directory: String, git: Git) -> String {
        KnowledgeBase.baseBranch { git($0, directory) }
    }

    // MARK: - kitterm start, stop, restart

    private static let daemonVerbs: Set<String> = ["start", "stop", "restart"]

    /// `kitterm <verb>` by any path, and `swift run [options] kitterm <verb>`.
    private static func kittermRefusal(_ words: [String]) -> String? {
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

    /// Drop `VAR=value` words and the `env`, `command`, `exec` prefixes.
    private static func stripPrefix(_ words: [String]) -> [String] {
        var rest = words[...]
        while let first = rest.first {
            if ["env", "command", "exec", "time"].contains(first) {
                rest = rest.dropFirst()
            } else if let equals = first.firstIndex(of: "="), !first.hasPrefix("-"),
                      first[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                rest = rest.dropFirst()
            } else {
                break
            }
        }
        return Array(rest)
    }

    /// Split a shell line into simple commands of unquoted words: `&&`,
    /// `||`, `;`, `|`, `&`, a newline, and parentheses end a command.
    /// Quotes and a backslash keep their text in one word. It is a
    /// tokenizer, not a shell: it does not expand variables.
    static func simpleCommands(_ line: String) -> [[String]] {
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var characters = line.makeIterator()
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
        while let character = characters.next() {
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"", let next = characters.next() {
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
                if let next = characters.next(), next != "\n" { word.append(next); inWord = true }
            case " ", "\t":
                endWord()
            case "\n", ";", "&", "|", "(", ")", "`":
                endCommand()
            default:
                word.append(character)
                inWord = true
            }
        }
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
