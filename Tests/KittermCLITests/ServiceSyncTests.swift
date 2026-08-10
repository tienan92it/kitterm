import XCTest

@testable import KittermCLI

/// `service sync` rewrites an installed LaunchAgent from this build's template.
///
/// It exists because the template lives in the binary while the plist lives on
/// disk, and the installer only ever re-bootstrapped whatever file was already
/// there. A build that changed the template therefore never reached an existing
/// service — which is how daemons kept starting at background QoS after the
/// release that fixed it was installed.
final class ServiceSyncTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("com.kitterm.daemon.plist")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func parse(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    /// A plist as `kitterm service install` wrote it before the QoS fix, with a
    /// non-default port and flags the user chose once.
    private var legacyPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>com.kitterm.daemon</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/Users/someone/.local/bin/kitterm</string>
        \t\t<string>serve</string>
        \t\t<string>--port</string>
        \t\t<string>4000</string>
        \t\t<string>--lan</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>ProcessType</key>
        \t<string>Background</string>
        </dict>
        </plist>

        """
    }

    /// The regression this command was written for: an installed service moves
    /// off Background without the user reinstalling it.
    func testSyncUpgradesProcessTypeInPlace() throws {
        let plist = try write(legacyPlist)
        XCTAssertTrue(try KittermMain.syncServicePlist(at: plist), "expected the file to change")
        XCTAssertEqual(try parse(plist)["ProcessType"] as? String, "Interactive")
    }

    /// The arguments are the one thing sync must not regenerate. They record a
    /// port and flags chosen at install time and stored nowhere else, so
    /// rebuilding them from defaults would silently drop `--lan` and send the
    /// daemon back to 3418.
    func testSyncPreservesTheArgumentsTheServiceWasInstalledWith() throws {
        let plist = try write(legacyPlist)
        _ = try KittermMain.syncServicePlist(at: plist)
        XCTAssertEqual(
            try parse(plist)["ProgramArguments"] as? [String],
            ["/Users/someone/.local/bin/kitterm", "serve", "--port", "4000", "--lan"]
        )
    }

    /// KeepAlive is what makes the login agent come back after a crash; losing
    /// it in a rewrite would turn it into a job that dies once and stays dead.
    func testSyncPreservesKeepAlive() throws {
        let plist = try write(legacyPlist)
        _ = try KittermMain.syncServicePlist(at: plist)
        XCTAssertEqual(try parse(plist)["KeepAlive"] as? Bool, true)
        XCTAssertEqual(try parse(plist)["Label"] as? String, "com.kitterm.daemon")
        XCTAssertEqual(try parse(plist)["RunAtLoad"] as? Bool, true)
    }

    /// The installer runs this on every upgrade, so a no-op has to be a real
    /// no-op — reporting a change every time would train the warning out.
    func testSyncIsIdempotent() throws {
        let plist = try write(legacyPlist)
        XCTAssertTrue(try KittermMain.syncServicePlist(at: plist))
        XCTAssertFalse(try KittermMain.syncServicePlist(at: plist), "second sync should be a no-op")
    }

    /// Better to fail loudly and send the user to `service install` than to
    /// invent arguments for a file we cannot read.
    func testSyncRefusesAPlistWithoutProgramArguments() throws {
        let plist = try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>com.kitterm.daemon</string>
        </dict>
        </plist>

        """)
        XCTAssertThrowsError(try KittermMain.syncServicePlist(at: plist))
    }

    func testSyncReportsAMissingFileRatherThanCreatingOne() throws {
        let missing = directory.appendingPathComponent("absent.plist")
        XCTAssertThrowsError(try KittermMain.syncServicePlist(at: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    /// Paths and flags reach the plist as XML text, so an argument containing a
    /// markup character must not be able to break the document.
    func testArgumentsWithMarkupCharactersStayParseable() throws {
        let body = KittermMain.launchdPlistBody(
            programArguments: ["/tmp/a&b/kitterm", "serve", "--trusted-host", "<x>"],
            keepAlive: false
        )
        let url = directory.appendingPathComponent("escaped.plist")
        try body.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try parse(url)["ProgramArguments"] as? [String],
            ["/tmp/a&b/kitterm", "serve", "--trusted-host", "<x>"]
        )
    }
}
