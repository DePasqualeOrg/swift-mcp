# Getting Started

## Overview

The simplest way to get started is connecting a client and server within the same process using ``InMemoryTransport``.

For other transports like stdio and HTTP, see the <doc:client-guide> and <doc:server-guide>.

## Example

```swift
import MCP

// Create the server
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(tools: .init())
)

// Handle requests to list tools
await server.withRequestHandler(ListTools.self) { _, _ in
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

// Handle requests to call tools
await server.withRequestHandler(CallTool.self) { params, _ in
    guard params.name == "greet" else {
        return .init(content: [.text("Unknown tool")], isError: true)
    }
    let name = params.arguments?["name"]?.stringValue ?? "World"
    return .init(content: [.text("Hello, \(name)!")])
}

// Create the client
let client = Client(name: "MyApp", version: "1.0.0")

// Create a connected transport pair
let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

// Start the server and connect the client
try await server.start(transport: serverTransport)
try await client.connect(transport: clientTransport)

// Use the client to interact with the server
let tools = try await client.listTools()
print("Available tools: \(tools.tools.map { $0.name })")

let result = try await client.callTool(name: "greet", arguments: ["name": "MCP"])
if case .text(let text, _, _) = result.content.first {
    print(text)  // "Hello, MCP!"
}

// Clean up
await client.disconnect()
await server.stop()
```

## Next Steps

- <doc:client-guide>: Build MCP clients
- <doc:server-guide>: Build MCP servers
- <doc:transports>: Available transport options
