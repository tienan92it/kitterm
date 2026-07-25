import Foundation
import XCTest

@testable import KittermDaemon

final class ShellIntegrationTests: XCTestCase {
    /// `scripts/shell-integration.zsh` is the canonical copy; the embedded
    /// string exists so `kitterm integrate` works from any install. They must
    /// never drift.
    func testEmbeddedSnippetMatchesCanonicalScript() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // KittermDaemonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("scripts/shell-integration.zsh")
        let canonical = try String(contentsOf: script, encoding: .utf8)
        XCTAssertEqual(
            ShellIntegration.zsh,
            canonical,
            "Sources/KittermDaemon/ShellIntegration.swift drifted from scripts/shell-integration.zsh — update both together"
        )
    }
}
