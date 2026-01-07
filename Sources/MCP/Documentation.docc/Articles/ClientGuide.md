# Client Guide

Build MCP clients that connect to servers and access their capabilities.

## Overview

The ``Client`` component allows your application to connect to MCP servers and interact with their tools, resources, and prompts. This guide covers all client functionality from basic usage to advanced features.

## Basic Setup

Create a client and connect to a server:

```swift
import MCP

// Create a client with implementation info
let client = Client(name: "MyApp", version: "1.0.0")

// Connect using a transport
let transport = StdioTransport()
let result = try await client.connect(transport: transport)

// Check server capabilities
if result.capabilities.tools != nil {
    print("Server supports tools")
}
```

> Note: The ``Client/connect(transport:)`` method returns the initialization result containing server capabilities. This return value is discardable if you don't need to inspect capabilities.

## Transport Options

### Stdio Transport

For local subprocess communication:

```swift
let transport = StdioTransport()
try await client.connect(transport: transport)
```

### HTTP Transport

For remote server communication:

```swift
let transport = HTTPClientTransport(
    endpoint: URL(string: "http://localhost:8080/mcp")!,
    streaming: true  // Enable Server-Sent Events
)
try await client.connect(transport: transport)
```

See <doc:Transports> for all available transport options.

## Tools

Tools represent functions that can be called by the client.

### Listing Tools

```swift
let result = try await client.listTools()
for tool in result.tools {
    print("\(tool.name): \(tool.description ?? "")")
}
// Use result.nextCursor for pagination
```

### Calling Tools

```swift
let result = try await client.callTool(
    name: "image-generator",
    arguments: [
        "prompt": "A serene mountain landscape",
        "width": 1024,
        "height": 768
    ]
)

// Check for errors
if result.isError == true {
    print("Tool call failed")
}

// Handle the response content
for item in result.content {
    switch item {
    case .text(let text, _, _):
        print("Text: \(text)")
    case .image(let data, let mimeType, _, _):
        print("Image: \(mimeType), \(data.count) bytes")
    case .audio(let data, let mimeType, _, _):
        print("Audio: \(mimeType)")
    case .resource(let resource, _, _):
        print("Resource: \(resource.uri)")
    case .link(let link, _, _):
        print("Link: \(link.uri)")
    }
}
```

## Resources

Resources represent data that can be accessed and subscribed to.

### Listing Resources

```swift
let result = try await client.listResources()
for resource in result.resources {
    print("\(resource.uri): \(resource.name)")
}
// Use result.nextCursor for pagination
```

### Reading Resources

```swift
let result = try await client.readResource(uri: "file:///path/to/file.txt")
for content in result.contents {
    if let text = content.text {
        print(text)
    }
}
```

### Resource Templates

List available resource templates for dynamic URIs:

```swift
let result = try await client.listResourceTemplates()
for template in result.resourceTemplates {
    print("\(template.uriTemplate): \(template.name)")
}
// Use result.nextCursor for pagination
```

### Subscribing to Updates

```swift
// Subscribe to resource changes
try await client.subscribeToResource(uri: "file:///config.json")

// Handle update notifications
await client.onNotification(ResourceUpdatedNotification.self) { message in
    print("Resource updated: \(message.params.uri)")

    // Fetch the updated content
    let updated = try await client.readResource(uri: message.params.uri)
}
```

## Prompts

Prompts represent templated conversation starters.

### Listing Prompts

```swift
let result = try await client.listPrompts()
for prompt in result.prompts {
    print("\(prompt.name): \(prompt.description ?? "")")
}
// Use result.nextCursor for pagination
```

### Getting a Prompt

```swift
let result = try await client.getPrompt(
    name: "customer-service",
    arguments: [
        "customerName": "Alice",
        "issue": "delivery delay"
    ]
)

for message in result.messages {
    if case .text(let text, _, _) = message.content {
        print("\(message.role): \(text)")
    }
}
```

## Completions

Request autocomplete suggestions for prompt arguments or resource template URIs:

```swift
// Complete a prompt argument
let result = try await client.complete(
    ref: .prompt(PromptReference(name: "greet")),
    argument: .init(name: "name", value: "Jo")
)

for value in result.completion.values {
    print("Suggestion: \(value)")
}
```

## Sampling Handler

Sampling allows servers to request LLM completions through the client. Register a handler to process these requests:

```swift
await client.withSamplingHandler { parameters in
    // The server is requesting an LLM completion
    print("Server requests: \(parameters.messages)")

    // Call your LLM service
    let completion = try await yourLLMService.complete(
        messages: parameters.messages,
        maxTokens: parameters.maxTokens,
        temperature: parameters.temperature
    )

    // Return the result
    return CreateSamplingMessage.Result(
        model: "your-model-name",
        stopReason: .endTurn,
        role: .assistant,
        content: .text(completion)
    )
}
```

> Tip: Sampling requests flow from server to client. This enables servers to request AI assistance while clients maintain control over model access and approval.

## Elicitation Handler

Servers can request additional information from users through elicitation. Register a handler to display these requests:

```swift
await client.withElicitationHandler { request in
    // Display the form to the user based on request.requestedSchema
    let userResponses = try await showFormToUser(
        message: request.message,
        schema: request.requestedSchema
    )

    // Return the user's responses
    return ElicitResult(
        action: .accept,
        content: userResponses
    )
}
```

Elicitation schemas can include various field types:

```swift
// The server might request:
ElicitationSchema(properties: [
    "apiKey": .string(StringSchema(title: "API Key", format: .password)),
    "rememberMe": .boolean(BooleanSchema(title: "Remember Me")),
    "priority": .untitledEnum(UntitledEnumSchema(title: "Priority", enumValues: ["low", "medium", "high"]))
])
```

## Roots Handler

Expose filesystem roots to the server:

```swift
await client.withRootsHandler {
    return [
        Root(uri: "file:///Users/me/projects", name: "Projects"),
        Root(uri: "file:///Users/me/documents", name: "Documents")
    ]
}

// Notify when roots change
try await client.sendRootsChanged()
```

## Request Batching

Improve performance by sending multiple requests in a single batch:

```swift
var toolTasks: [Task<CallTool.Result, Error>] = []

try await client.withBatch { batch in
    for i in 0..<10 {
        toolTasks.append(
            try await batch.addRequest(
                CallTool.request(.init(name: "square", arguments: ["n": Value(i)]))
            )
        )
    }
}

// Process results after the batch completes
for (index, task) in toolTasks.enumerated() {
    let result = try await task.value
    print("\(index): \(result.content)")
}
```

## Request Timeouts

Configure timeouts for individual requests:

```swift
// Set a custom timeout
let result = try await client.send(
    CallTool.request(.init(name: "slow-operation", arguments: [:])),
    timeout: .seconds(60)
)
```

## Request Cancellation

Cancel in-flight requests:

```swift
// Start a request
let requestId = RequestId.string(UUID().uuidString)
let task = Task {
    try await client.send(
        CallTool.request(.init(name: "long-operation", arguments: [:]), id: requestId)
    )
}

// Cancel it later
await client.cancelRequest(requestId, reason: "User cancelled")
task.cancel()
```

## Progress Notifications

Handle progress updates from long-running operations:

```swift
// Register for progress notifications
await client.onNotification(ProgressNotification.self) { message in
    let params = message.params

    if let total = params.total, total > 0 {
        let percentage = (params.progress / total) * 100
        print("Progress: \(Int(percentage))%")
    }

    if let status = params.message {
        print("Status: \(status)")
    }
}

// Include a progress token in requests
let result = try await client.send(
    CallTool.request(.init(
        name: "long-operation",
        arguments: [:],
        _meta: RequestMeta(progressToken: .string("my-token"))
    ))
)
```

## Configuration Options

### Strict Mode

Control capability checking behavior:

```swift
// Strict mode - fail if capability not available
let strictClient = Client(
    name: "StrictClient",
    version: "1.0.0",
    configuration: .strict
)

// Default mode - attempt requests even without capability
let flexibleClient = Client(
    name: "FlexibleClient",
    version: "1.0.0",
    configuration: .default
)
```

## Error Handling

Handle MCP-specific errors:

```swift
do {
    try await client.connect(transport: transport)
} catch let error as MCPError {
    switch error {
    case .connectionClosed(let reason):
        print("Connection closed: \(reason ?? "unknown")")
    case .requestTimeout(let message):
        print("Timeout: \(message ?? "")")
    case .methodNotFound(let method):
        print("Method not found: \(method ?? "")")
    default:
        print("MCP error: \(error)")
    }
} catch {
    print("Unexpected error: \(error)")
}
```

## See Also

- <doc:ServerGuide>
- <doc:Transports>
- ``Client``
