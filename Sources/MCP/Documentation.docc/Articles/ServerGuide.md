# Server Guide

Build MCP servers that expose tools, resources, and prompts to clients.

## Overview

The ``Server`` component allows your application to host MCP capabilities and respond to client requests. This guide covers all server functionality from basic setup to advanced features.

## Basic Setup

Create a server with capabilities and start it:

```swift
import MCP

// Create a server with capabilities
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(
        prompts: .init(listChanged: true),
        resources: .init(subscribe: true, listChanged: true),
        tools: .init(listChanged: true)
    )
)

// Start the server with a transport
let transport = StdioTransport()
try await server.start(transport: transport)
```

## Tools

Tools represent functions that clients can call.

### Registering Tools

```swift
// Register tool list handler
await server.withRequestHandler(ListTools.self) { _ in
    return .init(tools: [
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

// Register tool call handler
await server.withRequestHandler(CallTool.self) { params in
    switch params.name {
    case "weather":
        let location = params.arguments?["location"]?.stringValue ?? "Unknown"
        let weather = getWeather(location: location)
        return .init(content: [.text("Weather in \(location): \(weather)")])

    default:
        return .init(content: [.text("Unknown tool")], isError: true)
    }
}
```

### Tool Annotations

Provide hints about tool behavior:

```swift
Tool(
    name: "delete_file",
    description: "Delete a file from the filesystem",
    inputSchema: [...],
    annotations: .init(
        title: "Delete File",          // Human-readable title
        destructiveHint: true,         // May cause irreversible changes
        idempotentHint: false,         // Different results on repeated calls
        readOnlyHint: false,           // Modifies state
        openWorldHint: false           // Only accesses specified resources
    )
)
```

### Tool Icons

Add visual representation:

```swift
Tool(
    name: "search",
    description: "Search the web",
    inputSchema: [...],
    icons: [
        Icon(uri: "https://example.com/search-icon.png", mimeType: "image/png")
    ]
)
```

### Output Schema and Structured Content

Tools can define an output schema for validated structured results:

```swift
Tool(
    name: "get_weather",
    description: "Get weather data",
    inputSchema: [...],
    outputSchema: [
        "type": "object",
        "properties": [
            "temperature": ["type": "number"],
            "conditions": ["type": "string"]
        ],
        "required": ["temperature", "conditions"]
    ]
)
```

Return structured content alongside text:

```swift
await server.withRequestHandler(CallTool.self) { params in
    let data: [String: Value] = [
        "temperature": 22.5,
        "conditions": "Partly cloudy"
    ]

    return .init(
        content: [.text("{\"temperature\": 22.5, \"conditions\": \"Partly cloudy\"}")],
        structuredContent: data
    )
}
```

## Resources

Resources represent data that clients can access.

### Registering Resources

```swift
// List available resources
await server.withRequestHandler(ListResources.self) { _ in
    return .init(resources: [
        Resource(
            name: "Configuration",
            uri: "config://app",
            description: "Application configuration",
            mimeType: "application/json",
            icons: [Icon(uri: "https://example.com/config-icon.png", mimeType: "image/png")]
        ),
        Resource(
            name: "Logs",
            uri: "logs://app/recent",
            description: "Recent application logs"
        )
    ])
}

// Read resource content
await server.withRequestHandler(ReadResource.self) { params in
    switch params.uri {
    case "config://app":
        let config = loadConfiguration()
        return .init(contents: [
            .text(config.jsonString, uri: params.uri, mimeType: "application/json")
        ])

    default:
        throw MCPError.resourceNotFound("Unknown resource: \(params.uri)")
    }
}
```

### Resource Templates

Expose dynamic resources with URI templates:

```swift
await server.withRequestHandler(ListResourceTemplates.self) { _ in
    return .init(resourceTemplates: [
        Resource.Template(
            uriTemplate: "file:///{path}",
            name: "File",
            description: "Access files by path"
        )
    ])
}
```

### Resource Subscriptions

Handle subscription requests:

```swift
await server.withRequestHandler(ResourceSubscribe.self) { params, context in
    // Track the subscription
    subscriptions.add(params.uri)
    return .init()
}

// Later, notify subscribers of changes
try await context.sendResourceUpdated(uri: "config://app")
```

## Prompts

Prompts are templated conversation starters.

### Registering Prompts

```swift
await server.withRequestHandler(ListPrompts.self) { _ in
    return .init(prompts: [
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

await server.withRequestHandler(GetPrompt.self) { params in
    guard params.name == "code-review" else {
        throw MCPError.invalidParams("Unknown prompt: \(params.name)")
    }

    let language = params.arguments?["language"] ?? "unknown"
    let code = params.arguments?["code"] ?? ""

    return .init(
        description: "Code review for \(language)",
        messages: [
            .user("Please review this \(language) code for best practices:\n\n```\(language)\n\(code)\n```"),
            .assistant("I'll analyze this code for potential improvements...")
        ]
    )
}
```

## Completions

Provide autocomplete suggestions for prompt arguments and resource templates:

```swift
await server.withRequestHandler(Complete.self) { params in
    switch params.ref {
    case .prompt(let promptRef):
        // Autocomplete prompt arguments
        if promptRef.name == "code-review" && params.argument.name == "language" {
            let prefix = params.argument.value
            let languages = ["python", "javascript", "swift", "rust"]
            let matches = languages.filter { $0.hasPrefix(prefix) }
            return .init(completion: .init(values: matches))
        }

    case .resource(let resourceRef):
        // Autocomplete resource template parameters
        break
    }

    return .init(completion: .init(values: []))
}
```

## Roots

Request the client's filesystem roots to understand which locations the server can access:

```swift
await server.withRequestHandler(CallTool.self) { [server] params, context in
    guard params.name == "list-files" else { ... }

    // Get roots from the client
    let roots = try await server.listRoots()

    var files: [String] = []
    for root in roots {
        // root.uri is the filesystem location (e.g., "file:///Users/me/project")
        // root.name is the display name (e.g., "Project")
        let rootFiles = try listFilesIn(root.uri)
        files.append(contentsOf: rootFiles)
    }

    return .init(content: [.text("Found \(files.count) files")])
}
```

> Note: The client must have roots capability enabled and a roots handler registered. See <doc:ClientGuide#Roots-Handler>.

## Progress Notifications

Send progress updates during long-running operations:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    guard params.name == "process-data" else { ... }

    // Get the progress token from the request
    let progressToken = params._meta?.progressToken

    // Report progress
    if let token = progressToken {
        try await context.sendProgress(
            token: token,
            progress: 0,
            total: 100,
            message: "Starting..."
        )
    }

    // Do work...
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

    return .init(content: [.text("Processing complete")])
}
```

## Elicitation

Request additional information from users through the client.

### Basic Elicitation

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    // Request user input
    let result = try await context.elicit(
        message: "Please provide your credentials",
        requestedSchema: ElicitationSchema(properties: [
            "username": .string(StringSchema(title: "Username")),
            "password": .string(StringSchema(title: "Password", format: .password))
        ], required: ["username", "password"])
    )

    guard result.action == .accept, let content = result.content else {
        return .init(content: [.text("Operation cancelled")], isError: true)
    }

    // Use the provided values
    let username = content["username"]?.stringValue ?? ""
    return .init(content: [.text("Authenticated as \(username)")])
}
```

### URL Elicitation

Request users to visit a URL (useful for OAuth):

```swift
try await context.elicitUrl(
    message: "Please authorize access to your account",
    url: "https://auth.example.com/authorize?client_id=...",
    elicitationId: UUID().uuidString
)
```

## Sampling

Request LLM completions from the client. Enable the capability first:

```swift
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(
        sampling: .init()  // Enable sampling
    )
)
```

Then request completions:

```swift
await server.withRequestHandler(CallTool.self) { [server] params, context in
    // Request an LLM completion from the client
    let result = try await server.createMessage(
        CreateSamplingMessage.Parameters(
            messages: [.user("Summarize this data: \(data)")],
            systemPrompt: "You are a helpful data analyst",
            maxTokens: 500
        )
    )

    if case .text(let text, _, _) = result.content {
        return .init(content: [.text(text)])
    }
    return .init(content: [.text("Failed to get completion")])
}
```

## Initialize Hook

Control client connections with validation:

```swift
try await server.start(transport: transport) { clientInfo, capabilities in
    // Validate the client
    guard clientInfo.name != "BlockedClient" else {
        throw MCPError.invalidRequest("Client not allowed")
    }

    // Log connection
    print("Client connected: \(clientInfo.name) v\(clientInfo.version)")

    // Check client capabilities
    if capabilities.sampling == nil {
        print("Note: Client does not support sampling")
    }
}
```

## Sending Notifications

The ``RequestHandlerContext`` provides methods for sending notifications:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    // Progress updates
    try await context.sendProgress(token: token, progress: 50, total: 100)

    // Log messages
    try await context.sendLogMessage(level: .info, logger: "my-tool", data: "Processing...")

    // Resource changes
    try await context.sendResourceListChanged()
    try await context.sendResourceUpdated(uri: "config://app")

    // Tool/prompt changes
    try await context.sendToolListChanged()
    try await context.sendPromptListChanged()

    return .init(content: [...])
}
```

## Graceful Shutdown

Use [Swift Service Lifecycle](https://github.com/swift-server/swift-service-lifecycle) for production deployments:

```swift
import ServiceLifecycle

struct MCPService: Service {
    let server: Server
    let transport: Transport

    func run() async throws {
        try await server.start(transport: transport)
        try await Task.sleep(for: .days(365 * 100))  // Run indefinitely
    }

    func shutdown() async throws {
        await server.stop()
    }
}

// Create and run with signal handling
let serviceGroup = ServiceGroup(
    services: [MCPService(server: server, transport: transport)],
    configuration: .init(gracefulShutdownSignals: [.sigterm, .sigint]),
    logger: logger
)

try await serviceGroup.run()
```

## Request Handler Context

Handlers receive a ``RequestHandlerContext`` with useful utilities:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    // Check if the request was cancelled
    try context.checkCancellation()

    // Access request metadata
    if let taskId = params._meta?.relatedTaskId {
        print("Part of task: \(taskId)")
    }

    // Send notifications via context
    try await context.sendLogMessage(level: .debug, logger: "tool", data: "Working...")

    return .init(content: [...])
}
```

## See Also

- <doc:ClientGuide>
- <doc:Transports>
- <doc:Examples>
- ``Server``
