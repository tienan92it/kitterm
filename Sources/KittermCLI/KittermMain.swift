import Darwin
import Foundation
import KittermDaemon
import KittermProtocol

@main
enum KittermMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(2)
        }

        do {
            switch command {
            case "start":
                try start(parsePort(args.dropFirst()), flags: DaemonFlags.parse(args))
            case "stop":
                try stop()
            case "status":
                try status()
            case "restart":
                try restart(args.dropFirst())
            case "open":
                try openShell(at: args.dropFirst().first(where: { !$0.hasPrefix("-") }))
            case "service":
                try service(args.dropFirst())
            case "upgrade", "update":
                try upgrade()
            case "integrate":
                // Snippet only, nothing else on stdout — it is made for piping:
                //   kitterm integrate >> ~/.zshrc
                //   kitterm integrate bash | ssh vm 'cat >> ~/.bashrc'
                switch args.dropFirst().first ?? "zsh" {
                case "zsh":
                    print(ShellIntegration.zsh, terminator: "")
                case "bash":
                    print(ShellIntegration.bash, terminator: "")
                case let shell:
                    throw CLIError.usage("kitterm integrate [zsh|bash] — no snippet for \(shell)")
                }
            case "token":
                try tokenCommand(args.dropFirst())
            case "version", "--version", "-v":
                print(installedVersion() ?? "dev")
            case "serve":
                // Internal: foreground daemon process.
                try serve(port: parsePort(args.dropFirst()), flags: DaemonFlags.parse(args))
            case "help", "-h", "--help":
                printUsage()
            default:
                fputs("Unknown command: \(command)\n", stderr)
                printUsage()
                exit(2)
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// `kitterm token create|list|revoke` — named persistent LAN tokens.
    /// Only hashes are stored; the plaintext prints once on stdout (pipeable)
    /// with guidance on stderr. Revocation applies to a running daemon on its
    /// next request (the store reloads on file change).
    private static func tokenCommand<S: Sequence>(_ args: S) throws where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "create":
            guard let name = array.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
                throw CLIError.usage("usage: kitterm token create <name> [--watch]")
            }
            guard TokenStore.isValidName(name) else {
                throw CLIError.usage(
                    "invalid token name \"\(name)\" (letters, digits, . _ -, ≤\(TokenStore.maxNameLength) chars)"
                )
            }
            var tokens = TokenStore.load()
            guard !tokens.contains(where: { $0.name == name }) else {
                throw CLIError.usage("token \"\(name)\" already exists — revoke it first")
            }
            let grade: TokenGrade = hasFlag("--watch", array) ? .watch : .full
            let token = TokenStore.generate(grade: grade)
            tokens.append(
                NamedToken(name: name, hash: TokenStore.hash(token), grade: grade, created: Date())
            )
            try TokenStore.save(tokens)
            print(token)
            let hint = grade == .watch
                ? "watch-only: can observe sessions and read the API, never type or take control"
                : "full access"
            FileHandle.standardError.write(Data("""
            token "\(name)" created (\(hint)).
            Shown once — only its hash is stored. Use on another device:
              http://<lan-ip>:<port>/sessions?token=\(token)
            Revoke anytime with: kitterm token revoke \(name)

            """.utf8))
        case "list":
            let tokens = TokenStore.load()
            if tokens.isEmpty {
                print("no named tokens — create one with: kitterm token create <name> [--watch]")
                return
            }
            let formatter = ISO8601DateFormatter()
            for token in tokens.sorted(by: { $0.created < $1.created }) {
                let created = token.created == .distantPast
                    ? "-"
                    : formatter.string(from: token.created)
                print("\(token.name)\t\(token.grade.rawValue)\t\(created)")
            }
        case "revoke":
            guard let name = array.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
                throw CLIError.usage("usage: kitterm token revoke <name>")
            }
            var tokens = TokenStore.load()
            guard tokens.contains(where: { $0.name == name }) else {
                throw CLIError.usage("no token named \"\(name)\" (see: kitterm token list)")
            }
            tokens.removeAll { $0.name == name }
            try TokenStore.save(tokens)
            print("revoked \"\(name)\" — applies to a running daemon immediately")
        default:
            throw CLIError.usage("usage: kitterm token create <name> [--watch] | list | revoke <name>")
        }
    }

    private static func printUsage() {
        print(
            """
            kitterm — Mac loopback terminal daemon

            Usage:
              kitterm start [--port PORT] [--lan] [--record] [--agent-control]
                            [--trusted-host NAME] [--tls-cert FILE --tls-key FILE [--tls-port PORT]]
              kitterm stop
              kitterm status
              kitterm restart [same flags as start]
              kitterm open [PATH]     # browser shell in PATH (default: cwd)
              kitterm service install [same flags as start]
              kitterm service uninstall | status
              kitterm upgrade         # install the latest release
              kitterm integrate [zsh|bash]  # print the OSC 133/633 snippet
              kitterm token create <name> [--watch] | list | revoke <name>
              kitterm version

            service install starts kitterm on login via a LaunchAgent.

            --lan binds all interfaces; non-loopback clients need a token:
            the ephemeral one printed at start (~/.kitterm/token), the
            watch-only one (~/.kitterm/token-watch, observers who can never
            type or take control), or a named token from `kitterm token`
            (hashed, persistent, revocable without restart).
            --tls-cert/--tls-key add an encrypted listener on PORT+1 (or
            --tls-port) for other devices, while the plain listener stays on
            loopback. Bring a real certificate — `tailscale cert <name>` is
            free and publicly trusted; kitterm never generates one.
            --trusted-host NAME lets the daemon answer to a public name behind
            a reverse proxy or on an overlay network (repeatable). Those
            requests are treated as remote: they must present a token, so the
            proxy cannot become an unauthenticated way in.
            --record writes each session to ~/.kitterm/recordings/*.cast
            (asciinema v2 — replay with `asciinema play`).
            --agent-control enables POST /api/sessions/<id>/input, letting any
            client the access policy admits type into any shell as your user.

            integrate prints shell integration for shells without native
            OSC 133 marks. Local: kitterm integrate >> ~/.zshrc
            Remote VM/container: kitterm integrate bash | ssh vm 'cat >> ~/.bashrc'

            Session profiles (~/.kitterm/profiles.json) name connect commands
            run at session start — open /?profile=<name> or use /sessions:
              { "profiles": [ { "name": "vm", "command": "ssh dev-vm" } ] }

            Default port: \(KittermConstants.defaultPort)
            State: ~/.kitterm/{pid,port,server.log}
            Browser: http://kitterm.localhost:<port>/ (after Web/terminal build)
            """
        )
    }

    private static func hasFlag<S: Sequence>(_ flag: String, _ args: S) -> Bool
    where S.Element == String {
        args.contains(flag)
    }

    /// `--trusted-host <name>` (repeatable, or `--trusted-host=<name>`): the
    /// public names this daemon answers to behind a proxy or on an overlay
    /// network. Requests naming one are treated as remote and need a token.
    /// `--name value` or `--name=value`.
    static func parseOption<S: Sequence>(_ name: String, _ args: S) -> String?
    where S.Element == String {
        let array = Array(args)
        for (index, arg) in array.enumerated() {
            if arg == name, index + 1 < array.count, !array[index + 1].hasPrefix("--") {
                return array[index + 1]
            }
            if arg.hasPrefix("\(name)=") {
                let value = String(arg.dropFirst(name.count + 1))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func parseTrustedHosts<S: Sequence>(_ args: S) -> Set<String>
    where S.Element == String {
        var hosts: Set<String> = []
        let array = Array(args)
        var i = 0
        while i < array.count {
            if array[i] == "--trusted-host", i + 1 < array.count, !array[i + 1].hasPrefix("--") {
                hosts.insert(array[i + 1])
                i += 2
                continue
            }
            if array[i].hasPrefix("--trusted-host=") {
                let value = String(array[i].dropFirst("--trusted-host=".count))
                if !value.isEmpty { hosts.insert(value) }
            }
            i += 1
        }
        return hosts
    }

    private static func parsePort<S: Sequence>(_ args: S) -> Int where S.Element == String {
        var port = KittermConstants.defaultPort
        let array = Array(args)
        var i = 0
        while i < array.count {
            if array[i] == "--port", i + 1 < array.count, let value = Int(array[i + 1]) {
                port = value
                i += 2
                continue
            }
            if array[i].hasPrefix("--port="), let value = Int(array[i].dropFirst(7)) {
                port = value
            }
            i += 1
        }
        return port
    }

    private static func serve(port: Int, flags: DaemonFlags) throws {
        try DaemonPaths.ensureStateDirectory()
        redirectLogs(to: DaemonPaths.logFile)

        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(to: DaemonPaths.pidFile, atomically: true, encoding: .utf8)
        try "\(port)".write(to: DaemonPaths.portFile, atomically: true, encoding: .utf8)

        try runDaemon(config: flags.daemonConfig(port: port))
    }

    /// Both listeners, labelled, after a successful start.
    private static func printListeners(port: Int, flags: DaemonFlags) {
        print("Local:  http://kitterm.localhost:\(port)/  (loopback only)")
        if let tlsPort = try? flags.tlsConfig(port: port)?.port {
            let host = flags.trustedHosts.sorted().first ?? "<your-host>"
            print("Remote: https://\(host):\(tlsPort)/  (TLS)")
            if flags.trustedHosts.isEmpty {
                print("        add --trusted-host <name-on-your-certificate> so share links are correct")
            }
            if let token = awaitToken() {
                print("Token:  \(token)")
            }
        }
    }

    /// `kitterm restart` — restarts whichever mechanism owns the daemon.
    private static func restart<S: Sequence>(_ args: S) throws where S.Element == String {
        let array = Array(args)
        if serviceLoaded() {
            // The service's plist is the configuration of record; restarting
            // with different flags must go through `service install`.
            guard array.isEmpty else {
                throw CLIError.serviceFailed(
                    action: "restart",
                    detail: "the kitterm service manages the daemon; to change flags run: kitterm service install \(array.joined(separator: " "))"
                )
            }
            let result = launchctl(["kickstart", "-k", "gui/\(getuid())/\(serviceLabel)"])
            guard result.status == 0 else {
                throw CLIError.serviceFailed(
                    action: "launchctl kickstart",
                    detail: result.output.isEmpty ? "launchctl exited \(result.status)" : result.output
                )
            }
            let port = readPort() ?? KittermConstants.defaultPort
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if isHealthy(port: port) {
                    print("kitterm service restarted (port \(port))")
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw CLIError.serviceFailed(
                action: "restart",
                detail: "service restarted but the daemon is not healthy on port \(port); see ~/.kitterm/server.log"
            )
        }
        try stop(ignoreMissing: true)
        try start(
            parsePort(array),
            flags: DaemonFlags.parse(array)
        )
    }

    private static func start(
        _ port: Int,
        flags: DaemonFlags,
        openBrowser: Bool = true
    ) throws {
        // Validate here, in the terminal the user is looking at: `serve`
        // redirects its own output to ~/.kitterm/server.log, so a bad flag or
        // an unreadable certificate would otherwise fail invisibly and only
        // surface as "daemon exited before becoming healthy".
        if let tls = try flags.tlsConfig(port: port) {
            _ = try tls.makeSSLContext()
        }
        try DaemonPaths.ensureStateDirectory()
        if let existing = livePid() {
            print("kitterm already running (pid \(existing), port \(readPort() ?? port))")
            return
        }
        if serviceLoaded() {
            // The agent owns the daemon (it may be mid-respawn right now);
            // a detached competitor would just fight it for the port.
            throw CLIError.serviceFailed(
                action: "start",
                detail: "the kitterm service manages the daemon; use `kitterm restart`, `kitterm service install` to reconfigure, or `kitterm service uninstall` to remove it"
            )
        }

        if let occupant = portListenerDescription(port: port) {
            throw CLIError.portInUse(port: port, occupant: occupant)
        }

        let executable = ResolveExecutable.path()
        // Prefer posix_spawn-style detach: serve redirects its own logs.
        // Avoid wiring parent FileHandles into the child — that has broken
        // forkpty in practice on macOS when stdio is inherited from Process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["serve", "--port", "\(port)"] + flags.serveArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Wait briefly for health.
        let deadline = Date().addingTimeInterval(3)
        var healthy = false
        while Date() < deadline {
            if isHealthy(port: port) {
                healthy = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if !healthy, !process.isRunning {
            if let occupant = portListenerDescription(port: port) {
                throw CLIError.portInUse(port: port, occupant: occupant)
            }
            throw CLIError.daemonExited
        }
        if !healthy {
            throw CLIError.daemonExited
        }

        // Prefer pid file written by serve; fall back to process pid.
        if livePid() == nil {
            try "\(process.processIdentifier)".write(
                to: DaemonPaths.pidFile,
                atomically: true,
                encoding: .utf8
            )
            try "\(port)".write(to: DaemonPaths.portFile, atomically: true, encoding: .utf8)
        }

        let pid = livePid() ?? process.processIdentifier
        let plainlyExternal = flags.lan && flags.tlsCert == nil
        print("kitterm started on \(plainlyExternal ? "0.0.0.0" : KittermConstants.defaultHost):\(port) (pid \(pid))")
        if flags.tlsCert != nil {
            printListeners(port: port, flags: flags)
            if flags.lan {
                print("(--lan is redundant with TLS: plaintext stays on loopback)")
            }
        } else if flags.lan {
            printLANAccess(port: port)
        }
        if !flags.trustedHosts.isEmpty, flags.tlsCert == nil {
            printProxyAccess(port: port, hosts: flags.trustedHosts)
        }
        if openBrowser {
            openBrowserIfPossible(port: port)
        }
    }

    /// The daemon writes the token at bind time; give it a moment.
    private static func awaitToken() -> String? {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let token = (try? String(contentsOf: DaemonPaths.tokenFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let token, !token.isEmpty { return token }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    /// Behind a proxy / on an overlay network the daemon stays on loopback,
    /// so the useful line is the public name plus the token those requests
    /// must carry — they get no local trust.
    private static func printProxyAccess(port: Int, hosts: Set<String>) {
        for host in hosts.sorted() {
            print("Trusted host: \(host) (requests naming it need a token)")
        }
        if let token = awaitToken() {
            print("Token: \(token)  — append ?token=<token> once; a cookie carries it after that")
        } else {
            print("Token: see ~/.kitterm/token")
        }
        print("Point your proxy or `tailscale serve` at http://127.0.0.1:\(port)")
    }

    /// Best-effort LAN URL with the auth token for other devices.
    private static func printLANAccess(port: Int) {
        guard let token = awaitToken() else {
            print("LAN token: see ~/.kitterm/token")
            return
        }
        let ip = lanIPAddress() ?? "<lan-ip>"
        print("LAN access: http://\(ip):\(port)/?token=\(token)")
        print("(anyone with this link gets a shell as your user — share carefully)")
        // Plaintext HTTP: the token and every keystroke cross the network in
        // the clear, so the warning belongs next to the link, not only in the
        // README. Browsers also withhold the clipboard API from non-HTTPS LAN
        // origins, which silently disables copy/paste in the terminal there.
        print("WARNING: plain HTTP — token and keystrokes are unencrypted on this network.")
        print("         Trusted networks only; prefer an SSH tunnel or a private overlay network.")
    }

    private static func lanIPAddress() -> String? {
        for interface in ["en0", "en1"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
            process.arguments = ["getifaddr", interface]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let ip = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !ip.isEmpty {
                return ip
            }
        }
        return nil
    }

    /// `kitterm open [path]` — new browser shell in the given directory.
    private static func openShell(at rawPath: String?) throws {
        let fm = FileManager.default
        let base = rawPath ?? fm.currentDirectoryPath
        let expanded: String
        if base == "~" {
            expanded = fm.homeDirectoryForCurrentUser.path
        } else if base.hasPrefix("~/") {
            expanded = fm.homeDirectoryForCurrentUser.path + String(base.dropFirst(1))
        } else if base.hasPrefix("/") {
            expanded = base
        } else {
            expanded = URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent(base).standardizedFileURL.path
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.notADirectory(path: expanded)
        }

        let port = readPort() ?? KittermConstants.defaultPort
        if livePid() == nil {
            try start(port, flags: DaemonFlags(), openBrowser: false)
        }

        var components = URLComponents(string: "http://kitterm.localhost:\(port)/")!
        components.queryItems = [URLQueryItem(name: "cwd", value: expanded)]
        let url = components.url!.absoluteString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        try process.run()
        print("opened \(url)")
    }

    /// Opens the browser client when a built web UI is available. Best-effort; never fails start.
    private static func openBrowserIfPossible(port: Int) {
        let url = "http://kitterm.localhost:\(port)/"
        // Only auto-open when static assets exist (production serve path).
        guard StaticFileServer.resolveRoot() != nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - LaunchAgent (opt-in auto-start)

    private static let serviceLabel = "com.kitterm.daemon"

    private static var launchAgentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(serviceLabel).plist")
    }

    private static func service<S: Sequence>(_ args: S) throws where S.Element == String {
        let array = Array(args)
        switch array.first ?? "status" {
        case "install":
            try installService(port: parsePort(array), flags: DaemonFlags.parse(array))
        case "uninstall":
            try uninstallService()
        case "status":
            serviceStatus()
        default:
            fputs("usage: kitterm service install|uninstall|status\n", stderr)
            exit(2)
        }
    }

    /// True when the LaunchAgent is bootstrapped into the user's gui session.
    private static func serviceLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(serviceLabel)"]).status == 0
    }

    /// The executable path a login agent can outlive: absolute, existing, and
    /// preferring the stable `<prefix>/bin/kitterm` wrapper over the internal
    /// `<prefix>/lib/kitterm/kitterm` it execs (both resolve helper + web root).
    private static func serviceExecutablePath() throws -> String {
        let raw = ResolveExecutable.path()
        guard raw.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: raw) else {
            throw CLIError.serviceFailed(
                action: "service install",
                detail: "cannot resolve an absolute path to the kitterm binary (got \"\(raw)\"); run kitterm via its installed path"
            )
        }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        if url.deletingLastPathComponent().lastPathComponent == "kitterm",
           url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "lib" {
            let wrapper = url
                .deletingLastPathComponent()  // lib/kitterm
                .deletingLastPathComponent()  // lib
                .deletingLastPathComponent()  // prefix
                .appendingPathComponent("bin/kitterm")
            if FileManager.default.isExecutableFile(atPath: wrapper.path) {
                return wrapper.path
            }
        }
        if url.pathComponents.contains(".build") {
            print("warning: installing service with a build-tree binary (\(url.path));")
            print("         the agent breaks if the build directory is cleaned or moved")
        }
        return url.path
    }

    // MARK: - Upgrade

    /// The install prefix this binary lives under, or nil for a dev/unknown
    /// layout. Installed layout is always `<prefix>/lib/kitterm/kitterm`.
    private static func installedPrefix() -> URL? {
        let url = URL(fileURLWithPath: ResolveExecutable.path()).standardizedFileURL
        guard
            url.deletingLastPathComponent().lastPathComponent == "kitterm",
            url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "lib"
        else {
            return nil
        }
        return url
            .deletingLastPathComponent()  // lib/kitterm
            .deletingLastPathComponent()  // lib
            .deletingLastPathComponent()  // prefix
    }

    /// Version string packaged at `<prefix>/share/kitterm/VERSION`, or nil.
    private static func installedVersion() -> String? {
        guard let prefix = installedPrefix() else { return nil }
        let file = prefix.appendingPathComponent("share/kitterm/VERSION")
        return (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reinstall the latest release into this binary's own prefix by running the
    /// official installer, which handles checksum, quarantine, and the
    /// stop→swap→restart of a service-managed daemon.
    private static func upgrade() throws {
        guard let prefix = installedPrefix() else {
            throw CLIError.upgradeUnavailable(
                detail: "kitterm is not running from an installed location "
                    + "(\(ResolveExecutable.path())). Reinstall from https://kitterm.dev instead."
            )
        }

        print("current version: \(installedVersion() ?? "unknown")")
        print("installing the latest release into \(prefix.path) …")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "curl -fsSL https://kitterm.dev/install.sh | sh"]
        var environment = ProcessInfo.processInfo.environment
        environment["KITTERM_PREFIX"] = prefix.path
        process.environment = environment
        // Inherit stdio so the installer's progress streams straight through.

        do {
            try process.run()
        } catch {
            throw CLIError.upgradeFailed(detail: error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError.upgradeFailed(
                detail: "installer exited with status \(process.terminationStatus)"
            )
        }
    }

    private static func installService(
        port: Int,
        flags: DaemonFlags
    ) throws {
        let executable = try serviceExecutablePath()
        let plist = launchAgentPlist
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // A foreground `serve` under launchd — KeepAlive restarts it on crash.
        let programArgs = [executable, "serve", "--port", "\(port)"] + flags.serveArguments

        let entries = programArgs
            .map { "\t\t<string>\(xmlEscaped($0))</string>" }
            .joined(separator: "\n")

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(serviceLabel)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \(entries)
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>ProcessType</key>
        \t<string>Background</string>
        </dict>
        </plist>

        """.write(to: plist, atomically: true, encoding: .utf8)

        // Replacing an existing agent requires unloading it first; do it before
        // the pid-file stop so KeepAlive can't respawn what we just stopped.
        _ = launchctl(["bootout", "gui/\(getuid())/\(serviceLabel)"])
        // A manually started daemon would hold the port against the agent.
        try? stop(ignoreMissing: true, quiet: true)

        // A foreign listener would leave the agent crash-looping on bind.
        if let occupant = portListenerDescription(port: port) {
            throw CLIError.portInUse(port: port, occupant: occupant)
        }

        // Clear any persisted disabled state (System Settings toggle, or a past
        // `launchctl disable`) — otherwise bootstrap fails with error 119.
        _ = launchctl(["enable", "gui/\(getuid())/\(serviceLabel)"])

        let result = launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        guard result.status == 0 else {
            throw CLIError.serviceFailed(
                action: "launchctl bootstrap",
                detail: result.output.isEmpty ? "launchctl exited \(result.status)" : result.output
            )
        }

        // bootstrap only loads the job; confirm the daemon actually serves.
        let deadline = Date().addingTimeInterval(3)
        var healthy = false
        while Date() < deadline {
            if isHealthy(port: port) {
                healthy = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard healthy else {
            throw CLIError.serviceFailed(
                action: "service start",
                detail: "agent loaded but the daemon is not healthy on port \(port); see ~/.kitterm/server.log"
            )
        }

        print("kitterm service installed — starts on login (port \(port))")
        print("plist: \(plist.path)")
        print("disable with: kitterm service uninstall")
    }

    private static func uninstallService() throws {
        // Bootout first, unconditionally: the job can be loaded even when the
        // plist file is gone (deleted by hand), and would otherwise keep
        // KeepAlive-respawning until logout.
        let bootout = launchctl(["bootout", "gui/\(getuid())/\(serviceLabel)"])
        let plist = launchAgentPlist
        let hadPlist = FileManager.default.fileExists(atPath: plist.path)
        if hadPlist {
            try FileManager.default.removeItem(at: plist)
        }
        if hadPlist || bootout.status == 0 {
            print("kitterm service uninstalled")
        } else {
            print("kitterm service is not installed")
        }
    }

    private static func serviceStatus() {
        guard FileManager.default.fileExists(atPath: launchAgentPlist.path) else {
            print("kitterm service not installed")
            return
        }
        let result = launchctl(["print", "gui/\(getuid())/\(serviceLabel)"])
        if result.status == 0 {
            print("kitterm service installed and loaded (\(launchAgentPlist.path))")
        } else {
            print("kitterm service installed but not loaded (\(launchAgentPlist.path))")
        }
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        // Read before waiting: launchctl output is small, but a full pipe
        // buffer would deadlock the child against waitUntilExit().
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func stop(ignoreMissing: Bool = false, quiet: Bool = false) throws {
        // A launchd-managed daemon must be booted out, not signalled —
        // KeepAlive would respawn it within seconds of a plain SIGTERM.
        var wasService = false
        if serviceLoaded() {
            wasService = true
            _ = launchctl(["bootout", "gui/\(getuid())/\(serviceLabel)"])
        }

        guard let pid = livePid() else {
            if wasService, !quiet {
                print("kitterm service stopped (unloaded until next login; `kitterm service uninstall` removes it)")
            } else if !ignoreMissing, !quiet {
                print("kitterm is not running")
            }
            return
        }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, kill(pid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: DaemonPaths.pidFile)
        if quiet { return }
        if wasService {
            print("kitterm stopped (was pid \(pid); service unloaded until next login — `kitterm service uninstall` removes it)")
        } else {
            print("kitterm stopped (was pid \(pid))")
        }
    }

    private static func status() throws {
        if let pid = livePid() {
            let port = readPort() ?? KittermConstants.defaultPort
            let health = isHealthy(port: port) ? "healthy" : "process alive, health check failed"
            print("kitterm running pid=\(pid) port=\(port) (\(health))")
        } else {
            print("kitterm not running")
            exit(1)
        }
    }

    private static func livePid() -> pid_t? {
        guard let text = try? String(contentsOf: DaemonPaths.pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else {
            return nil
        }
        if kill(pid, 0) == 0 {
            return pid
        }
        try? FileManager.default.removeItem(at: DaemonPaths.pidFile)
        return nil
    }

    private static func readPort() -> Int? {
        guard let text = try? String(contentsOf: DaemonPaths.portFile, encoding: .utf8) else {
            return nil
        }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isHealthy(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else {
            return false
        }
        var request = URLRequest(url: url, timeoutInterval: 0.3)
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { sem.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true
            else { return }
            ok = true
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 0.4)
        return ok
    }

    private static func redirectLogs(to url: URL) {
        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        if fd > STDERR_FILENO {
            close(fd)
        }
    }

    /// Best-effort `lsof` summary of whoever is listening on the port.
    private static func portListenerDescription(port: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }
        let lines = text.split(separator: "\n")
        guard lines.count >= 2 else { return text }
        // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        let cols = lines[1].split(whereSeparator: { $0.isWhitespace })
        if cols.count >= 2 {
            return "\(cols[0]) (pid \(cols[1]))"
        }
        return String(lines[1])
    }
}

enum CLIError: Error, LocalizedError {
    case daemonExited
    case portInUse(port: Int, occupant: String)
    case notADirectory(path: String)
    case serviceFailed(action: String, detail: String)
    case upgradeUnavailable(detail: String)
    case upgradeFailed(detail: String)
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .serviceFailed(let action, let detail):
            return "\(action) failed: \(detail)"
        case .daemonExited:
            return "daemon exited before becoming healthy; see ~/.kitterm/server.log"
        case .portInUse(let port, let occupant):
            return """
            port \(port) is already in use by \(occupant). \
            Stop that process, or run: kitterm start --port <other>
            """
        case .notADirectory(let path):
            return "not a directory: \(path)"
        case .upgradeUnavailable(let detail):
            return "cannot upgrade: \(detail)"
        case .upgradeFailed(let detail):
            return "upgrade failed: \(detail)"
        case .usage(let detail):
            return detail
        }
    }
}

enum ResolveExecutable {
    static func path() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            return arg0
        }
        if arg0.contains("/") {
            let cwd = FileManager.default.currentDirectoryPath
            return URL(fileURLWithPath: cwd).appendingPathComponent(arg0).path
        }
        // Look up on PATH
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(arg0).path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return arg0
    }
}
