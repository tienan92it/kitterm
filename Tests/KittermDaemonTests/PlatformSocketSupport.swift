#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The raw-socket helpers in the route tests open a TCP socket by hand. Two
// spellings differ between the C libraries, so they are chosen once here
// (the `Sources/KittermDaemon/PlatformSyscalls.swift` pattern) and the tests
// call the wrappers.

/// `SOCK_STREAM` is an `Int32` on Darwin and a `__socket_type` enum on Glibc.
#if canImport(Darwin)
let streamSocketType = SOCK_STREAM
#else
let streamSocketType = Int32(SOCK_STREAM.rawValue)
#endif

/// `bind`, `connect` and `send` are qualified with the C library module where
/// a test's own names shadow them; that module is `Darwin` on macOS and
/// `Glibc` on Linux.
func systemBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.bind(fd, address, length)
    #else
    return Glibc.bind(fd, address, length)
    #endif
}

func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, length)
    #else
    return Glibc.connect(fd, address, length)
    #endif
}

func systemSend(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ flags: Int32) -> Int {
    #if canImport(Darwin)
    return Darwin.send(fd, buffer, count, flags)
    #else
    return Glibc.send(fd, buffer, count, flags)
    #endif
}
