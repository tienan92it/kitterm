import Foundation
import KittermDaemon

/// `kitterm goal new|list|cost` — the goal folders under a project's
/// knowledge directory. Each goal is one folder, `<knowledge>/<slug>/`, and
/// its status is the `- Status:` line of its `STATE.md`. The project need
/// not be registered: the commands read and write the checkout only, and
/// `cost` reads the archives under `~/.kitterm` (`KITTERM_STATE_DIR`).
enum GoalCommand {
    static let usage = """
        usage: kitterm goal new <path> <slug> [--knowledge <dir>] | list <path> [--knowledge <dir>] \
        | cost <path> [<slug>] [--knowledge <dir>] [--json]
        """

    /// Run one subcommand. `out` takes every line meant for stdout.
    static func run<S: Sequence>(_ args: S, out: (String) -> Void = { print($0) }) throws
    where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "new":
            try new(Array(array.dropFirst()), out: out)
        case "list":
            try list(Array(array.dropFirst()), out: out)
        case "cost":
            try cost(Array(array.dropFirst()), out: out)
        default:
            throw CLIError.usage(usage)
        }
    }

    /// Parse `<path> [<slug>] [--knowledge <dir>] [<flags>]`: the canonical
    /// root, the knowledge directory, the positional arguments after the
    /// path, and the flags seen from `flags`; any other option is refused.
    private static func parse(
        _ args: [String], positionals: ClosedRange<Int>, flags: Set<String> = []
    ) throws -> (root: String, knowledge: String, rest: [String], flags: Set<String>) {
        var values: [String] = []
        var knowledgeOption: String?
        var seen: Set<String> = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--knowledge":
                guard index + 1 < args.count else { throw CLIError.usage("\(arg) needs a value") }
                knowledgeOption = args[index + 1]
                index += 2
                continue
            case _ where arg.hasPrefix("--knowledge="):
                knowledgeOption = String(arg.dropFirst("--knowledge=".count))
            case _ where flags.contains(arg):
                seen.insert(arg)
            case _ where arg.hasPrefix("-"):
                throw CLIError.usage("unknown option \(arg)\n\(usage)")
            default:
                values.append(arg)
            }
            index += 1
        }
        guard positionals.contains(values.count - 1) else { throw CLIError.usage(usage) }
        let root = try ProjectCommand.canonicalRoot(values[0])
        return (root, try ProjectCommand.knowledge(knowledgeOption), Array(values.dropFirst()), seen)
    }

    /// A slug is a project id (`ProjectStore.isValidID`): lowercase letters,
    /// digits, and hyphens, no leading or trailing hyphen, at most
    /// `maxIDLength` characters. It is a folder name, a label value, and the
    /// `# STATE:` heading; the daemon lists a goal folder by the same rule.
    static func isValidSlug(_ slug: String) -> Bool {
        ProjectStore.isValidID(slug)
    }

    /// `new`: write `<knowledge>/<slug>/` from the goal template with the
    /// slug in `STATE.md`. An existing folder, a file, or a dangling link of
    /// that name, and a symlink at any prefix of the path, are refused
    /// before anything is written, by the rule `project init` uses.
    private static func new(_ args: [String], out: (String) -> Void) throws {
        let (root, knowledge, rest, _) = try parse(args, positionals: 1...1)
        let slug = rest[0]
        guard isValidSlug(slug) else {
            throw CLIError.usage("slug must be lowercase letters, digits, and hyphens, not at the ends: \(slug)")
        }
        let folder = knowledge + "/" + slug
        try ProjectCommand.refuseExisting([slug], under: knowledge, root: root)
        let templates = GoalsTemplates.goal.map { template in
            template.path == "STATE.md"
                ? (path: template.path, contents: template.contents.replacingOccurrences(of: GoalsTemplates.slugPlaceholder, with: slug))
                : template
        }
        try ProjectCommand.writeTemplates(templates, under: folder, root: root, out: out)
    }

    /// `list`: one line per goal folder, `<slug>\t<status>`, the folders,
    /// the status words, and the order the summary route answers: the
    /// daemon's `KnowledgeFile.summaries` (the symlink gate, the bounded
    /// read, the slug rule, the folder cap) and its parser, sorted by
    /// `KnowledgeSummary.isOrderedBefore` (`active`, `waiting`, `stopped`,
    /// `done`, then the rest, then by slug). A missing status line prints
    /// `unknown`; a missing knowledge directory lists nothing.
    private static func list(_ args: [String], out: (String) -> Void) throws {
        let (root, knowledge, _, _) = try parse(args, positionals: 0...0)
        for goal in KnowledgeFile.summaries(root: root, knowledge: knowledge) ?? [] {
            out("\(goal.slug ?? "")\t\(goal.status ?? "unknown")")
        }
    }

    /// `cost`: the ledger of every goal, or of the one named, per round:
    /// dollars, tokens, the cache-read share of input, wall-clock, tests
    /// added, files changed, the decision and the PR, with totals per goal.
    /// One monospace table per goal, a blank line between goals; `--json`
    /// prints one document with one object per round, unrounded. See
    /// `GoalLedger` for where each column comes from and which source wins.
    private static func cost(_ args: [String], out: (String) -> Void) throws {
        let (root, knowledge, rest, flags) = try parse(args, positionals: 0...1, flags: ["--json"])
        let goals = try GoalLedger.goals(root: root, knowledge: knowledge, slug: rest.first)
        if flags.contains("--json") {
            out(try GoalLedger.jsonText(goals))
            return
        }
        for (index, goal) in goals.enumerated() {
            if index > 0 { out("") }
            for line in GoalLedger.table(goal) { out(line) }
        }
    }
}
