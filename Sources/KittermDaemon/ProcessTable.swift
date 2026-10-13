#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// The user's processes and their listening TCP sockets, read from the
/// kernel in one pass (`running-servers` round 1). `GET /api/servers` is
/// built from this table by `ListeningServers`.
///
/// On Darwin the read is libproc: `proc_listpids` for every pid,
/// `PROC_PIDTBSDINFO` for each one's parent, owner and controlling tty,
/// and for the user's own pids `PROC_PIDLISTFDS` then
/// `PROC_PIDFDSOCKETINFO` per socket, keeping the TCP sockets in the
/// `LISTEN` state. No `lsof`, no `netstat`: every call is a kernel read
/// with no subprocess. On Linux `read` answers nil with `linuxReason`;
/// reading `/proc` is a later goal.
public struct ProcessTable: Sendable {
    /// One process: its parent, its owner, the device of its controlling
    /// tty (nil when it has none) and when it started.
    public struct Process: Equatable, Sendable {
        public var pid: pid_t
        public var ppid: pid_t
        public var uid: uid_t
        public var tty: UInt32?
        public var startedAt: Date?

        public init(pid: pid_t, ppid: pid_t, uid: uid_t, tty: UInt32?, startedAt: Date? = nil) {
            self.pid = pid
            self.ppid = ppid
            self.uid = uid
            self.tty = tty
            self.startedAt = startedAt
        }
    }

    /// One listening TCP socket: the pid that holds it, its port and the
    /// address it binds (`127.0.0.1`, `0.0.0.0`, `::1`, `::`, or a
    /// specific address).
    public struct Listener: Equatable, Sendable {
        public var pid: pid_t
        public var port: Int
        public var address: String

        public init(pid: pid_t, port: Int, address: String) {
            self.pid = pid
            self.port = port
            self.address = address
        }
    }

    public static let linuxReason = "reading /proc is not implemented on Linux"

    public var processes: [pid_t: Process]
    public var listeners: [Listener]
    /// The name a process was started under, by the `foregroundProgram`
    /// rule (`argv[0]`, else the executable's basename); nil for a pid the
    /// kernel can no longer name. A closure so a test hands in a table
    /// with names and the live read asks the kernel only for the pids a
    /// row needs.
    public var name: @Sendable (pid_t) -> String?
    /// A process's working directory, nil for a reaped pid or any failure.
    public var cwd: @Sendable (pid_t) -> String?
    /// The `KITTERM_SESSION_ID` a process carries in its environment
    /// (`running-servers` round 3): the pane's shell exported it, and a
    /// server keeps it after it leaves the terminal and its starter exits.
    /// Nil for a process with none, a reaped pid or any failure.
    public var sessionID: @Sendable (pid_t) -> String?

    public static let sessionVariable = "KITTERM_SESSION_ID"

    public init(
        processes: [pid_t: Process], listeners: [Listener],
        name: @escaping @Sendable (pid_t) -> String?,
        cwd: @escaping @Sendable (pid_t) -> String?,
        sessionID: @escaping @Sendable (pid_t) -> String? = { _ in nil }
    ) {
        self.processes = processes
        self.listeners = listeners
        self.name = name
        self.cwd = cwd
        self.sessionID = sessionID
    }

    /// The live table, or nil with the reason on a platform with no reader.
    public static func read() -> (table: ProcessTable?, reason: String?) {
        #if canImport(Darwin)
        return (readDarwin(), nil)
        #else
        return (nil, linuxReason)
        #endif
    }

    #if canImport(Darwin)
    /// `e_tdev` of a process with no controlling tty.
    private static let noDevice = UInt32.max

    static func readDarwin() -> ProcessTable {
        let uid = getuid()
        var processes: [pid_t: Process] = [:]
        var listeners: [Listener] = []
        for pid in allPids() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let tty = info.e_tdev == noDevice ? nil : info.e_tdev
            let started = Date(
                timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
            processes[pid] = Process(
                pid: pid, ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid, tty: tty, startedAt: started)
            // Another user's descriptors are not readable, so the call is
            // not made.
            guard info.pbi_uid == uid else { continue }
            listeners.append(contentsOf: listeningSockets(of: pid))
        }
        return ProcessTable(
            processes: processes, listeners: listeners,
            name: { pid in
                PtySession.invocationName(ofPID: pid)
                    ?? PtySession.executablePath(ofPID: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
            },
            cwd: { pid in PtySession.currentDirectory(ofPID: pid) },
            sessionID: { pid in PtySession.environmentValue(ofPID: pid, name: sessionVariable) }
        )
    }

    private static func allPids() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        // Slack for the processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 64)
        let filled = pids.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }
        return Array(pids[0..<Int(filled) / MemoryLayout<pid_t>.stride]).filter { $0 > 0 }
    }

    /// The TCP sockets of `pid` in the `LISTEN` state.
    private static func listeningSockets(of pid: pid_t) -> [Listener] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let filled = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }
        var found: [Listener] = []
        for fd in fds[0..<Int(filled) / stride] where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size else { continue }
            guard socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            var inet = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)))
            guard let address = localAddress(&inet) else { continue }
            found.append(Listener(pid: pid, port: port, address: address))
        }
        return found
    }

    private static func localAddress(_ inet: inout in_sockinfo) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet.insi_vflag & UInt8(INI_IPV6) != 0 {
            var addr = inet.insi_laddr.ina_6
            guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else {
            var addr = inet.insi_laddr.ina_46.i46a_addr4
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        }
        return String(cString: buffer)
    }
    #endif
}
