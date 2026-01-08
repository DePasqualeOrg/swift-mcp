# Debugging

Configure logging and handle errors in MCP applications

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

In request handlers, throw ``MCPError`` for protocol-compliant error responses:

```swift
await server.withRequestHandler(ReadResource.self) { params, _ in
    guard let content = loadResource(params.uri) else {
        throw MCPError.resourceNotFound(uri: params.uri)
    }
    return .init(contents: [content])
}

await server.withRequestHandler(CallTool.self) { params, _ in
    guard isValidTool(params.name) else {
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
    // ...
}
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

## See Also

- <doc:client-setup>
- <doc:server-setup>
- ``MCPError``
- ``ErrorCode``
