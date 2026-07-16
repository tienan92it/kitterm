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
                try start(parsePort(args.dropFirst()))
            case "stop":
                try stop()
            case "status":
                try status()
            case "restart":
                try stop(ignoreMissing: true)
                try start(parsePort(args.dropFirst()))
            case "serve":
                // Internal: foreground daemon process.
                let port = parsePort(args.dropFirst())
                try serve(port: port)
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

    private static func printUsage() {
        print(
            """
            kitterm — Mac loopback terminal daemon

            Usage:
              kitterm start [--port PORT]
              kitterm stop
              kitterm status
              kitterm restart [--port PORT]

            Default port: \(KittermConstants.defaultPort)
            State: ~/.kitterm/{pid,port,server.log}
            Browser: http://kitterm.localhost:<port>/ (after Web/terminal build)
            """
        )
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

    private static func serve(port: Int) throws {
        try DaemonPaths.ensureStateDirectory()
        redirectLogs(to: DaemonPaths.logFile)

        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(to: DaemonPaths.pidFile, atomically: true, encoding: .utf8)
        try "\(port)".write(to: DaemonPaths.portFile, atomically: true, encoding: .utf8)

        try runDaemon(config: DaemonConfig(host: KittermConstants.defaultHost, port: port))
    }

    private static func start(_ port: Int) throws {
        try DaemonPaths.ensureStateDirectory()
        if let existing = livePid() {
            print("kitterm already running (pid \(existing), port \(readPort() ?? port))")
            return
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
        process.arguments = ["serve", "--port", "\(port)"]
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
        print("kitterm started on \(KittermConstants.defaultHost):\(port) (pid \(pid))")
        openBrowserIfPossible(port: port)
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

    private static func stop(ignoreMissing: Bool = false) throws {
        guard let pid = livePid() else {
            if ignoreMissing { return }
            print("kitterm is not running")
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
        print("kitterm stopped (was pid \(pid))")
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

    var errorDescription: String? {
        switch self {
        case .daemonExited:
            return "daemon exited before becoming healthy; see ~/.kitterm/server.log"
        case .portInUse(let port, let occupant):
            return """
            port \(port) is already in use by \(occupant). \
            Stop that process, or run: kitterm start --port <other>
            """
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
