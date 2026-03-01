# Server Setup

Create an MCP server and handle client connections.

## Overview

The Swift SDK provides two server APIs:

- **`MCPServer`**: High-level API with automatic capability management, tool/resource/prompt registration, and lifecycle handling (recommended)
- **`Server`**: Low-level API for custom request handling and advanced use cases

This guide covers the high-level `MCPServer`. For the low-level API, see <doc:server-advanced>.

## Creating a Server

Create a server with your implementation's identity:

```swift
import MCP

let server = MCPServer(name: "MyServer", version: "1.0.0")
```

You can provide additional metadata:

```swift
let server = MCPServer(
    name: "MyServer",
    version: "1.0.0",
    title: "My MCP Server",
    description: "A server that provides tools for data processing",
    icons: [Icon(src: "https://example.com/icon.png", mimeType: "image/png")],
    websiteUrl: "https://example.com",
    instructions: "Call the 'process' tool with your data"
)
```

## Registering Tools, Resources, and Prompts

`MCPServer` manages capabilities automatically based on what you register. When tools, resources, or prompts are registered, enabled, disabled, or removed, `MCPServer` automatically broadcasts list-changed notifications to all connected sessions:

```swift
// Register tools - enables tools capability
try await server.register {
    GetWeather.self
    Search.self
}

// Register resources - enables resources capability
try await server.registerResource(
    uri: "config://app",
    name: "Configuration"
) { ... }

// Register prompts - enables prompts capability
try await server.register {
    CodeReview.self
}
```

See <doc:server-tools>, <doc:server-resources>, and <doc:server-prompts> for detailed registration APIs.

### Capability Overrides

For dynamic registration scenarios (e.g., tools determined by client identity after authentication),
you can force capabilities via the initializer:

```swift
let server = MCPServer(
    name: "MyServer",
    version: "1.0.0",
    capabilities: Server.Capabilities(tools: .init(listChanged: true))
)

// Tools capability is advertised even before any tools are registered.
// Register tools dynamically after client connects:
try await server.register { toolsForUser(authenticatedUser) }
```

## Running the Server

### Stdio Transport

For command-line servers (most common):

```swift
try await server.run(transport: .stdio)
```

This connects to stdin/stdout and blocks until the connection closes.

### HTTP Transport

For HTTP-based servers with multiple concurrent clients, use `createSession()` to create
per-session Server instances that share tool/resource/prompt definitions:

```swift
let mcpServer = MCPServer(name: "my-server", version: "1.0.0")
try await mcpServer.register { Echo.self }

// In your HTTP handler (Vapor, Hummingbird, etc.):
let session = await mcpServer.createSession()
let transport = HTTPServerTransport(...)
try await session.start(transport: transport)
```

Sessions created via `createSession()` are tracked by `MCPServer`. When tools, resources, or prompts change at runtime, list-changed notifications are automatically broadcast to all active sessions. Sessions are automatically removed when their transport disconnects.

See the [Vapor Integration](https://github.com/DePasqualeOrg/swift-mcp/tree/main/Examples/VaporIntegration)
and [Hummingbird Integration](https://github.com/DePasqualeOrg/swift-mcp/tree/main/Examples/HummingbirdIntegration)
examples for complete implementations.

For simple demos and testing, `BasicHTTPSessionManager` handles session lifecycle automatically:

```swift
let sessionManager = BasicHTTPSessionManager(server: mcpServer, port: 8080)
// In your HTTP route:
let response = await sessionManager.handleRequest(httpRequest)
```

### Custom Transport

For other transports:

```swift
let transport = // your custom transport
try await server.run(transport: .custom(transport))
```

## Complete Example

```swift
import MCP
import MCPTool

@Tool
struct Echo {
    static let name = "echo"
    static let description = "Echo back a message"

    @Parameter(description: "Message to echo")
    var message: String

    func perform() async throws -> String {
        "Echo: \(message)"
    }
}

@main
struct MyServer {
    static func main() async throws {
        let server = MCPServer(
            name: "EchoServer",
            version: "1.0.0",
            description: "A simple echo server"
        )

        try await server.register {
            Echo.self
        }

        try await server.run(transport: .stdio)
    }
}
```

## Ping

The server automatically handles incoming ping requests. Clients use ping to verify the connection is alive.

## Protocol Version Negotiation

During initialization, the server negotiates a protocol version with the client. If the server supports the client's requested version, it uses that version; otherwise it responds with its own preferred version (the latest it supports).

This happens automatically – no configuration is needed. When using the low-level ``Server`` API, the negotiated version is available after initialization via ``Server/protocolVersion``.

## Low-Level Server API

For scenarios requiring custom request handling, direct protocol access, or mixing high-level registration with manual handlers, see <doc:server-advanced>.

## See Also

- <doc:server-tools>
- <doc:server-resources>
- <doc:server-prompts>
- <doc:server-advanced>
- <doc:transports>
- ``MCPServer``
- ``Server``
