import Foundation
import XCTest

@testable import KittermDaemon

/// Certificate loading fails at startup, not on the first connection — a
/// mistyped path should stop the launch with a readable reason.
final class TLSConfigTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingCertificateIsNamedInTheError() {
        let config = TLSConfig(
            certificatePath: dir.appendingPathComponent("nope.pem").path,
            privateKeyPath: dir.appendingPathComponent("nope.key").path,
            port: 3419
        )
        XCTAssertThrowsError(try config.makeSSLContext()) { error in
            guard case .missingFile(let path)? = error as? TLSConfigError else {
                return XCTFail("expected .missingFile, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix("nope.pem"))
        }
    }

    func testGarbagePEMIsRejectedWithAReadableError() throws {
        let cert = dir.appendingPathComponent("cert.pem")
        let key = dir.appendingPathComponent("key.pem")
        try "not a certificate".write(to: cert, atomically: true, encoding: .utf8)
        try "not a key".write(to: key, atomically: true, encoding: .utf8)
        let config = TLSConfig(
            certificatePath: cert.path,
            privateKeyPath: key.path,
            port: 3419
        )
        XCTAssertThrowsError(try config.makeSSLContext()) { error in
            guard case .invalidMaterial? = error as? TLSConfigError else {
                return XCTFail("expected .invalidMaterial, got \(error)")
            }
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }
}
