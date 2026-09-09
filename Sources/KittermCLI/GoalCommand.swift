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

    /// The statuses `LOOP.md` names, in the order `list` prints them. Any
    /// other value sorts after `done`, with a missing line as `unknown`.
    static let statusOrder = ["active", "waiting", "stopped", "done"]

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

    /// A slug is lowercase letters, digits, and hyphens: it is a folder name,
    /// a label value, and the `# STATE:` heading.
    static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.count <= ProjectStore.maxIDLength
            && slug.allSatisfy { ($0.isASCII && $0.isLowercase && $0.isLetter) || ($0.isASCII && $0.isNumber) || $0 == "-" }
    }

    /// `new`: write `<knowledge>/<slug>/` from the goal template with the
    /// slug in `STATE.md`. An existing folder, or a file of that name, is
    /// refused before anything is written.
    private static func new(_ args: [String], out: (String) -> Void) throws {
        let (root, knowledge, rest) = try parse(args, positionals: 1)
        let slug = rest[0]
        guard isValidSlug(slug) else {
            throw CLIError.usage("slug must be lowercase letters, digits, and hyphens: \(slug)")
        }
        let folder = knowledge + "/" + slug
        let folderPath = root + "/" + folder
        if FileManager.default.fileExists(atPath: folderPath) || isLink(folderPath) {
            throw CLIError.usage("refusing to overwrite: \(folder) exists (nothing written)")
        }
        try ProjectCommand.refuseExisting(GoalsTemplates.goal.map(\.path), under: folder, root: root)
        let templates = GoalsTemplates.goal.map { template in
            template.path == "STATE.md"
                ? (path: template.path, contents: template.contents.replacingOccurrences(of: GoalsTemplates.slugPlaceholder, with: slug))
                : template
        }
        try ProjectCommand.writeTemplates(templates, under: folder, root: root, out: out)
    }

    /// `list`: one line per goal folder, `<slug>\t<status>`, sorted by
    /// status (`active`, `waiting`, `stopped`, `done`, then the rest) and
    /// slug. A folder without `STATE.md` is not a goal and is skipped.
    private static func list(_ args: [String], out: (String) -> Void) throws {
        let (root, knowledge, _) = try parse(args, positionals: 0)
        let directory = root + "/" + knowledge
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var goals: [(slug: String, status: String)] = []
        for name in names {
            let state = directory + "/" + name + "/STATE.md"
            guard let text = try? String(contentsOfFile: state, encoding: .utf8) else { continue }
            goals.append((name, status(of: text) ?? "unknown"))
        }
        goals.sort { a, b in
            let (ra, rb) = (rank(a.status), rank(b.status))
            return ra != rb ? ra < rb : a.slug < b.slug
        }
        for goal in goals { out("\(goal.slug)\t\(goal.status)") }
    }

    /// The value of the first `- Status:` line, trimmed; nil when the file
    /// has none or the value is empty.
    static func status(of stateText: String) -> String? {
        let marker = "- Status:"
        for line in stateText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        where line.hasPrefix(marker) {
            let value = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func rank(_ status: String) -> Int {
        statusOrder.firstIndex(of: status) ?? statusOrder.count
    }

    /// `lstat`: a dangling link at the folder path still occupies the name.
    private static func isLink(_ path: String) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        return type == .typeSymbolicLink
    }
}
