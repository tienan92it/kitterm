import Foundation
import XCTest

/// Helpers the CLI tests share for the files a command writes.
enum CLIFixture {
    /// The checkout the test source sits in: `Tests/KittermCLITests/<file>`.
    /// The tests that read `docs/goals/` and `examples/` resolve it here,
    /// so a moved test file changes one line.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // KittermCLITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    /// Every regular file under `url`, keyed by its path relative to `url`.
    /// A directory contributes nothing, so an empty `corpus/` is invisible.
    static func files(under url: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: url.path))
        var result: [String: Data] = [:]
        for case let relative as String in enumerator {
            let full = url.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                result[relative] = try Data(contentsOf: full)
            }
        }
        return result
    }
}
