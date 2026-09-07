#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import KittermProtocol

/// The process-level half of a live upgrade (`docs/live-upgrade.md`): which
/// binary to become, whether it runs, which descriptors cross `exec`, and the
/// `exec` itself. `DaemonServer` owns the quiesce and the state; this owns
/// nothing but syscalls.
public enum TakeoverHandoff: Sendable {
    /// The binary a takeover execs: `<prefix>/lib/kitterm/kitterm` when this
    /// process runs from an install, which is where `kitterm upgrade` stages
    /// the new build, else this process's own executable (a build tree or a
    /// test, which execs into itself).
    public static func targetExecutable() -> String {
        let own = resolvedExecutable()
        if let prefix = InstallLayout.prefix(forExecutable: own) {
            return prefix.appendingPathComponent("lib/kitterm/kitterm").path
        }
        return own
    }

    /// argv[0] as an absolute path: `exec` needs a path, and the successor
    /// finds its helper and its version through its own argv[0].
    public static func resolvedExecutable() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") { return arg0 }
        if arg0.contains("/") {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(arg0).standardizedFileURL.path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(arg0).path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return arg0
    }

    /// Run `<executable> --help` and report why it cannot run, or nil when it
    /// can. The installer smoke-tests the download before it installs; this
    /// covers a binary damaged since. Blocking: call it off the event loop.
    public static func validate(executable: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return "\(executable) is not an executable file"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--help"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "\(executable) failed to start: \(error.localizedDescription)"
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return "\(executable) --help exited \(process.terminationStatus)"
        }
        return nil
    }

    /// Mark every descriptor above stderr close-on-exec except the carried
    /// ones, which are cleared. swift-nio sets no close-on-exec on the
    /// sockets it opens on Darwin, so a listener or an accepted connection
    /// not fully closed by quiesce would otherwise follow the process into
    /// its next image and could hold the port.
    public static func prepareDescriptors(carrying carried: [Int32]) {
        let keep = Set(carried)
        for fd in Int32(3)..<descriptorLimit() {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0 else { continue }
            if keep.contains(fd) {
                _ = fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC)
            } else if flags & FD_CLOEXEC == 0 {
                _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
            }
        }
    }

    /// Put close-on-exec back on the carried descriptors after an `exec`
    /// that returned: the process keeps serving from them, and a spawned
    /// helper must not inherit them.
    public static func restoreDescriptors(carried: [Int32]) {
        for fd in carried {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0 else { continue }
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    /// Replace this process with `executable`. Returns only on failure, with
    /// `errno`; the process is then exactly as it was before the call.
    public static func exec(executable: String, arguments: [String]) -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }
        errno = 0
        _ = execv(executable, &argv)
        return errno
    }

    /// The successor's argv (after argv[0]): the predecessor's own, less any
    /// `--takeover` pair it was itself started with, plus the new directory.
    /// A takeover that follows a takeover must not carry a stale directory.
    public static func successorArguments(from arguments: [String], directory: URL) -> [String] {
        var out: [String] = []
        var skip = false
        for argument in arguments {
            if skip { skip = false; continue }
            if argument == "--takeover" { skip = true; continue }
            if argument.hasPrefix("--takeover=") { continue }
            out.append(argument)
        }
        out.append(contentsOf: ["--takeover", directory.path])
        return out
    }

    private static func descriptorLimit() -> Int32 {
        #if canImport(Darwin)
        return Int32(getdtablesize())
        #else
        let limit = sysconf(Int32(_SC_OPEN_MAX))
        return limit > 0 ? Int32(min(limit, 1 << 20)) : 65536
        #endif
    }
}
