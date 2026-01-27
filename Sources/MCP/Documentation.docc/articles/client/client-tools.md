# Tools

List and call tools provided by MCP servers

## Overview

Tools represent functions that servers expose for clients to call. Each tool has a name, description, and input schema that defines its parameters. This guide covers discovering available tools and calling them.

## Security Considerations

When invoking tools, client implementations should:

- Show tool inputs to the user before calling the server to prevent accidental or malicious data exfiltration
- Prompt for user confirmation on sensitive or destructive operations (check `annotations.destructiveHint`)
- Implement timeouts for tool calls
- Log tool usage for audit purposes

## Listing Tools

Use ``Client/listTools(cursor:)`` to discover available tools:

```swift
let result = try await client.listTools()
for tool in result.tools {
    print("\(tool.name): \(tool.description ?? "")")
}
```

### Pagination

For servers with many tools, use the cursor for pagination:

```swift
var cursor: String? = nil
repeat {
    let result = try await client.listTools(cursor: cursor)
    for tool in result.tools {
        print(tool.name)
    }
    cursor = result.nextCursor
} while cursor != nil
```

### Tool Metadata

Each ``Tool`` includes metadata you can use to display or filter tools:

```swift
let result = try await client.listTools()
for tool in result.tools {
    // Basic info
    print("Name: \(tool.name)")
    print("Title: \(tool.title ?? tool.name)")
    print("Description: \(tool.description ?? "")")

    // Annotations provide behavioral hints
    if tool.annotations.readOnlyHint == true {
        print("This tool only reads data")
    }
    if tool.annotations.destructiveHint == true {
        print("Warning: This tool may make destructive changes")
    }
}
```

## Calling Tools

Use ``Client/callTool(name:arguments:)`` to invoke a tool:

```swift
let result = try await client.callTool(
    name: "weather",
    arguments: [
        "location": "San Francisco",
        "units": "metric"
    ]
)
```

### Tracking Progress

Use ``Client/callTool(name:arguments:onProgress:)`` to receive progress notifications during execution:

```swift
let result = try await client.callTool(
    name: "process_data",
    arguments: ["input": "data.csv"],
    onProgress: { progress in
        print("Progress: \(progress.value) / \(progress.total ?? 100)")
    }
)
```

The client automatically injects a progress token into the request. For more control over timeouts and progress, see <doc:client-advanced>.

### Using MCPClient

When using ``MCPClient``, tool calls automatically reconnect and retry on recoverable errors (session expiration, connection loss, transport errors):

```swift
let result = try await mcpClient.callTool(
    name: "weather",
    arguments: ["location": "San Francisco"]
)
```

See <doc:client-setup> for ``MCPClient`` setup details.

### Checking for Errors

The result includes an `isError` flag:

```swift
if result.isError == true {
    print("Tool call failed")
}
```

### Handling Response Content

Tool results contain an array of content items. Each item can be text, image, audio, a resource, or a resource link:

```swift
for item in result.content {
    switch item {
        case .text(let text, _, _):
            print("Text: \(text)")
        case .image(let data, let mimeType, _, _):
            print("Image (\(mimeType)): \(data.count) chars base64")
        case .audio(let data, let mimeType, _, _):
            print("Audio (\(mimeType))")
        case .resource(let resource, _, _):
            print("Resource: \(resource.uri)")
        case .resourceLink(let link):
            print("Link: \(link.uri)")
    }
}
```

### Structured Content

Tools may return structured data in addition to content:

```swift
if let structured = result.structuredContent {
    // structured is a Value that can be decoded
    print("Structured result: \(structured)")
}
```

## Listening for Tool List Changes

Servers can notify clients when available tools change. Register a notification handler:

```swift
await client.onNotification(ToolListChangedNotification.self) { _ in
    // Refresh the tool list
    let updated = try await client.listTools()
    print("Tools updated: \(updated.tools.count) tools available")
}
```

## See Also

- <doc:client-setup>
- <doc:client-advanced>
- <doc:server-tools>
- ``MCPClient``
- ``Client``
- ``Tool``
