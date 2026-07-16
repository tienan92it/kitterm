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
        .executable(name: "KittermApp", targets: ["KittermApp"]),
        .executable(name: "KittermBench", targets: ["KittermBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.14.0"),
    ],
    targets: [
        .target(
            name: "KittermProtocol"
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
            name: "KittermApp",
            dependencies: [
                "KittermProtocol",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Apps/Kitterm"
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
    ]
)
