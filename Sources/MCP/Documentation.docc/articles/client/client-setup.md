# Client Setup

Create an MCP client and connect to a server

## Overview

The ``Client`` allows your application to connect to MCP servers and interact with their tools, resources, and prompts. This guide covers creating a client, connecting to servers, and handling errors.

## Creating a Client

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

## Connecting to a Server

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

## Transport Options

### stdio

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

### HTTP

Connect to a remote MCP server over HTTP:

```swift
let transport = HTTPClientTransport(
    endpoint: URL(string: "http://localhost:8080/mcp")!
)
try await client.connect(transport: transport)
```

See <doc:transports> for all available transport options.

## Client Capabilities

Before connecting, you can configure what capabilities your client advertises to servers. This determines what server-to-client requests your client can handle:

```swift
let client = Client(name: "MyApp", version: "1.0.0")

await client.setCapabilities(Client.Capabilities(
    // Enable sampling requests from server
    sampling: .init(context: .init(), tools: .init()),
    // Enable elicitation (user input requests)
    elicitation: .init(form: .init(applyDefaults: true), url: .init()),
    // Enable roots (filesystem location sharing)
    roots: .init(listChanged: true)
))

try await client.connect(transport: transport)
```

> Important: You must register handlers for any capabilities you advertise. See <doc:client-sampling>, <doc:client-elicitation>, and <doc:client-roots>.

## Configuration Options

### Strict Mode

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

## Disconnecting

Disconnect the client when you're done:

```swift
await client.disconnect()
```

This cancels all pending requests and closes the connection.

## Error Handling

Handle MCP-specific errors:

```swift
do {
    try await client.connect(transport: transport)
} catch let error as MCPError {
    switch error {
    case .connectionClosed:
        print("Connection closed")
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
- ``Client``
