import Foundation

/// Key/value tags an orchestrator attaches to a session so the sessions it
/// created can be told apart later: which run they belong to, which node of
/// that run, which attempt.
///
/// Without them a fleet of sessions is anonymous — you can see twelve shells
/// and not know which graph node any of them is. With them, `/api/sessions` is
/// filterable and every command a session records attributes to a node.
///
/// A label also declares intent: a session carrying labels was created by a
/// program rather than by someone opening a tab, so the registry keeps it alive
/// far longer when its client disconnects (see `SessionRegistry`).
public struct SessionLabels: Sendable, Equatable {
    public static let maxCount = 12
    public static let maxKeyLength = 32
    public static let maxValueLength = 256

    /// `traceparent` is passed through verbatim so a caller can correlate a
    /// session's commands with a span it owns, without kitterm joining the
    /// trace itself. It is the one label whose value may hold `-`-separated
    /// hex fields, which the value charset already permits.
    public static let traceparentKey = "traceparent"

    public let values: [String: String]

    public var isEmpty: Bool { values.isEmpty }
    public subscript(key: String) -> String? { values[key] }

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    private static let keyAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
    private static let valueAllowed = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/"
    )

    /// Parse `key:value,key:value` as it arrives on `/ws?label=…`.
    ///
    /// Anything malformed is dropped rather than failing the connection: a bad
    /// tag should cost you a filter, not a shell. Keys are lowercased so
    /// `Run` and `run` are the same label.
    public static func parse(_ raw: String?) -> SessionLabels {
        guard let raw, !raw.isEmpty else { return SessionLabels() }
        var values: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            guard values.count < maxCount else { break }
            guard let separator = pair.firstIndex(of: ":") else { continue }
            let key = String(pair[pair.startIndex..<separator]).lowercased()
            let value = String(pair[pair.index(after: separator)...])
            guard isValidKey(key), isValidValue(value) else { continue }
            values[key] = value
        }
        return SessionLabels(values)
    }

    public static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= maxKeyLength && key.allSatisfy(keyAllowed.contains)
    }

    public static func isValidValue(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maxValueLength && value.allSatisfy(valueAllowed.contains)
    }

    /// Is this a well-formed `key:value` filter? Separate from matching so a
    /// typo can be rejected rather than reported as "no sessions matched".
    public static func isValidFilter(_ raw: String) -> Bool {
        guard let separator = raw.firstIndex(of: ":") else { return false }
        let key = String(raw[raw.startIndex..<separator])
        let value = String(raw[raw.index(after: separator)...])
        return isValidKey(key.lowercased()) && isValidValue(value)
    }

    /// Does this session match a `key:value` filter?
    public func matches(filter raw: String) -> Bool {
        guard let separator = raw.firstIndex(of: ":") else { return false }
        let key = String(raw[raw.startIndex..<separator]).lowercased()
        let value = String(raw[raw.index(after: separator)...])
        return values[key] == value
    }
}
