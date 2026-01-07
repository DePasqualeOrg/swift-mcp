# Getting Started

Get up and running with the MCP Swift SDK.

## Overview

This guide walks you through installing the SDK and creating your first MCP client and server.

## Installation

Add the MCP Swift SDK to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/DePasqualeOrg/mcp-swift-sdk", from: "0.1.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "MCP", package: "mcp-swift-sdk")
    ]
)
```

## Platform Requirements

| Platform | Minimum Version |
|----------|----------------|
| macOS | 13.0+ |
| iOS / Mac Catalyst | 16.0+ |
| watchOS | 9.0+ |
| tvOS | 16.0+ |
| visionOS | 1.0+ |
| Linux | glibc or musl (Ubuntu, Debian, Fedora, Alpine) |

## Quick Start: Client

Create a client that connects to an MCP server and calls a tool:

```swift
import MCP

// Create a client
let client = Client(name: "MyApp", version: "1.0.0")

// Connect using stdio transport
let transport = StdioTransport()
try await client.connect(transport: transport)

// List available tools
let toolsResult = try await client.listTools()
print("Available tools: \(toolsResult.tools.map { $0.name })")

// Call a tool
let result = try await client.callTool(
    name: "echo",
    arguments: ["message": "Hello, MCP!"]
)

for item in result.content {
    if case .text(let text, _, _) = item {
        print("Result: \(text)")
    }
}
```

## Quick Start: Server

Create a server that exposes a simple tool:

```swift
import MCP

// Create a server with capabilities
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(
        tools: .init(listChanged: true)
    )
)

// Register tool list handler
await server.withRequestHandler(ListTools.self) { _ in
    return .init(tools: [
        Tool(
            name: "greet",
            description: "Greet someone by name",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Name to greet"]
                ],
                "required": ["name"]
            ]
        )
    ])
}

// Register tool call handler
await server.withRequestHandler(CallTool.self) { params in
    guard params.name == "greet" else {
        return .init(content: [.text("Unknown tool")], isError: true)
    }

    let name = params.arguments?["name"]?.stringValue ?? "World"
    return .init(content: [.text("Hello, \(name)!")])
}

// Start the server
let transport = StdioTransport()
try await server.start(transport: transport)

// Keep running
try await server.waitUntilCompleted()
```

## Next Steps

- <doc:ClientGuide> - Complete guide to building MCP clients
- <doc:ServerGuide> - Complete guide to building MCP servers
- <doc:Transports> - Available transport options
- <doc:Examples> - HTTP server integration examples
