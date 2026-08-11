#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

enum NetworkInterfaces {
    /// First non-loopback IPv4 address, preferring Wi-Fi/Ethernet (`enX`,
    /// lowest index first).
    static func primaryLANIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var best: (name: String, ip: String)?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            // `ifa_flags` is UInt32 on Darwin and Int32 on Linux, so widen
            // both to the same type before masking.
            let flags = Int32(bitPattern: UInt32(current.pointee.ifa_flags))
            guard (flags & Int32(IFF_UP)) != 0,
                  (flags & Int32(IFF_LOOPBACK)) == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                // `sa_len` is a BSD field; Linux has no length in sockaddr, so
                // the size comes from the family, which is already known to be
                // IPv4 here.
                socklen_t(MemoryLayout<sockaddr_in>.size),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let name = String(cString: current.pointee.ifa_name)
            let ip = String(cString: host)
            if name.hasPrefix("en") {
                if let existing = best, existing.name.hasPrefix("en"), existing.name <= name {
                    continue
                }
                best = (name, ip)
            } else if best == nil {
                best = (name, ip)
            }
        }
        return best?.ip
    }
}
