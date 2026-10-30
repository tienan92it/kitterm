import Foundation

/// Which usage text a `--help` request names: the whole program, or one
/// subcommand (no subcommand carries its own section yet, so `.command`
/// prints the whole usage too — see `KittermMain.printUsage`).
enum HelpTopic: Equatable {
    case general
    case command(String)
}

/// Decides whether an argv asks for help, before anything it names runs.
///
/// The incident this exists for: `kitterm service install --help` reached
/// `DaemonFlags.parse`, which keeps the flags it knows and silently drops
/// the rest, so `--help` vanished and the command rewrote the LaunchAgent
/// plist with none of the real flags (docs/goals/facts.md, 2026-10-30). No
/// subcommand checked for `--help` at all; `start`, `stop`, `restart`,
/// `upgrade` acted the same way.
enum HelpRequest {
    /// Exact tokens, never a substring match: `--trusted-host
    /// --help-desk.example` is a value for `--trusted-host`, not a request
    /// for help, because `"--help-desk.example" != "--help"`.
    private static let flags: Set<String> = ["--help", "-h"]

    /// Flags that take a separate following token as their value, across
    /// every subcommand that has one (`DaemonFlags`, `project`, `goal`,
    /// `skills`, `statusline`, `foreman`, `screen-state`). The token right
    /// after one of these is that flag's value, whatever it looks like —
    /// `kitterm project add x --name -h` names the project `-h`, it does not
    /// ask for help.
    private static let valuedFlagNames: Set<String> = [
        "--port", "--trusted-host", "--tls-cert", "--tls-key", "--tls-port",
        "--session-linger", "--name", "--knowledge", "--dir", "--scope",
        "--days", "--print", "--session", "--since", "--epoch", "--heartbeat", "--timeout",
    ]

    /// `args` is the full argv with the command name first, if any. `nil`
    /// means run the command as given.
    ///
    /// The bare word `help` means help only as `args[0]` — `kitterm help`,
    /// `kitterm help service` — never later, so `kitterm goal new <path>
    /// help` still names a goal `help`. `--help` and `-h` count anywhere
    /// after the command, except where a valued flag consumes them as its
    /// own value.
    static func decide(_ args: [String]) -> HelpTopic? {
        guard let command = args.first else { return nil }
        if command == "help" || flags.contains(command) {
            return .general
        }
        var index = 1
        while index < args.count {
            let arg = args[index]
            if valuedFlagNames.contains(arg) {
                index += 2  // the next token is this flag's value, not a candidate
                continue
            }
            if flags.contains(arg) {
                return .command(command)
            }
            index += 1
        }
        return nil
    }
}
