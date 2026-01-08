# Server Setup

Create an MCP server and handle client connections

## Overview

The ``Server`` handles incoming connections from MCP clients, processes requests, and sends responses. This guide covers creating a server, configuring capabilities, and managing the server lifecycle.

## Creating a Server

Create a server with your implementation's identity:

```swift
import MCP

let server = Server(
    name: "MyServer",
    version: "1.0.0"
)
```

You can provide additional metadata:

```swift
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    title: "My MCP Server",
    description: "A server that provides tools for data processing",
    icons: [Icon(src: "https://example.com/icon.png", mimeType: "image/png")],
    websiteUrl: "https://example.com",
    instructions: "Call the 'process' tool with your data"
)
```

## Declaring Capabilities

Declare which features your server supports:

```swift
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: Server.Capabilities(
        tools: .init(listChanged: true),
        resources: .init(subscribe: true, listChanged: true),
        prompts: .init(listChanged: true),
        logging: .init(),
        completions: .init()
    )
)
```

### Capability Options

- **tools**: Server provides tools
  - `listChanged`: Server notifies when tools change
- **resources**: Server provides resources
  - `subscribe`: Clients can subscribe to resource updates
  - `listChanged`: Server notifies when resource list changes
- **prompts**: Server provides prompts
  - `listChanged`: Server notifies when prompts change
- **logging**: Server accepts log level configuration
- **completions**: Server provides autocomplete suggestions

## Starting the Server

Start the server with a transport:

```swift
try await server.start(transport: transport)
```

For stdio servers (most common), use ``StdioTransport``:

```swift
import System

let transport = StdioTransport(
    input: FileDescriptor.standardInput,
    output: FileDescriptor.standardOutput
)
try await server.start(transport: transport)
await server.waitUntilCompleted()
```

## Initialize Hook

Run custom logic when clients connect using the initialize hook:

```swift
try await server.start(transport: transport) { clientInfo, clientCapabilities in
    print("Client connected: \(clientInfo.name) v\(clientInfo.version)")

    // Check client capabilities
    if clientCapabilities.sampling != nil {
        print("Client supports sampling")
    }

    // Perform any initialization
    await loadResources()
}
```

The hook receives:
- `clientInfo`: Information about the connecting client
- `clientCapabilities`: What the client supports (sampling, roots, etc.)

## Registering Handlers

Register handlers for requests using `withRequestHandler(_:handler:)`:

```swift
await server.withRequestHandler(ListTools.self) { params, context in
    ListTools.Result(tools: [
        Tool(name: "greet", description: "Say hello")
    ])
}

await server.withRequestHandler(CallTool.self) { params, context in
    if params.name == "greet" {
        return CallTool.Result(content: [.text("Hello!")])
    }
    throw MCPError.invalidParams("Unknown tool: \(params.name)")
}
```

## Configuration

### Strict Mode

By default, servers enforce strict initialization order:

```swift
// Default - requires initialize before other requests
let strictServer = Server(
    name: "Strict",
    version: "1.0.0",
    configuration: .default
)

// Lenient - allows requests before initialization
let lenientServer = Server(
    name: "Lenient",
    version: "1.0.0",
    configuration: .lenient
)
```

Strict mode ensures clients send `initialize` before other requests (except `ping`), following the MCP specification.

## Stopping the Server

Stop the server gracefully:

```swift
await server.stop()
```

This:
1. Cancels in-flight request handlers
2. Cancels the message processing task
3. Disconnects the transport

## Waiting for Completion

Wait for the server to finish processing:

```swift
try await server.start(transport: transport)
await server.waitUntilCompleted()
```

This blocks until the transport disconnects or the server stops.

## Complete Example

```swift
import MCP
import System

@main
struct MyServer {
    static func main() async throws {
        let server = Server(
            name: "MyServer",
            version: "1.0.0",
            capabilities: Server.Capabilities(
                tools: .init()
            )
        )

        // Register tool handlers
        await server.withRequestHandler(ListTools.self) { _, _ in
            ListTools.Result(tools: [
                Tool(name: "echo", description: "Echo back input")
            ])
        }

        await server.withRequestHandler(CallTool.self) { params, _ in
            guard params.name == "echo" else {
                throw MCPError.invalidParams("Unknown tool")
            }
            let message = params.arguments?["message"]?.stringValue ?? ""
            return CallTool.Result(content: [.text(message)])
        }

        // Start with stdio transport
        let transport = StdioTransport(
            input: FileDescriptor.standardInput,
            output: FileDescriptor.standardOutput
        )
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
```

## See Also

- <doc:server-tools>
- <doc:server-resources>
- <doc:server-prompts>
- <doc:transports>
- ``Server``
