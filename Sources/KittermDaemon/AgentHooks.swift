import Foundation
import KittermProtocol

/// The Claude Code hook configuration that points an agent at this daemon.
///
/// Two events, for two different jobs:
///
/// - `PreToolUse` blocks. The daemon holds the response until a human decides,
///   which is what lets a permission prompt be answered from a phone instead of
///   only from the keyboard the agent happens to be running on.
/// - `Notification` does not block; it is how "the agent needs you" reaches the
///   fleet view at all. Claude discards this hook's output by design.
/// - `Stop` does not block either; it marks the agent's turn finished, which
///   is the `completed` edge in the fleet view. Answered `{}` at once — we
///   never hold a Stop, we only note it.
///
/// The URL is always loopback: the agent runs on the same machine as the daemon
/// serving it, so no token is involved even when that daemon is reachable from a
/// tailnet. `$KITTERM_SESSION_ID` is exported into every pane the daemon spawns,
/// and `allowedEnvVars` is what permits a header to read it — a hook config is
/// static and cannot look up which pane it is running in.
public enum AgentHooks {
    /// Claude's own timeout must outlast the daemon's hold, or Claude gives up
    /// first and the hold achieves nothing.
    static var hookTimeoutSeconds: Int { KittermConstants.approvalHoldDefaultSeconds + 30 }

    public static func settingsJSON(port: Int = KittermConstants.defaultPort) -> String {
        let entry: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/api/hooks",
            "headers": ["X-Kitterm-Session": "$KITTERM_SESSION_ID"],
            "allowedEnvVars": ["KITTERM_SESSION_ID"],
            "timeout": hookTimeoutSeconds,
        ]
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [["hooks": [entry]]],
                "Notification": [["hooks": [entry]]],
                "Stop": [["hooks": [entry]]],
            ]
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
