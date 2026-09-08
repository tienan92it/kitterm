import Foundation

/// `kitterm skills install|list` — the reference foreman skills under
/// `examples/foreman/`, embedded in the binary as `ForemanSkills`, written
/// where Claude Code reads a skill: `<dir>/<name>/SKILL.md`.
enum SkillsCommand {
    static let usage = "usage: kitterm skills install [--dir <path>] | list"

    /// Where `install` writes without `--dir`.
    static var defaultDirectory: String {
        NSHomeDirectory() + "/.claude/skills"
    }

    /// Run one subcommand. `out` takes every line meant for stdout, so a
    /// test reads what the user would.
    static func run<S: Sequence>(_ args: S, out: (String) -> Void = { print($0) }) throws
    where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "install":
            try install(directory: try directory(Array(array.dropFirst())), out: out)
        case "list":
            guard array.count == 1 else { throw CLIError.usage(usage) }
            list(out: out)
        default:
            throw CLIError.usage(usage)
        }
    }

    /// Parse `[--dir <path>]`. A relative path is taken from the cwd; a
    /// leading `~` is the home directory.
    private static func directory(_ args: [String]) throws -> String {
        var directory: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--dir":
                guard index + 1 < args.count else { throw CLIError.usage("--dir needs a value") }
                directory = args[index + 1]
                index += 2
                continue
            case _ where arg.hasPrefix("--dir="):
                directory = String(arg.dropFirst("--dir=".count))
            default:
                throw CLIError.usage("unknown option \(arg)\n\(usage)")
            }
            index += 1
        }
        guard let directory else { return defaultDirectory }
        guard !directory.isEmpty else { throw CLIError.usage("--dir needs a value") }
        if directory == "~" || directory.hasPrefix("~/") {
            return NSHomeDirectory() + directory.dropFirst()
        }
        if directory.hasPrefix("/") { return directory }
        return FileManager.default.currentDirectoryPath + "/" + directory
    }

    /// Write every skill to `<dir>/<name>/SKILL.md` and print one line per
    /// file: `wrote` for a new file, `updated` for a file whose bytes
    /// differed, `unchanged` for a file that already matched. An unchanged
    /// file is not rewritten, so its mtime stays.
    static func install(directory: String, out: (String) -> Void) throws {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        for (name, contents) in ForemanSkills.files {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let file = folder.appendingPathComponent("SKILL.md")
            let bytes = Data(contents.utf8)
            let verb: String
            if let existing = try? Data(contentsOf: file) {
                if existing == bytes {
                    out("unchanged \(file.path)")
                    continue
                }
                verb = "updated"
            } else {
                verb = "wrote"
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            out("\(verb) \(file.path)")
        }
    }

    /// One line per skill: the name and the description from its frontmatter.
    static func list(out: (String) -> Void) {
        for (name, contents) in ForemanSkills.files {
            out("\(name)\t\(ForemanSkills.description(of: contents))")
        }
    }
}
