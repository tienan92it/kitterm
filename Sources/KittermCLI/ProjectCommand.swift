import Foundation
import KittermDaemon

/// `kitterm project add|list|remove` — the registered projects in
/// `~/.kitterm/projects.json`. The daemon reloads the file on its next
/// resolution, so a running daemon needs no restart.
enum ProjectCommand {
    static let usage = "usage: kitterm project add <path> [--name <name>] [--knowledge <dir>] | list | remove <id>"

    /// Run one subcommand. `out` takes every line meant for stdout, so a
    /// test reads what the user would.
    static func run<S: Sequence>(_ args: S, out: (String) -> Void = { print($0) }) throws
    where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "add":
            try add(Array(array.dropFirst()), out: out)
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

    private static func add(_ args: [String], out: (String) -> Void) throws {
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

        var projects = ProjectStore.load()
        if let existing = projects.first(where: { $0.root == root }) {
            throw CLIError.usage("\(root) is already registered as \"\(existing.id)\"")
        }
        let id = ProjectStore.uniqueID(for: folder, taken: Set(projects.map(\.id)))
        projects.append(Project(id: id, name: name, root: root, knowledge: knowledge))
        try ProjectStore.save(projects)
        out("\(id)\t\(name)\t\(root)\t\(knowledge)")
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
