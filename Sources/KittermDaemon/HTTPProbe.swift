#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// One HTTP request to a port on this machine, to learn whether the
/// server behind it speaks HTTP (`running-servers` round 1): the fleet
/// view links such a server and prints the others as text. A
/// non-blocking connect, `HEAD / HTTP/1.0`, and the first bytes of the
/// reply, all under one timeout; a server that answers anything that
/// does not start with `HTTP/` (postgres, redis, `nc`) or nothing at all
/// is not HTTP. Blocking, so a caller runs it off the event loop;
/// `ListeningServers` does, on its own queue, and caches the verdict.
public enum HTTPProbe {
    public static let timeoutSeconds: TimeInterval = 0.5
    static let request = "HEAD / HTTP/1.0\r\nHost: localhost\r\n\r\n"

    /// The loopback address to probe for a bound address, nil for a server
    /// bound to another interface alone: the probe reaches loopback and
    /// nothing else.
    public static func loopbackTarget(for bound: String) -> String? {
        switch bound {
        case "0.0.0.0", "127.0.0.1": return "127.0.0.1"
        case "::", "::1": return "::1"
        default: return bound.hasPrefix("127.") ? bound : nil
        }
    }

    /// True when `host:port` answers the request with an HTTP status line
    /// before the timeout.
    public static func answersHTTP(host: String, port: Int, timeout: TimeInterval = timeoutSeconds) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let isV6 = host.contains(":")
        #if canImport(Darwin)
        let stream = SOCK_STREAM
        #else
        let stream = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(isV6 ? AF_INET6 : AF_INET, stream, 0)
        guard fd >= 0 else { return false }
        defer { _ = close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let connected: Bool
        if isV6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET6, host, &addr.sin6_addr) == 1 else { return false }
            connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
            connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
        if !connected {
            guard errno == EINPROGRESS, wait(fd, events: Int16(POLLOUT), until: deadline) else { return false }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return false }
        }
        let sent = request.utf8CString.withUnsafeBufferPointer { buffer -> Int in
            #if canImport(Darwin)
            return send(fd, buffer.baseAddress, buffer.count - 1, 0)
            #else
            return send(fd, buffer.baseAddress, buffer.count - 1, Int32(MSG_NOSIGNAL))
            #endif
        }
        guard sent > 0 else { return false }
        var reply = [UInt8](repeating: 0, count: 16)
        var count = 0
        while count < 5 {
            guard wait(fd, events: Int16(POLLIN), until: deadline) else { return false }
            let got = reply.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress! + count, raw.count - count, 0)
            }
            guard got > 0 else { return false }
            count += got
        }
        return reply.starts(with: Array("HTTP/".utf8))
    }

    /// Poll `fd` for `events` until `deadline`; false on a timeout or an
    /// error.
    private static func wait(_ fd: Int32, events: Int16, until deadline: Date) -> Bool {
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let left = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard left > 0 else { return false }
            let rc = poll(&pfd, 1, left)
            if rc < 0 && errno == EINTR { continue }
            guard rc > 0 else { return false }
            return pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 || pfd.revents & events != 0
        }
    }
}
