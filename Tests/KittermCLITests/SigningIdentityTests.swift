import XCTest

@testable import KittermCLI

/// Reading identity state out of `security` and `codesign` output.
///
/// These parse the words the tools actually print, because the words are the
/// interface: `security` has no machine-readable mode, and misreading it here
/// means `setup` either re-runs a trust dialog the user already answered or
/// declares an unusable identity ready.
final class SigningIdentityTests: XCTestCase {
    // MARK: - find-identity

    /// Both sections present, our identity in both: ready to sign.
    func testTrustedIdentityIsValid() {
        let output = """
        Policy: Code Signing
          Matching identities
          1) 4574693C0DF782582EEC07DD43661B312A99FDB6 "kitterm-local"
             1 identities found

          Valid identities only
          1) 4574693C0DF782582EEC07DD43661B312A99FDB6 "kitterm-local"
             1 valid identities found
        """
        XCTAssertEqual(SigningIdentity.state(fromFindIdentity: output), .valid)
    }

    /// The state this machine is in between `setup`'s creation and its trust
    /// step: present above the line, absent below it, refused for signing.
    func testUntrustedIdentityIsRecognised() {
        let output = """
        Policy: Code Signing
          Matching identities
          1) 4574693C0DF782582EEC07DD43661B312A99FDB6 "kitterm-local" (CSSMERR_TP_NOT_TRUSTED)
             1 identities found

          Valid identities only
             0 valid identities found
        """
        XCTAssertEqual(SigningIdentity.state(fromFindIdentity: output), .untrusted)
    }

    func testEmptyKeychainIsMissing() {
        let output = """
        Policy: Code Signing
          Matching identities
             0 identities found

          Valid identities only
             0 valid identities found
        """
        XCTAssertEqual(SigningIdentity.state(fromFindIdentity: output), .missing)
    }

    /// Somebody else's certificate must not read as ours.
    func testOtherIdentitiesDoNotCount() {
        let output = """
        Policy: Code Signing
          Matching identities
          1) AAAA "Apple Development: someone@example.com (ABC123)"
             1 identities found

          Valid identities only
          1) AAAA "Apple Development: someone@example.com (ABC123)"
             1 valid identities found
        """
        XCTAssertEqual(SigningIdentity.state(fromFindIdentity: output), .missing)
    }

    // MARK: - list-keychains

    /// The listing is quoted and indented; the paths inside are what `-s`
    /// needs back. Losing one would orphan that keychain from the search list.
    func testSearchListParsesQuotedPaths() {
        let output = """
            "/Users/x/Library/Keychains/login.keychain-db"
            "/Users/x/.kitterm/signing/signing.keychain-db"
        """
        XCTAssertEqual(
            SigningIdentity.searchList(fromListKeychains: output),
            [
                "/Users/x/Library/Keychains/login.keychain-db",
                "/Users/x/.kitterm/signing/signing.keychain-db",
            ])
    }

    func testSearchListIgnoresNoise() {
        XCTAssertEqual(SigningIdentity.searchList(fromListKeychains: ""), [])
        XCTAssertEqual(SigningIdentity.searchList(fromListKeychains: "no quotes here\n"), [])
    }

    // MARK: - codesign -dvv

    func testLocallySignedBinaryIsRecognised() {
        let info = """
        Executable=/Users/x/.local/lib/kitterm/kitterm
        Identifier=kitterm
        CodeDirectory v=20400 size=85184 flags=0x0(none) hashes=2659+2
        Signature size=1523
        Authority=kitterm-local
        Info.plist=not bound
        """
        XCTAssertTrue(SigningIdentity.isSigned(byIdentity: "kitterm-local", codesignInfo: info))
    }

    /// The ad-hoc case is the whole problem: no authority at all.
    func testAdHocBinaryIsNotSigned() {
        let info = """
        Executable=/Users/x/.local/lib/kitterm/kitterm
        Identifier=kitterm
        CodeDirectory v=20400 size=85184 flags=0x20002(adhoc,linker-signed) hashes=2659+0
        Signature=adhoc
        """
        XCTAssertFalse(SigningIdentity.isSigned(byIdentity: "kitterm-local", codesignInfo: info))
    }

    /// `Authority=` is matched as a whole line, so a name that merely contains
    /// ours — or a log line quoting it — cannot pass as a signature.
    func testAuthorityMustMatchExactly() {
        XCTAssertFalse(SigningIdentity.isSigned(
            byIdentity: "kitterm-local",
            codesignInfo: "Authority=kitterm-local-old\n"))
        XCTAssertFalse(SigningIdentity.isSigned(
            byIdentity: "kitterm-local",
            codesignInfo: "TeamIdentifier=Authority=kitterm-local\n"))
    }
}
