// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

// Base dependencies needed on all platforms
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/mattt/eventsource.git", from: "1.1.0"),
    .package(url: "https://github.com/ajevans99/swift-json-schema", from: "0.2.1"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0" ..< "603.0.0"),
    .package(url: "https://github.com/swiftlang/swift-docc", branch: "main"),
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", branch: "main"),
    // Cross-platform crypto (Linux only; Apple platforms use CryptoKit)
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    // Test-only dependency for real HTTP testing
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
]

// Target dependencies needed on all platforms
var targetDependencies: [Target.Dependency] = [
    .product(name: "SystemPackage", package: "swift-system"),
    .product(name: "Logging", package: "swift-log"),
    .product(
        name: "EventSource", package: "eventsource",
        condition: .when(platforms: [.macOS, .iOS, .tvOS, .visionOS, .watchOS, .macCatalyst])
    ),
    .product(name: "JSONSchema", package: "swift-json-schema"),
    .product(
        name: "Crypto", package: "swift-crypto",
        condition: .when(platforms: [.linux])
    ),
]

// Macro dependencies
let macroDependencies: [Target.Dependency] = [
    .product(name: "SwiftSyntax", package: "swift-syntax"),
    .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
    .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
]

// MCP target dependencies (core types, no macros)
var mcpTargetDependencies: [Target.Dependency] = targetDependencies

// MCPTests target dependencies (MCP + MCPTool + MCPPrompt + Hummingbird for HTTP testing)
var testTargetDependencies: [Target.Dependency] = ["MCP", "MCPTool", "MCPPrompt"]
testTargetDependencies.append(contentsOf: targetDependencies)
testTargetDependencies.append(.product(name: "Hummingbird", package: "hummingbird"))
testTargetDependencies.append(.product(name: "HummingbirdTesting", package: "hummingbird"))

let package = Package(
    name: "swift-mcp",
    platforms: [
        .macOS("13.0"),
        .macCatalyst("16.0"),
        .iOS("16.0"),
        .watchOS("9.0"),
        .tvOS("16.0"),
        .visionOS("1.0"),
    ],
    products: [
        .library(
            name: "MCP",
            targets: ["MCP"]
        ),
        .library(
            name: "MCPTool",
            targets: ["MCPTool"]
        ),
        .library(
            name: "MCPPrompt",
            targets: ["MCPPrompt"]
        ),
    ],
    dependencies: dependencies,
    targets: [
        .macro(
            name: "MCPMacros",
            dependencies: macroDependencies,
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "MCP",
            dependencies: mcpTargetDependencies,
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "MCPTool",
            dependencies: ["MCP", "MCPMacros"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "MCPPrompt",
            dependencies: ["MCP", "MCPMacros"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "MCPTests",
            dependencies: testTargetDependencies
        ),
        .testTarget(
            name: "MCPMacroTests",
            dependencies: [
                "MCPMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
