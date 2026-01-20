// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MCPConformanceTests",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(path: "../.."), // MCP Swift SDK
    ],
    targets: [
        .executableTarget(
            name: "ConformanceClient",
            dependencies: [
                .product(name: "MCP", package: "mcp-swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ConformanceClient"
        ),
        .executableTarget(
            name: "ConformanceServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MCP", package: "mcp-swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ConformanceServer"
        ),
    ]
)
