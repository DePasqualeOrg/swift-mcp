# Debugging

Configure logging and handle errors in MCP applications.

## Overview

This guide covers debugging techniques, logging configuration, and error handling for MCP clients and servers.

## Logging

The MCP SDK uses [swift-log](https://github.com/apple/swift-log) for logging. Configure it to see detailed protocol messages.

### Basic Setup

```swift
import Logging
import MCP

// Configure the logging system
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .debug
    return handler
}

// Create a logger
let logger = Logger(label: "com.example.mcp")

// Pass to transport
let transport = StdioTransport(logger: logger)
```

### Log Levels

| Level | Use Case |
|-------|----------|
| `.trace` | Detailed protocol messages, raw JSON |
| `.debug` | Connection events, handler registration |
| `.info` | Normal operations, session lifecycle |
| `.warning` | Recoverable issues, deprecation notices |
| `.error` | Failures, exceptions |
| `.critical` | Fatal errors |

### Setting Server Log Level

Clients can request a specific log level from the server:

```swift
try await client.setLoggingLevel(.debug)
```

The server will then only send log messages at that level or higher.

### Transport Logging

All transports accept a logger:

```swift
// Stdio transport
let stdioTransport = StdioTransport(logger: logger)

// HTTP client transport
let httpTransport = HTTPClientTransport(
    endpoint: url,
    logger: logger
)

// HTTP server transport
let serverTransport = HTTPServerTransport(
    options: .init(...),
    logger: logger
)
```

## Error Handling

### MCPError

The SDK defines ``MCPError`` for protocol-level errors:

```swift
do {
    try await client.callTool(name: "unknown", arguments: [:])
} catch let error as MCPError {
    switch error {
    case .parseError(let message):
        print("Invalid JSON: \(message ?? "")")

    case .invalidRequest(let message):
        print("Invalid request: \(message ?? "")")

    case .methodNotFound(let method):
        print("Method not found: \(method ?? "")")

    case .invalidParams(let message):
        print("Invalid parameters: \(message ?? "")")

    case .internalError(let message):
        print("Internal error: \(message ?? "")")

    case .connectionClosed(let reason):
        print("Connection closed: \(reason ?? "")")

    case .requestTimeout(let message):
        print("Request timed out: \(message ?? "")")

    case .requestCancelled(let reason):
        print("Request cancelled: \(reason ?? "")")

    case .resourceNotFound(let uri):
        print("Resource not found: \(uri ?? "")")

    case .transportError(let message):
        print("Transport error: \(message ?? "")")

    case .custom(let code, let message, let data):
        print("Custom error \(code): \(message ?? "")")
    }
}
```

### Error Codes

Standard JSON-RPC and MCP error codes:

```swift
// JSON-RPC 2.0 standard errors
ErrorCode.parseError        // -32700: Invalid JSON
ErrorCode.invalidRequest    // -32600: Invalid request object
ErrorCode.methodNotFound    // -32601: Method not available
ErrorCode.invalidParams     // -32602: Invalid parameters
ErrorCode.internalError     // -32603: Internal error

// MCP specification errors
ErrorCode.resourceNotFound        // -32002: Resource doesn't exist
ErrorCode.urlElicitationRequired  // -32042: URL elicitation needed

// SDK-specific errors
ErrorCode.connectionClosed   // -32000: Connection closed
ErrorCode.requestTimeout     // -32001: Request timed out
ErrorCode.transportError     // -32003: Transport layer error
ErrorCode.requestCancelled   // -32004: Request was cancelled
```

### Throwing Errors from Handlers

In request handlers, throw ``MCPError`` for protocol-compliant error responses:

```swift
await server.withRequestHandler(ReadResource.self) { params in
    guard let content = loadResource(params.uri) else {
        throw MCPError.resourceNotFound(params.uri)
    }
    return .init(contents: [content])
}

await server.withRequestHandler(CallTool.self) { params in
    guard isValidTool(params.name) else {
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
    // ...
}
```

## Common Issues

### Connection Problems

**Symptom:** Client can't connect to server

**Debugging steps:**
1. Enable debug logging on both client and server
2. Verify transport configuration (endpoint URL, port)
3. Check network connectivity
4. For HTTP: verify the endpoint path matches

```swift
// Verbose logging for connection issues
var handler = StreamLogHandler.standardOutput(label: "mcp")
handler.logLevel = .trace
```

### Initialization Failures

**Symptom:** Connection succeeds but initialization fails

**Debugging steps:**
1. Check protocol version compatibility
2. Verify capabilities are properly declared
3. Look for errors in the initialize hook

```swift
try await server.start(transport: transport) { clientInfo, capabilities in
    print("Client: \(clientInfo.name) v\(clientInfo.version)")
    print("Capabilities: \(capabilities)")
}
```

### Handler Not Called

**Symptom:** Requests succeed but handler code doesn't run

**Debugging steps:**
1. Verify handler is registered before `server.start()`
2. Check the method name matches exactly
3. Confirm capabilities are declared for the feature

```swift
// Handlers must be registered before starting
await server.withRequestHandler(ListTools.self) { _ in ... }
await server.withRequestHandler(CallTool.self) { params in ... }

// Then start
try await server.start(transport: transport)
```

### Request Timeouts

**Symptom:** Requests hang or timeout

**Debugging steps:**
1. Check if handler is blocking or slow
2. Verify network latency for HTTP transport
3. Consider increasing timeout for slow operations

```swift
// Increase timeout for slow operations
let result = try await client.send(
    CallTool.request(.init(name: "slow-tool", arguments: [:])),
    timeout: .seconds(120)
)
```

### Session Issues (HTTP)

**Symptom:** Session ID errors or 404 responses

**Debugging steps:**
1. Verify session ID is included in headers
2. Check session hasn't expired or been cleaned up
3. Ensure session manager is properly configured

```swift
// Log session lifecycle
let transport = HTTPServerTransport(
    options: .init(
        sessionIdGenerator: { UUID().uuidString },
        onSessionInitialized: { id in
            print("Session started: \(id)")
        },
        onSessionClosed: { id in
            print("Session ended: \(id)")
        }
    ),
    logger: logger
)
```

## Protocol Inspection

### Raw Message Logging

For deep debugging, log raw JSON messages:

```swift
// Create a custom log handler that shows full messages
struct VerboseLogHandler: LogHandler {
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        print("[\(level)] \(message)")
        if let meta = metadata {
            for (key, value) in meta {
                print("  \(key): \(value)")
            }
        }
    }
}
```

### Inspecting Capabilities

Check what capabilities were negotiated:

```swift
// Client side
let result = try await client.connect(transport: transport)
print("Server capabilities:")
print("  Tools: \(result.capabilities.tools != nil)")
print("  Resources: \(result.capabilities.resources != nil)")
print("  Prompts: \(result.capabilities.prompts != nil)")
print("  Sampling: \(result.capabilities.sampling != nil)")

// Server side (in initialize hook)
try await server.start(transport: transport) { clientInfo, capabilities in
    print("Client capabilities:")
    print("  Sampling: \(capabilities.sampling != nil)")
    print("  Roots: \(capabilities.roots != nil)")
}
```

## See Also

- <doc:ClientGuide>
- <doc:ServerGuide>
- ``MCPError``
- ``ErrorCode``
