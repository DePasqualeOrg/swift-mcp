# Advanced

Send progress notifications, log messages, and handle cancellation

## Overview

This guide covers advanced server features including progress reporting, sending notifications, handling cancellation, and using the request handler context.

## Request Handler Context

Every request handler receives a ``Server/RequestHandlerContext`` that provides request-scoped capabilities:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    // Request identification
    print("Request ID: \(context.requestId)")

    // Request metadata (includes progress token)
    if let meta = context._meta {
        print("Progress token: \(meta.progressToken)")
    }

    // Session ID (for HTTP transports with multiple clients)
    if let sessionId = context.sessionId {
        print("Session: \(sessionId)")
    }

    return CallTool.Result(content: [...])
}
```

## Progress Notifications

Report progress during long-running operations:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    guard params.name == "process-data" else { ... }

    // Get the progress token from the request
    let progressToken = context._meta?.progressToken

    // Report initial progress
    if let token = progressToken {
        try await context.sendProgress(
            token: token,
            progress: 0,
            total: 100,
            message: "Starting..."
        )
    }

    // Process in chunks
    for i in 1...10 {
        await processChunk(i)

        if let token = progressToken {
            try await context.sendProgress(
                token: token,
                progress: Double(i * 10),
                total: 100,
                message: "Processing chunk \(i)/10"
            )
        }
    }

    return CallTool.Result(content: [.text("Processing complete")])
}
```

## Sending Notifications

The context provides methods for sending various notifications:

### Progress

```swift
try await context.sendProgress(
    token: token,
    progress: 50,
    total: 100,
    message: "Halfway done"
)
```

### Log Messages

```swift
try await context.sendLogMessage(
    level: .info,
    logger: "my-tool",
    data: "Processing started"
)

try await context.sendLogMessage(
    level: .warning,
    logger: "my-tool",
    data: .object(["message": "Rate limit approaching", "remaining": 10])
)
```

### Resource Changes

```swift
// Resource list changed (new/removed resources)
try await context.sendResourceListChanged()

// Specific resource updated
try await context.sendResourceUpdated(uri: "config://app")
```

### Tool/Prompt Changes

```swift
try await context.sendToolListChanged()
try await context.sendPromptListChanged()
```

## Handling Cancellation

Check if the request has been cancelled:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    for item in largeDataSet {
        // Check for cancellation
        if context.isCancelled {
            return CallTool.Result(
                content: [.text("Operation cancelled")],
                isError: true
            )
        }

        // Or throw on cancellation
        try context.checkCancellation()

        await processItem(item)
    }

    return CallTool.Result(content: [.text("Done")])
}
```

## Logging

Servers can send log messages to clients and handle log level changes.

Handle log level changes from clients:

```swift
// The server automatically handles SetLoggingLevel requests
// if you declared logging capability
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: Server.Capabilities(logging: .init())
)
```

## Graceful Shutdown

Stop the server cleanly:

```swift
// Capture server reference
let server = Server(name: "MyServer", version: "1.0.0")

// Set up signal handler
signal(SIGINT) { _ in
    Task {
        await server.stop()
    }
}

// Start server
try await server.start(transport: transport)
await server.waitUntilCompleted()
```

Stopping the server:
1. Cancels all in-flight request handlers
2. Cancels the message processing task
3. Disconnects the transport

## HTTP Transport Considerations

When using HTTP transport with multiple concurrent clients:

### Session Identification

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    // Each HTTP client gets a unique session ID
    if let sessionId = context.sessionId {
        print("Request from session: \(sessionId)")
    }

    // Authentication info for OAuth-protected endpoints
    if let authInfo = context.authInfo {
        print("Authenticated user: \(authInfo)")
    }

    return CallTool.Result(content: [...])
}
```

### Request Information

```swift
if let requestInfo = context.requestInfo {
    // Access HTTP headers and other request details
}
```

## See Also

- <doc:server-setup>
- <doc:server-tools>
- ``Server``
- ``Server/RequestHandlerContext``
