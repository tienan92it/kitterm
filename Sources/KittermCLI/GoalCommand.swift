import Foundation
import KittermDaemon

/// `kitterm goal new|list` — the goal folders under a project's knowledge
/// directory. Each goal is one folder, `<knowledge>/<slug>/`, and its
/// status is the `- Status:` line of its `STATE.md`. The project need not
/// be registered: the commands read and write the checkout only.
enum GoalCommand {
    static let usage = """
        usage: kitterm goal new <path> <slug> [--knowledge <dir>] | list <path> [--knowledge <dir>]
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
        default:
            throw CLIError.usage(usage)
        }
    }

    /// Parse `<path> [<slug>] [--knowledge <dir>]`: the canonical root, the
    /// knowledge directory, and the positional arguments after the path.
    private static func parse(_ args: [String], positionals: Int) throws -> (root: String, knowledge: String, rest: [String]) {
        var values: [String] = []
        var knowledgeOption: String?
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
            case _ where arg.hasPrefix("-"):
                throw CLIError.usage("unknown option \(arg)\n\(usage)")
            default:
                values.append(arg)
            }
            index += 1
        }
        guard values.count == positionals + 1 else { throw CLIError.usage(usage) }
        let root = try ProjectCommand.canonicalRoot(values[0])
        return (root, try ProjectCommand.knowledge(knowledgeOption), Array(values.dropFirst()))
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
        let (root, knowledge, rest) = try parse(args, positionals: 1)
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
        let (root, knowledge, _) = try parse(args, positionals: 0)
        for goal in KnowledgeFile.summaries(root: root, knowledge: knowledge) ?? [] {
            out("\(goal.slug ?? "")\t\(goal.status ?? "unknown")")
        }
    }
}
