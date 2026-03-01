# Advanced

Low-level server API, manual registration patterns, and advanced features.

## Overview

This guide covers the low-level ``Server`` API for scenarios where you need direct control over request handling, want to mix high-level and low-level patterns, or need features not exposed by ``MCPServer``.

For most use cases, ``MCPServer`` with `@Tool`, `@Prompt`, and closure-based registration is recommended. See <doc:server-setup>.

## When to Use the Low-Level API

Use ``Server`` directly when you need:

- **Custom request routing**: Complex logic to determine how to handle requests
- **Dynamic handlers**: Handlers that change based on runtime conditions
- **Protocol extensions**: Support for custom MCP methods beyond the standard set
- **Resource subscriptions**: Full control over subscribe/unsubscribe handlers
- **Mixing patterns**: Combine high-level registration with manual handlers

## Creating a Low-Level Server

```swift
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: Server.Capabilities(
        tools: .init(listChanged: true),
        resources: .init(subscribe: true, listChanged: true),
        prompts: .init(listChanged: true)
    )
)
```

Unlike ``MCPServer``, you must declare capabilities upfront.

## Manual Tool Registration

Register handlers for listing and calling tools.

> Note: When using the low-level API, input validation is not automatic. If you need schema validation, you must implement it yourself in your `CallTool` handler. For automatic validation, use ``MCPServer`` instead.

```swift
await server.withRequestHandler(ListTools.self) { _, _ in
    ListTools.Result(tools: [
        Tool(
            name: "weather",
            description: "Get current weather for a location",
            inputSchema: [
                "type": "object",
                "properties": [
                    "location": ["type": "string", "description": "City name"],
                    "units": ["type": "string", "enum": ["metric", "imperial"]]
                ],
                "required": ["location"]
            ]
        )
    ])
}

await server.withRequestHandler(CallTool.self) { params, _ in
    switch params.name {
        case "weather":
            let location = params.arguments?["location"]?.stringValue ?? "Unknown"
            let weather = await getWeather(location: location)
            return CallTool.Result(content: [.text("Weather in \(location): \(weather)")])
        default:
            throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
}
```

### Error Handling with Low-Level API

With the low-level ``Server`` API, thrown errors become JSON-RPC error responses (protocol errors). For recoverable tool execution errors that models can self-correct from, you must explicitly return `CallTool.Result` with `isError: true`:

```swift
await server.withRequestHandler(CallTool.self) { params, _ in
    switch params.name {
        case "weather":
            guard let location = params.arguments?["location"]?.stringValue else {
                // Recoverable error - model can retry with correct arguments
                return CallTool.Result(
                    content: [.text("Missing required parameter: location")],
                    isError: true
                )
            }
            let weather = await getWeather(location: location)
            return CallTool.Result(content: [.text("Weather in \(location): \(weather)")])
        default:
            // Protocol error - unknown tool
            throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
}
```

This differs from ``MCPServer``, which automatically converts thrown errors to `isError: true` responses.

## Manual Resource Registration

```swift
await server.withRequestHandler(ListResources.self) { _, _ in
    ListResources.Result(resources: [
        Resource(
            name: "Configuration",
            uri: "config://app",
            description: "Application configuration",
            mimeType: "application/json"
        )
    ])
}

await server.withRequestHandler(ReadResource.self) { params, _ in
    switch params.uri {
        case "config://app":
            let config = loadConfiguration()
            return ReadResource.Result(contents: [
                .text(config.jsonString, uri: params.uri, mimeType: "application/json")
            ])
        default:
            throw MCPError.resourceNotFound(uri: params.uri)
    }
}
```

### Resource Templates

```swift
await server.withRequestHandler(ListResourceTemplates.self) { _, _ in
    ListResourceTemplates.Result(templates: [
        Resource.Template(
            uriTemplate: "file:///{path}",
            name: "File",
            description: "Access files by path"
        )
    ])
}
```

### Resource Subscriptions

```swift
var subscriptions: Set<String> = []

await server.withRequestHandler(ResourceSubscribe.self) { params, _ in
    subscriptions.insert(params.uri)
    return ResourceSubscribe.Result()
}

await server.withRequestHandler(ResourceUnsubscribe.self) { params, _ in
    subscriptions.remove(params.uri)
    return ResourceUnsubscribe.Result()
}

// Notify subscribers when content changes
func onResourceChanged(uri: String) async throws {
    if subscriptions.contains(uri) {
        try await server.sendResourceUpdated(uri: uri)
    }
}
```

## Manual Prompt Registration

```swift
await server.withRequestHandler(ListPrompts.self) { _, _ in
    ListPrompts.Result(prompts: [
        Prompt(
            name: "code-review",
            description: "Review code for best practices",
            arguments: [
                .init(name: "language", description: "Programming language", required: true),
                .init(name: "code", description: "Code to review", required: true)
            ]
        )
    ])
}

await server.withRequestHandler(GetPrompt.self) { params, _ in
    guard params.name == "code-review" else {
        throw MCPError.invalidParams("Unknown prompt: \(params.name)")
    }

    let language = params.arguments?["language"] ?? "unknown"
    let code = params.arguments?["code"] ?? ""

    return GetPrompt.Result(
        description: "Code review for \(language)",
        messages: [
            .user("Please review this \(language) code:\n\n```\(language)\n\(code)\n```")
        ]
    )
}
```

## Mixing High-Level and Low-Level

For HTTP servers, you can add custom handlers to session instances created via `createSession()`:

```swift
let mcpServer = MCPServer(name: "MyServer", version: "1.0.0")

// High-level tool registration (shared across all sessions)
try await mcpServer.register(MyTool.self)

// Create a session and add custom handlers
let session = await mcpServer.createSession()
await session.withRequestHandler(CustomMethod.self) { params, context in
    // Custom handling
}

// Start with transport
try await session.start(transport: transport)
```

For stdio servers, use the low-level ``Server`` directly if you need custom handlers:

## Request Handler Context

Every request handler receives a context with request-scoped capabilities:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    // Request identification
    print("Request ID: \(context.requestId)")

    // Progress token for long operations
    if let meta = context._meta {
        print("Progress token: \(meta.progressToken)")
    }

    // Session ID (HTTP transport with multiple clients)
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
    let progressToken = context._meta?.progressToken

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

    return CallTool.Result(content: [.text("Complete")])
}
```

## Sending Notifications

### Log Messages

```swift
try await context.sendLogMessage(
    level: .info,
    logger: "my-tool",
    data: "Processing started"
)
```

### List Changes

```swift
try await context.sendToolListChanged()
try await context.sendResourceListChanged()
try await context.sendPromptListChanged()
```

### Resource Updates

```swift
try await context.sendResourceUpdated(uri: "config://app")
```

## Handling Cancellation

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

## Logging Capability

Handle log level changes from clients:

```swift
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: Server.Capabilities(logging: .init())
)

// Server automatically handles SetLoggingLevel requests
```

## Starting and Stopping

```swift
// Create transport
let transport = StdioTransport(
    input: FileDescriptor.standardInput,
    output: FileDescriptor.standardOutput
)

// Start with optional initialize hook
try await server.start(transport: transport) { clientInfo, clientCapabilities in
    print("Client connected: \(clientInfo.name)")
}

// Wait for completion
await server.waitUntilCompleted()

// Or stop manually
await server.stop()
```

### Disconnect Callback

Register a callback to be notified when the server's transport disconnects:

```swift
await server.setOnDisconnect {
    print("Client disconnected")
    // Clean up session-specific resources
}
```

> Note: When using ``MCPServer``, disconnect callbacks are automatically set up on sessions created via ``MCPServer/createSession()`` to remove them from the active session list.

## Configuration Options

```swift
// Strict mode (default) - requires initialize before other requests
let strictServer = Server(
    name: "Strict",
    version: "1.0.0",
    configuration: .default
)

// Lenient mode - allows requests before initialization
let lenientServer = Server(
    name: "Lenient",
    version: "1.0.0",
    configuration: .lenient
)
```

## HTTP Transport Considerations

When using HTTP transport with multiple concurrent clients:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    // Session ID for client identification
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

See <doc:server-auth> for full server-side auth setup.

## Fallback Handlers

Fallback handlers intercept requests and notifications that don't have a specific handler registered.

### Fallback Request Handler

Handle client requests that have no specific handler:

```swift
await server.setFallbackRequestHandler { request, context in
    print("Unhandled request: \(request.method)")
    // Return a response or throw an error
    throw MCPError.methodNotFound("Unknown method: \(request.method)")
}
```

You can also return a valid response from the fallback handler:

```swift
await server.setFallbackRequestHandler { request, context in
    // Handle unknown methods gracefully
    if request.method.hasPrefix("custom/") {
        return Response<AnyMethod>(id: request.id, result: .object(["handled": .bool(true)]))
    }
    throw MCPError.methodNotFound("Unknown method: \(request.method)")
}
```

### Fallback Notification Handler

Observe client notifications that have no specific handler:

```swift
await server.setFallbackNotificationHandler { notification in
    print("Unhandled notification: \(notification.method)")
}
```

Fallback handlers are useful for:
- **Debugging**: Log all requests/notifications your handlers don't cover
- **Forward-compatibility**: Handle new MCP methods without code changes
- **Testing**: Capture requests/notifications for verification
- **Protocol extensions**: Provide generic handling for custom method namespaces

> Important: Specific handlers always take precedence over fallback handlers. If you register a handler for a method via `withRequestHandler(_:handler:)` or `onNotification(_:handler:)`, the fallback handler won't be called for that method.

## Graceful Shutdown

```swift
let server = Server(name: "MyServer", version: "1.0.0")

// Signal handler for clean shutdown
signal(SIGINT) { _ in
    Task { await server.stop() }
}

try await server.start(transport: transport)
await server.waitUntilCompleted()
```

## See Also

- <doc:server-setup>
- <doc:server-tools>
- <doc:server-resources>
- <doc:server-prompts>
- ``Server``
- ``MCPServer``
- ``RequestHandlerContext``
