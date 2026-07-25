import Foundation
import XCTest

@testable import KittermDaemon

final class ShellIntegrationTests: XCTestCase {
    /// `scripts/shell-integration.{zsh,bash}` are the canonical copies; the
    /// embedded strings exist so `kitterm integrate` works from any install.
    /// They must never drift.
    func testEmbeddedSnippetsMatchCanonicalScripts() throws {
        for (embedded, script) in [
            (ShellIntegration.zsh, "shell-integration.zsh"),
            (ShellIntegration.bash, "shell-integration.bash"),
        ] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // KittermDaemonTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("scripts/\(script)")
            let canonical = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(
                embedded,
                canonical,
                "ShellIntegration.swift drifted from scripts/\(script) — update both together"
            )
        }
    }
}
