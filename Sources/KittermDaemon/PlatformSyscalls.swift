#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Syscalls whose bare names collide with something else in scope.
///
/// `write` is the case that matters: `PtySession` has a `write` method, so an
/// unqualified call resolves to it. Qualifying with the C library module is not
/// portable — it is `Darwin` on macOS and `Glibc` on Linux — so the choice is
/// made once here rather than at every call site.
@inlinable
func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer!, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(descriptor, buffer, count)
    #else
    return Glibc.write(descriptor, buffer, count)
    #endif
}
