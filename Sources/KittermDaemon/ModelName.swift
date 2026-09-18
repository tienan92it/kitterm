import Foundation

/// The name the fleet view prints for a model id, by the naming rule in
/// `docs/goals/agent-dashboard/corpus/design-foundation.md`.
///
/// The rule, in order: drop the `claude-` prefix; move a `[1m]` suffix to
/// ` · 1M` and keep that variant apart from its family; drop a trailing
/// eight-digit date; title-case the family and join the version digits with
/// a dot. When a step cannot read the id, the id prints unchanged: a name
/// is never guessed from an id the rule does not fit.
///
/// | Id | Name |
/// |---|---|
/// | `claude-fable-5-1` | Fable 5.1 |
/// | `claude-opus-5[1m]` | Opus 5 · 1M |
/// | `claude-haiku-4-5-20251001` | Haiku 4.5 |
/// | `claude-3-5-sonnet-20241022` | unchanged |
/// | `us.anthropic.claude-fable-5-1` | unchanged |
public enum ModelName {
    static let prefix = "claude-"
    static let longContextSuffix = "[1m]"
    static let longContextName = " · 1M"

    /// The name for `id`, or `id` itself when the rule does not fit it.
    public static func name(for id: String) -> String {
        guard id.hasPrefix(prefix) else { return id }
        var rest = String(id.dropFirst(prefix.count))
        var variant = ""
        if rest.hasSuffix(longContextSuffix) {
            rest = String(rest.dropLast(longContextSuffix.count))
            variant = longContextName
        }
        var parts = rest.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber), parts.count > 1 {
            parts.removeLast()
        }
        // The family, then one or more version digits. `claude-3-5-sonnet`
        // puts the digits first and does not fit; it prints as it is.
        guard let family = parts.first, !family.isEmpty, family.allSatisfy({ $0.isLetter }),
              parts.count >= 2, parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + " " + version + variant
    }
}
