import Foundation
import KittermDaemon

/// `kitterm project add|init|list|remove` — the registered projects in
/// `~/.kitterm/projects.json`. The daemon reloads the file on its next
/// resolution, so a running daemon needs no restart.
enum ProjectCommand {
    static let usage = """
        usage: kitterm project add <path> [--name <name>] [--knowledge <dir>] \
        | init <path> [--name <name>] [--knowledge <dir>] | list | remove <id>
        """

    /// Run one subcommand. `out` takes every line meant for stdout, so a
    /// test reads what the user would.
    static func run<S: Sequence>(_ args: S, out: (String) -> Void = { print($0) }) throws
    where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "add":
            try add(Array(array.dropFirst()), out: out)
        case "init":
            try initialize(Array(array.dropFirst()), out: out)
        case "list":
            list(out: out)
        case "remove":
            guard array.count == 2 else {
                throw CLIError.usage("usage: kitterm project remove <id>")
            }
            try remove(id: array[1], out: out)
        default:
            throw CLIError.usage(usage)
        }
    }

    /// A validated `add` or `init` request: the canonical root, the name,
    /// and the knowledge directory relative to the root.
    private struct Target {
        let root: String
        let folder: String
        let name: String
        let knowledge: String
    }

    /// Parse `<path> [--name <name>] [--knowledge <dir>]` and validate every
    /// value the same way for `add` and `init`.
    private static func target(_ args: [String]) throws -> Target {
        var path: String?
        var nameOption: String?
        var knowledgeOption: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--name", "--knowledge":
                guard index + 1 < args.count else { throw CLIError.usage("\(arg) needs a value") }
                if arg == "--name" { nameOption = args[index + 1] } else { knowledgeOption = args[index + 1] }
                index += 2
                continue
            case _ where arg.hasPrefix("--name="):
                nameOption = String(arg.dropFirst("--name=".count))
            case _ where arg.hasPrefix("--knowledge="):
                knowledgeOption = String(arg.dropFirst("--knowledge=".count))
            case _ where arg.hasPrefix("-"):
                throw CLIError.usage("unknown option \(arg)\n\(usage)")
            default:
                guard path == nil else { throw CLIError.usage(usage) }
                path = arg
            }
            index += 1
        }
        guard let path else { throw CLIError.usage(usage) }

        let root = ProjectStore.canonicalRoot(
            path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.usage("no such directory: \(path)")
        }
        let folder = URL(fileURLWithPath: root).lastPathComponent
        let name = nameOption ?? folder
        guard !name.isEmpty, name.count <= ProjectStore.maxNameLength else {
            throw CLIError.usage("name must be 1 to \(ProjectStore.maxNameLength) characters")
        }
        let knowledge = knowledgeOption ?? ProjectStore.defaultKnowledge
        guard ProjectStore.isValidKnowledge(knowledge) else {
            throw CLIError.usage("knowledge must be a relative directory inside the project, without `..`")
        }
        return Target(root: root, folder: folder, name: name, knowledge: knowledge)
    }

    private static func add(_ args: [String], out: (String) -> Void) throws {
        try register(try target(args), out: out)
    }

    /// Append the project to `projects.json` and print its row.
    private static func register(_ target: Target, out: (String) -> Void) throws {
        var projects = ProjectStore.load()
        if let existing = projects.first(where: { $0.root == target.root }) {
            throw CLIError.usage("\(target.root) is already registered as \"\(existing.id)\"")
        }
        let id = ProjectStore.uniqueID(for: target.folder, taken: Set(projects.map(\.id)))
        projects.append(Project(id: id, name: target.name, root: target.root, knowledge: target.knowledge))
        try ProjectStore.save(projects)
        out("\(id)\t\(target.name)\t\(target.root)\t\(target.knowledge)")
    }

    /// `init`: write the goal package templates into the knowledge directory,
    /// then register the project. Every refusal happens before the first
    /// write, so a refused command leaves the project and the file untouched.
    private static func initialize(_ args: [String], out: (String) -> Void) throws {
        let target = try target(args)
        let knowledgeURL = URL(fileURLWithPath: target.root, isDirectory: true)
            .appendingPathComponent(target.knowledge, isDirectory: true)
        let existing = GoalsTemplates.files
            .map(\.path)
            .filter { FileManager.default.fileExists(atPath: knowledgeURL.appendingPathComponent($0).path) }
        guard existing.isEmpty else {
            let list = existing.map { "\(target.knowledge)/\($0)" }.joined(separator: ", ")
            throw CLIError.usage("refusing to overwrite: \(list) (nothing written)")
        }
        if let registered = ProjectStore.load().first(where: { $0.root == target.root }) {
            throw CLIError.usage("\(target.root) is already registered as \"\(registered.id)\" (nothing written)")
        }
        for (path, contents) in GoalsTemplates.files {
            let file = knowledgeURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file, options: .withoutOverwriting)
            out("wrote \(target.knowledge)/\(path)")
        }
        try register(target, out: out)
    }

    private static func list(out: (String) -> Void) {
        let projects = ProjectStore.load()
        if projects.isEmpty {
            out("no projects — register one with: kitterm project add <path>")
            return
        }
        for project in projects {
            out("\(project.id)\t\(project.name)\t\(project.root)\t\(project.knowledge)")
        }
    }

    private static func remove(id: String, out: (String) -> Void) throws {
        var projects = ProjectStore.load()
        guard projects.contains(where: { $0.id == id }) else {
            throw CLIError.usage("no project \"\(id)\" (see: kitterm project list)")
        }
        projects.removeAll { $0.id == id }
        try ProjectStore.save(projects)
        out("removed \(id)")
    }
}
