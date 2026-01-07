# MCP Swift SDK

[**Installation**](#installation) | [**Documentation**](https://swiftpackageindex.com/DePasqualeOrg/mcp-swift-sdk/main/documentation/mcp) | [**Examples**](Examples/)

Swift SDK for the [Model Context Protocol][mcp] (MCP).

This repository, which builds on the [official](https://github.com/modelcontextprotocol/swift-sdk) but incomplete Swift SDK for MCP, includes new and revised functionality that has not yet been fully vetted. Feedback on anything that can be improved is welcome.

## Installation

Add the following to your `Package.swift`:

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

## Quick Start

### Client

```swift
import MCP

let client = Client(name: "MyApp", version: "1.0.0")
let transport = StdioTransport()
try await client.connect(transport: transport)

// List and call tools
let tools = try await client.listTools()
let result = try await client.callTool(name: "echo", arguments: ["message": "Hello!"])
```

### Server

```swift
import MCP

let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true))
)

await server.withRequestHandler(ListTools.self) { _ in
    .init(tools: [
        Tool(name: "greet", description: "Greet someone", inputSchema: [
            "type": "object",
            "properties": ["name": ["type": "string"]],
            "required": ["name"]
        ])
    ])
}

await server.withRequestHandler(CallTool.self) { params in
    let name = params.arguments?["name"]?.stringValue ?? "World"
    return .init(content: [.text("Hello, \(name)!")])
}

let transport = StdioTransport()
try await server.start(transport: transport)
```

## Transports

| Transport | Description | Use Case |
|-----------|-------------|----------|
| `StdioTransport` | Standard I/O streams | Local subprocesses, CLI tools |
| `HTTPClientTransport` | HTTP client with SSE | Connect to remote servers |
| `HTTPServerTransport` | HTTP server hosting | Host servers over HTTP |
| `InMemoryTransport` | In-process communication | Testing |
| `NetworkTransport` | Apple Network framework | Custom protocols (Apple platforms) |

## Examples

See the [Examples](Examples/) directory for HTTP server integrations:

- **[Hummingbird Integration](Examples/HummingbirdIntegration/)**: Lightweight web framework
- **[Vapor Integration](Examples/VaporIntegration/)**: Full-featured web framework

## Documentation

Full documentation is available on [Swift Package Index](https://swiftpackageindex.com/DePasqualeOrg/mcp-swift-sdk/main/documentation/mcp):

- [Getting Started](https://swiftpackageindex.com/DePasqualeOrg/mcp-swift-sdk/main/documentation/mcp/gettingstarted)
- [Client Guide](https://swiftpackageindex.com/DePasqualeOrg/mcp-swift-sdk/main/documentation/mcp/clientguide)
- [Server Guide](https://swiftpackageindex.com/DePasqualeOrg/mcp-swift-sdk/main/documentation/mcp/serverguide)
- [Transports](https://swiftpackageindex.com/DePasqualeOrg/mcp-swift-sdk/main/documentation/mcp/transports)
- [Examples](https://swiftpackageindex.com/DePasqualeOrg/mcp-swift-sdk/main/documentation/mcp/examples)

## Additional Resources

- [MCP Specification](https://modelcontextprotocol.io/specification/2025-11-25/)
- [Protocol Documentation](https://modelcontextprotocol.io)

[mcp]: https://modelcontextprotocol.io
[mcp-spec]: https://modelcontextprotocol.io/specification/2025-11-25
