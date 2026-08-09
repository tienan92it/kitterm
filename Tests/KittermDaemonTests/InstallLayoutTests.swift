import Foundation
import XCTest

@testable import KittermDaemon

/// The installer stages a new build under a live daemon, so "which version is
/// this" has two answers. Getting the prefix wrong makes both of them wrong.
final class InstallLayoutTests: XCTestCase {
    func testPrefixFromInstalledLayout() {
        let prefix = InstallLayout.prefix(forExecutable: "/opt/kit/lib/kitterm/kitterm")
        XCTAssertEqual(prefix?.path, "/opt/kit")
    }

    /// A build tree is not an install: reporting a version for it would invent
    /// one out of whatever happened to sit three directories up.
    func testPrefixRejectsBuildTreeLayout() {
        XCTAssertNil(InstallLayout.prefix(forExecutable: "/repo/.build/debug/kitterm"))
        XCTAssertNil(InstallLayout.prefix(forExecutable: "/usr/local/bin/kitterm"))
    }

    func testVersionIsReadAndTrimmed() throws {
        let root = try makeInstallTree(version: "v1.2.3\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            InstallLayout.versionOnDisk(executablePath: executable(in: root)),
            "v1.2.3"
        )
    }

    /// An empty or whitespace-only VERSION means "unknown", not "".
    func testBlankVersionFileIsNil() throws {
        let root = try makeInstallTree(version: "   \n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(InstallLayout.versionOnDisk(executablePath: executable(in: root)))
    }

    func testMissingVersionFileIsNil() throws {
        let root = try makeInstallTree(version: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(InstallLayout.versionOnDisk(executablePath: executable(in: root)))
    }

    private func executable(in root: URL) -> String {
        root.appendingPathComponent("lib/kitterm/kitterm").path
    }

    private func makeInstallTree(version: String?) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-layout-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("lib/kitterm"),
            withIntermediateDirectories: true
        )
        let share = root.appendingPathComponent("share/kitterm")
        try fm.createDirectory(at: share, withIntermediateDirectories: true)
        if let version {
            try version.write(
                to: share.appendingPathComponent("VERSION"),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }
}
