import Foundation

import KittermDaemon

/**
 A stable code-signing identity for the installed binaries.

 The released binaries are ad-hoc signed, and an ad-hoc signature's identity is
 a hash of the binary's own bytes. macOS ties every privacy grant — the folder
 prompts and Full Disk Access alike — to that identity, so every release
 silently invalidates every grant the user has made: the toggle still reads
 "on" in System Settings, but it names a binary that no longer exists, and the
 prompts return. That is not a bug to work around in TCC; the binary genuinely
 has no durable identity.

 This gives it one, without Apple. A self-signed code-signing certificate is
 created once, on this machine, in a keychain of its own under the state
 directory, and every install re-signs the downloaded binaries with it (see
 `scripts/install.sh`). The designated requirement then names the certificate
 rather than the bytes, so it is the same for every release and grants survive
 upgrades. Nothing leaves the machine: no developer account, no notarization,
 no change to what CI publishes.

 A dedicated keychain rather than the login keychain, deliberately. Its
 password can then be stored beside it (0600) and used to unlock and to set the
 key's partition list, which is what lets an unattended `kitterm upgrade` sign
 without a keychain dialog. The key signs kitterm's own binaries and nothing
 else; anyone who can read the password file can already replace the binaries
 outright, so the key adds nothing to what that attacker could do.

 The one step that cannot be silent is trust. macOS refuses to sign with a
 certificate nobody vouches for (`CSSMERR_TP_NOT_TRUSTED`), and changing trust
 settings is guarded by a password dialog. That dialog appears once, during
 `kitterm identity setup`, and never again.
 */
enum SigningIdentity {
    /// The certificate's common name, and the name `codesign -s` selects by.
    static let name = "kitterm-local"

    /// How the identity can stand, read from `security find-identity`.
    enum State: Equatable {
        /// No certificate with our name anywhere in the keychain.
        case missing
        /// Present but not yet trusted — signing with it is refused.
        case untrusted
        /// Present and trusted: ready to sign.
        case valid
    }

    static var directory: URL {
        DaemonPaths.stateDirectory.appendingPathComponent("signing", isDirectory: true)
    }
    static var keychainPath: String { directory.appendingPathComponent("signing.keychain-db").path }
    static var passwordPath: String { directory.appendingPathComponent("keychain-pass").path }
    static var certificatePath: String { directory.appendingPathComponent("cert.pem").path }

    // MARK: - Parsing (pure, tested)

    /**
     Read the identity's state out of `security find-identity -p codesigning`
     (without `-v`, so both sections are present).

     The output lists every matching identity, then repeats the *valid* ones
     under a "Valid identities only" heading. An identity that appears only
     above the heading exists but cannot sign — untrusted, expired, or missing
     its key — and the untrusted case is the one `setup` has to finish by hand.
     */
    static func state(fromFindIdentity output: String, name: String = SigningIdentity.name) -> State {
        let needle = "\"\(name)\""
        var inValidSection = false
        var found = false
        for line in output.split(separator: "\n") {
            if line.contains("Valid identities only") {
                inValidSection = true
                continue
            }
            guard line.contains(needle) else { continue }
            if inValidSection { return .valid }
            found = true
        }
        return found ? .untrusted : .missing
    }

    /**
     Whether `codesign -dvv` output says the binary was signed by `name`.

     A real signature carries `Authority=<signer>` lines; an ad-hoc one carries
     `Signature=adhoc` and no authority at all. The leaf authority is the first
     one printed, which for a self-signed certificate is also the only one.
     */
    static func isSigned(byIdentity name: String, codesignInfo: String) -> Bool {
        codesignInfo.split(separator: "\n").contains { $0 == "Authority=\(name)" }
    }

    // MARK: - Commands

    static func command(_ args: ArraySlice<String>) throws {
        switch args.first ?? "status" {
        case "status":
            try status()
        case "setup":
            try setup()
        case "sign":
            try signInstalled(reportWhenMissing: true)
        default:
            throw CLIError.usage("kitterm identity [status|setup|sign]")
        }
    }

    private static func status() throws {
        let state = try currentState()
        switch state {
        case .missing:
            print("no local signing identity — binaries are ad-hoc, and macOS forgets")
            print("file-access grants (Full Disk Access included) at every upgrade.")
            print("`kitterm identity setup` creates one; grants then survive upgrades.")
        case .untrusted:
            print("identity \(name) exists but is not trusted yet, so it cannot sign.")
            print("`kitterm identity setup` finishes it — macOS asks for your login")
            print("password once, to change Certificate Trust Settings.")
        case .valid:
            print("identity \(name) is ready (keychain: \(keychainPath))")
            if let until = certificateExpiry() { print("valid until \(until)") }
        }

        guard let prefix = InstallLayout.prefix(forExecutable: ResolveExecutable.path()) else {
            print("running from a dev build — the installed binaries were not checked")
            return
        }
        for binary in installedBinaries(prefix: prefix) {
            let info = run("/usr/bin/codesign", ["-dvv", binary]).output
            let signed = isSigned(byIdentity: name, codesignInfo: info)
            let base = (binary as NSString).lastPathComponent
            print("\(base): \(signed ? "signed with \(name)" : "ad-hoc — grants die at the next upgrade")")
        }
    }

    /// Create what is missing, finish trust, and sign the installed binaries.
    /// Safe to run again at any point: each stage is skipped once it holds.
    private static func setup() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if try currentState() == .missing {
            try createIdentity()
        }

        if try currentState() == .untrusted {
            print("macOS will now ask for your login password — it is changing your")
            print("Certificate Trust Settings so this certificate may sign code. Once.")
            let trust = run("/usr/bin/security", [
                "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
                "-k", keychainPath, certificatePath,
            ])
            guard trust.status == 0 else {
                throw CLIError.usage("trusting the certificate failed: \(trust.output)")
            }
        }

        guard try currentState() == .valid else {
            throw CLIError.usage(
                "the identity still is not valid after setup; `security find-identity "
                    + "-p codesigning \(keychainPath)` has the detail")
        }
        print("identity \(name) is ready")

        try signInstalled(reportWhenMissing: false)

        print("""

        one manual step remains, once:
          System Settings → Privacy & Security → Full Disk Access
          — remove any existing kitterm entries (they name dead identities)
          — add: \(installedDaemonPath() ?? "<prefix>/lib/kitterm/kitterm")
        then `kitterm restart`. Grants made from now on survive every upgrade.
        """)
    }

    /**
     Re-sign the installed binaries with the local identity.

     Sign a copy and rename it over the original, never the file in place. The
     kernel ties a running process to its file's code signature; rewriting the
     signature under a live daemon kills it, while a rename leaves it running
     from the old inode exactly the way the installer's swap does.
     */
    private static func signInstalled(reportWhenMissing: Bool) throws {
        guard try currentState() == .valid else {
            throw CLIError.usage("no valid signing identity — run `kitterm identity setup` first")
        }
        guard let prefix = InstallLayout.prefix(forExecutable: ResolveExecutable.path()) else {
            if reportWhenMissing {
                print("running from a dev build; nothing installed to sign")
            } else {
                print("no installed binaries found to sign — the next install will be signed")
            }
            return
        }

        let password = try String(contentsOfFile: passwordPath, encoding: .utf8)
        _ = run("/usr/bin/security", ["unlock-keychain", "-p", password, keychainPath])

        for binary in installedBinaries(prefix: prefix) {
            let info = run("/usr/bin/codesign", ["-dvv", binary]).output
            if isSigned(byIdentity: name, codesignInfo: info) { continue }
            let staged = binary + ".resign"
            try? FileManager.default.removeItem(atPath: staged)
            try FileManager.default.copyItem(atPath: binary, toPath: staged)
            let sign = run("/usr/bin/codesign", [
                "--force", "--timestamp=none", "--keychain", keychainPath,
                "--sign", name, staged,
            ])
            guard sign.status == 0 else {
                try? FileManager.default.removeItem(atPath: staged)
                throw CLIError.usage("codesign failed for \(binary): \(sign.output)")
            }
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: binary), withItemAt: URL(fileURLWithPath: staged))
            print("signed \((binary as NSString).lastPathComponent)")
        }
        print("a daemon that was already running still carries the old identity — `kitterm restart` picks up the signed one")
    }

    // MARK: - Creation

    /**
     Key and certificate via the system LibreSSL, imported through PKCS#12.

     `security` has no way to mint a certificate, and the Certificate Assistant
     is GUI-only, so openssl is the only scriptable path. The key exists as a
     file only inside the 0700 signing directory and only between these two
     commands; after import it lives in the keychain alone.

     `-T /usr/bin/codesign` on the import plus the partition list with the
     known password are together what make later signing silent — without them
     every upgrade would pop a keychain dialog, which an unattended
     `kitterm upgrade` cannot answer.
     */
    private static func createIdentity() throws {
        let password = randomHex(24)
        try password.write(toFile: passwordPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: passwordPath)

        let keyPath = directory.appendingPathComponent("key.pem").path
        let p12Path = directory.appendingPathComponent("identity.p12").path
        defer {
            try? FileManager.default.removeItem(atPath: keyPath)
            try? FileManager.default.removeItem(atPath: p12Path)
        }

        // Ten years. At expiry a new certificate means one new round of TCC
        // prompts, so the window is made long rather than conventional.
        let request = run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-keyout", keyPath,
            "-out", certificatePath, "-days", "3650", "-nodes",
            "-subj", "/CN=\(name)",
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning",
            "-addext", "basicConstraints=critical,CA:FALSE",
        ])
        guard request.status == 0 else {
            throw CLIError.usage("openssl could not create the certificate: \(request.output)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)

        let bundle = run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", keyPath, "-in", certificatePath,
            "-out", p12Path, "-passout", "pass:\(password)", "-name", name,
        ])
        guard bundle.status == 0 else {
            throw CLIError.usage("openssl could not bundle the identity: \(bundle.output)")
        }

        for step: (String, [String]) in [
            ("create-keychain", ["create-keychain", "-p", password, keychainPath]),
            // No auto-lock: a locked keychain would turn the next unattended
            // upgrade's signing step into a hang.
            ("set-keychain-settings", ["set-keychain-settings", keychainPath]),
            ("unlock-keychain", ["unlock-keychain", "-p", password, keychainPath]),
            ("import", ["import", p12Path, "-k", keychainPath, "-P", password,
                        "-T", "/usr/bin/codesign"]),
            ("set-key-partition-list", ["set-key-partition-list",
                                        "-S", "apple-tool:,apple:,codesign:",
                                        "-s", "-k", password, keychainPath]),
        ] {
            let result = run("/usr/bin/security", step.1)
            guard result.status == 0 else {
                throw CLIError.usage("security \(step.0) failed: \(result.output)")
            }
        }
        print("created identity \(name) in \(keychainPath)")
    }

    // MARK: - Plumbing

    private static func currentState() throws -> State {
        guard FileManager.default.fileExists(atPath: keychainPath) else { return .missing }
        let result = run("/usr/bin/security", ["find-identity", "-p", "codesigning", keychainPath])
        return state(fromFindIdentity: result.output)
    }

    private static func installedBinaries(prefix: URL) -> [String] {
        let lib = prefix.appendingPathComponent("lib/kitterm")
        return ["kitterm", "kitterm-spawn-helper"]
            .map { lib.appendingPathComponent($0).path }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func installedDaemonPath() -> String? {
        guard let prefix = InstallLayout.prefix(forExecutable: ResolveExecutable.path()) else {
            return nil
        }
        return prefix.appendingPathComponent("lib/kitterm/kitterm").path
    }

    private static func certificateExpiry() -> String? {
        let result = run("/usr/bin/openssl", ["x509", "-in", certificatePath, "-noout", "-enddate"])
        guard result.status == 0,
              let line = result.output.split(separator: "\n").first(where: { $0.hasPrefix("notAfter=") })
        else { return nil }
        return String(line.dropFirst("notAfter=".count))
    }

    private static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// Run a tool and collect everything it says, both streams merged: the
    /// caller reports failures whole rather than deciding which half mattered.
    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
