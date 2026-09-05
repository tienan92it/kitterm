// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kitterm",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "KittermProtocol", targets: ["KittermProtocol"]),
        .library(name: "KittermDaemon", targets: ["KittermDaemon"]),
        .executable(name: "kitterm", targets: ["KittermCLI"]),
        .executable(name: "kitterm-spawn-helper", targets: ["KittermSpawnHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
        // TLS for the optional external listener only; the loopback listener
        // never sees this handler.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        // Token hashing where CryptoKit does not exist. Linked on Linux only,
        // so macOS keeps using the system framework and gains no binary.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "KittermProtocol"
        ),
        .executableTarget(
            name: "KittermSpawnHelper",
            path: "Sources/KittermSpawnHelper"
        ),
        .target(
            name: "KittermDaemon",
            dependencies: [
                "KittermProtocol",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ]
        ),
        // The bounded terminal renderer behind `read_screen`. Only the CLI
        // links it: the daemon does not emulate a terminal (ADR 0001), and
        // keeping it out of KittermDaemon's dependencies is what enforces that.
        .target(
            name: "KittermScreen"
        ),
        .executableTarget(
            name: "KittermCLI",
            dependencies: [
                "KittermDaemon",
                "KittermProtocol",
                "KittermScreen",
            ]
        ),
        .testTarget(
            name: "KittermProtocolTests",
            dependencies: ["KittermProtocol"]
        ),
        .testTarget(
            name: "KittermScreenTests",
            dependencies: ["KittermScreen"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "KittermDaemonTests",
            dependencies: [
                "KittermDaemon",
                "KittermSpawnHelper",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "KittermCLITests",
            dependencies: ["KittermCLI"]
        ),
    ]
)

// The benchmark drives the daemon over a WebSocket with URLSessionWebSocketTask,
// which swift-corelibs-foundation does not implement — so on Linux it is left
// out rather than breaking `swift build` for the daemon it is meant to measure.
// Benchmarking still happens on macOS, against a Linux daemon if you point it
// at one with `--port`.
#if !os(Linux)
package.products.append(
    .executable(name: "KittermBench", targets: ["KittermBench"])
)
package.targets.append(
    .executableTarget(name: "KittermBench", dependencies: ["KittermProtocol"])
)
#endif
