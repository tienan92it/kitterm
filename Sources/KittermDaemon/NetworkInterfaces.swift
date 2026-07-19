import Darwin
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
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
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
