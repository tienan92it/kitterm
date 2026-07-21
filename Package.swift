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
        .executable(name: "KittermBench", targets: ["KittermBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
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
            ]
        ),
        .executableTarget(
            name: "KittermCLI",
            dependencies: [
                "KittermDaemon",
                "KittermProtocol",
            ]
        ),
        .executableTarget(
            name: "KittermBench",
            dependencies: [
                "KittermProtocol",
            ]
        ),
        .testTarget(
            name: "KittermProtocolTests",
            dependencies: ["KittermProtocol"]
        ),
        .testTarget(
            name: "KittermDaemonTests",
            dependencies: ["KittermDaemon", "KittermSpawnHelper"]
        ),
    ]
)
