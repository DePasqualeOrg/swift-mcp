# Client Setup

Create an MCP client and connect to a server

## Overview

The Swift SDK provides two client APIs:

- **``MCPClient``**: High-level API with automatic reconnection, health monitoring, and transparent retry on recoverable errors (recommended)
- **``Client``**: Low-level API for direct transport control

This guide covers both approaches.

## MCPClient (Recommended)

``MCPClient`` manages the connection lifecycle for you. It wraps ``Client`` and adds automatic reconnection with exponential backoff, health monitoring via periodic pings, and transparent retry on recoverable errors like session expiration and connection loss. These features work with any transport — for example, if a stdio server process crashes, ``MCPClient`` re-invokes the transport factory to spawn a new process and reconnect.

### Creating an MCPClient

```swift
import MCP

let mcpClient = MCPClient(name: "MyApp", version: "1.0.0")
```

### Connecting

Connect using a transport factory — a closure that creates a fresh transport instance. The factory is re-invoked on each reconnection attempt because transports cannot be reused after disconnection:

```swift
// HTTP
try await mcpClient.connect {
    HTTPClientTransport(endpoint: URL(string: "https://example.com/mcp")!)
}

// stdio (spawns a new server process on each connection/reconnection)
try await mcpClient.connect {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/path/to/my-mcp-server")
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    try process.run()
    return StdioTransport(
        input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
        output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
    )
}
```

### Registering Handlers

Register handlers on the underlying ``Client`` before connecting:

```swift
await mcpClient.client.withSamplingHandler { params, context in
    try await yourLLMService.complete(params)
}

try await mcpClient.connect {
    HTTPClientTransport(endpoint: URL(string: "https://example.com/mcp")!)
}
```

### Using Protocol Methods

``MCPClient`` wraps common protocol methods with automatic reconnection and retry:

```swift
let tools = try await mcpClient.listTools()
let result = try await mcpClient.callTool(name: "my_tool", arguments: ["key": .string("value")])
```

If a call fails due to session expiration or connection loss, ``MCPClient`` reconnects and retries the operation once before propagating the error.

### Observing State Changes

Monitor connection state and tool list changes:

```swift
await mcpClient.setOnStateChanged { state in
    switch state {
        case .disconnected:
            print("Disconnected")
        case .connecting:
            print("Connecting...")
        case .connected:
            print("Connected")
        case .reconnecting(let attempt):
            print("Reconnecting (attempt \(attempt))...")
    }
}

await mcpClient.setOnToolsChanged { tools in
    print("Tools updated: \(tools.map { $0.name })")
}
```

### Reconnection Options

Customize reconnection behavior:

```swift
let mcpClient = MCPClient(
    name: "MyApp",
    version: "1.0.0",
    reconnectionOptions: .init(
        maxRetries: 5,
        initialDelay: .seconds(2),
        maxDelay: .seconds(60),
        delayGrowFactor: 2.0,
        healthCheckInterval: .seconds(30)
    )
)
```

Set `healthCheckInterval` to `nil` to disable periodic health checks.

### HTTP-Specific Features

When the transport is an ``HTTPClientTransport``, ``MCPClient`` additionally hooks into:

- **Session expiration detection**: If the SSE event stream receives a 404, ``MCPClient`` proactively triggers reconnection before your next call fails.
- **Event stream status monitoring**: Track the health of the SSE event stream via ``MCPClient/onEventStreamStatusChanged``. See ``EventStreamStatus``.

These callbacks are set up automatically — no extra configuration is needed.

## Client (Low-Level)

For direct control over the connection lifecycle, or when you don't need automatic reconnection, use ``Client`` directly.

### Creating a Client

Create a client with your application's identity:

```swift
import MCP

let client = Client(
    name: "MyApp",
    version: "1.0.0"
)
```

You can also provide optional metadata:

```swift
let client = Client(
    name: "MyApp",
    version: "1.0.0",
    title: "My Application",
    description: "An MCP client application",
    icons: [Icon(src: "https://example.com/icon.png", mimeType: "image/png")],
    websiteUrl: "https://example.com"
)
```

### Connecting to a Server

Connect to a server using a transport. The ``Client/connect(transport:)`` method returns the initialization result containing server capabilities:

```swift
let transport = StdioTransport()
let result = try await client.connect(transport: transport)

// Check server capabilities
if result.capabilities.tools != nil {
    print("Server supports tools")
}
```

The return value is discardable if you don't need to inspect capabilities immediately.

After connecting, you can retrieve server capabilities at any time:

```swift
if let capabilities = await client.getServerCapabilities() {
    if capabilities.resources?.subscribe == true {
        print("Server supports resource subscriptions")
    }
}
```

### Transport Options

#### stdio

For spawning and communicating with a local MCP server process:

```swift
import Foundation
import MCP
import System

// Spawn the server process
let process = Process()
process.executableURL = URL(fileURLWithPath: "/path/to/my-mcp-server")

let stdinPipe = Pipe()
let stdoutPipe = Pipe()
process.standardInput = stdinPipe
process.standardOutput = stdoutPipe

try process.run()

// Create client with stdio transport using the process pipes
let client = Client(name: "MyApp", version: "1.0.0")
let transport = StdioTransport(
    input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
    output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
)

try await client.connect(transport: transport)
```

#### HTTP

Connect to a remote MCP server over HTTP:

```swift
let transport = HTTPClientTransport(
    endpoint: URL(string: "http://localhost:8080/mcp")!
)
try await client.connect(transport: transport)
```

See <doc:transports> for all available transport options.

### Client Capabilities

Client capabilities are automatically detected from the handlers you register. Simply register handlers before connecting, and the client will advertise the appropriate capabilities:

```swift
let client = Client(name: "MyApp", version: "1.0.0")

// Enable sampling with tool support
await client.withSamplingHandler(supportsTools: true) { params, context in
    // Handle LLM completion requests
    return try await yourLLMService.complete(params)
}

// Enable elicitation with form and URL modes
await client.withElicitationHandler(formMode: .enabled(), urlMode: .enabled) { params, context in
    // Handle user input requests
    return try await handleUserInput(params)
}

// Enable roots with change notifications
await client.withRootsHandler(listChanged: true) { context in
    // Return available filesystem roots
    return [Root(uri: "file:///path/to/project", name: "Project")]
}

try await client.connect(transport: transport)
```

> Important: Register handlers before calling `connect()`. Attempting to register handlers after connecting will result in an error.

See <doc:client-sampling>, <doc:client-elicitation>, and <doc:client-roots> for detailed handler documentation.

#### Explicit Capability Override

For edge cases, you can provide explicit capability overrides via the initializer. This is useful for:

- Testing with specific capability configurations
- Forward compatibility with capabilities not yet supported by SDK handler registration
- Advertising `experimental` capabilities (which cannot be auto-detected)

```swift
let client = Client(
    name: "MyApp",
    version: "1.0.0",
    capabilities: Client.Capabilities(
        // Explicit sampling override
        sampling: .init(context: .init(), tools: .init()),
        // Experimental capabilities (cannot be auto-detected)
        experimental: ["customFeature": ["enabled": .bool(true)]]
        // roots: nil — will be auto-detected from handler
    )
)

// Auto-detect roots capability from handler
await client.withRootsHandler { context in
    return await workspace.getCurrentRoots()
}

try await client.connect(transport: transport)
```

Explicit overrides take precedence over auto-detection on a per-capability basis. Only non-nil fields in the initializer override auto-detection; others are still auto-detected from handlers.

### Configuration Options

#### Strict Mode

Control how the client handles capability checking:

```swift
// Strict mode - requires server capabilities before making requests
let strictClient = Client(
    name: "StrictClient",
    version: "1.0.0",
    configuration: .strict
)

// Default mode - more lenient with non-compliant servers
let flexibleClient = Client(
    name: "FlexibleClient",
    version: "1.0.0",
    configuration: .default
)
```

When strict mode is enabled, the client requires server capabilities to be initialized before making requests. Disabling strict mode allows the client to be more lenient with servers that don't fully follow the MCP specification.

### Disconnecting

Disconnect the client when you're done:

```swift
await client.disconnect()
```

This cancels all pending requests and closes the connection.

## Error Handling

> Note: When using ``MCPClient``, session expiration, connection closed, and transport errors are handled automatically via reconnection and retry. The error cases below are most relevant when using ``Client`` directly.

Handle MCP-specific errors:

```swift
do {
    try await client.connect(transport: transport)
} catch let error as MCPError {
    switch error {
        case .connectionClosed:
            print("Connection closed")
        case .sessionExpired:
            print("Session expired — reconnect to the server")
        case .requestTimeout(let timeout, let message):
            print("Timeout after \(timeout): \(message ?? "")")
        case .methodNotFound(let method):
            print("Method not found: \(method ?? "")")
        case .invalidRequest(let message):
            print("Invalid request: \(message)")
        case .invalidParams(let message):
            print("Invalid params: \(message)")
        default:
            print("MCP error: \(error)")
    }
} catch {
    print("Unexpected error: \(error)")
}
```

## See Also

- <doc:client-tools>
- <doc:client-resources>
- <doc:client-prompts>
- <doc:transports>
- ``MCPClient``
- ``Client``
