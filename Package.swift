// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

// Base dependencies needed on all platforms
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/DePasqualeOrg/swift-sse", .upToNextMinor(from: "0.1.0")),
    .package(url: "https://github.com/ajevans99/swift-json-schema", .upToNextMinor(from: "0.11.2")),
    .package(url: "https://github.com/swiftlang/swift-syntax", "603.0.0" ..< "604.0.0"),
    .package(url: "https://github.com/swiftlang/swift-docc", branch: "main"),
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", branch: "main"),
    // Cross-platform crypto (Linux only; Apple platforms use CryptoKit)
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    // Test-only dependency for real HTTP testing
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
]

// Dependencies for MCPCore (types and protocols only — no transport/I/O)
var mcpCoreTargetDependencies: [Target.Dependency] = [
    .product(name: "SystemPackage", package: "swift-system"),
    .product(name: "Logging", package: "swift-log"),
    .product(name: "JSONSchema", package: "swift-json-schema"),
    .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
]

// Target dependencies needed on all platforms (for MCP runtime, which depends
// on MCPCore for shared types and protocols)
var targetDependencies: [Target.Dependency] = [
    .product(name: "SystemPackage", package: "swift-system"),
    .product(name: "Logging", package: "swift-log"),
    .product(name: "SSE", package: "swift-sse"),
    .product(name: "JSONSchema", package: "swift-json-schema"),
    .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
    .product(
        name: "Crypto", package: "swift-crypto",
        condition: .when(platforms: [.linux]),
    ),
]

// MCP runtime target depends on MCPCore plus the base target dependencies.
var mcpRuntimeTargetDependencies: [Target.Dependency] = ["MCPCore"] + targetDependencies

// Macro dependencies
let macroDependencies: [Target.Dependency] = [
    .product(name: "SwiftSyntax", package: "swift-syntax"),
    .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
    .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
]

// MCPTests target dependencies (MCP + MCPTool + MCPPrompt + Hummingbird for HTTP testing).
// MCPCore is available transitively via MCP.
var testTargetDependencies: [Target.Dependency] = ["MCP", "MCPTool", "MCPPrompt"]
testTargetDependencies.append(contentsOf: targetDependencies)
testTargetDependencies.append(.product(name: "Hummingbird", package: "hummingbird"))
testTargetDependencies.append(.product(name: "HummingbirdTesting", package: "hummingbird"))

let package = Package(
    name: "swift-mcp",
    platforms: [
        .macOS("14.0"),
        .macCatalyst("17.0"),
        .iOS("17.0"),
        .watchOS("10.0"),
        .tvOS("17.0"),
        .visionOS("1.0"),
    ],
    products: [
        .library(
            name: "MCPCore",
            targets: ["MCPCore"],
        ),
        .library(
            name: "MCP",
            targets: ["MCP"],
        ),
        .library(
            name: "MCPTool",
            targets: ["MCPTool"],
        ),
        .library(
            name: "MCPPrompt",
            targets: ["MCPPrompt"],
        ),
    ],
    dependencies: dependencies,
    targets: [
        .macro(
            name: "MCPMacros",
            dependencies: macroDependencies,
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
        ),
        .target(
            name: "MCPCore",
            dependencies: mcpCoreTargetDependencies + ["MCPMacros"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
        ),
        .target(
            name: "MCP",
            dependencies: mcpRuntimeTargetDependencies,
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
        ),
        .target(
            name: "MCPTool",
            dependencies: [
                "MCP",
                "MCPMacros",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
        ),
        .target(
            name: "MCPPrompt",
            dependencies: ["MCP", "MCPMacros"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ],
        ),
        .testTarget(
            name: "MCPTests",
            dependencies: testTargetDependencies,
        ),
        .testTarget(
            name: "MCPMacroTests",
            dependencies: [
                "MCPMacros",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
        ),
    ],
)
