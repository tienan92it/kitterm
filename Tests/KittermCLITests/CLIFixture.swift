import Foundation
import XCTest

/// Helpers the CLI tests share for the files a command writes.
enum CLIFixture {
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
