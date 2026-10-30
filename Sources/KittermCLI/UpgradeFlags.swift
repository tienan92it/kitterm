import Foundation

/// `kitterm upgrade`'s own flags — just the two booleans. Anything else
/// (a typo, or `--help` falling through unnoticed as `--restart`/`--live`
/// did before this) must not reach `upgrade()`, which runs the installer
/// (`curl … | sh`) unconditionally once called.
enum UpgradeFlags {
    static let usage = "usage: kitterm upgrade [--live | --restart]"

    static func validate<S: Sequence>(_ args: S) throws where S.Element == String {
        for arg in args {
            guard arg == "--restart" || arg == "--live" else {
                throw CLIError.unknownOption("kitterm: unknown option \(arg)\n\(usage)")
            }
        }
    }
}
