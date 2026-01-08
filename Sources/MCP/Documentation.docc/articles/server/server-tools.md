# Tools

Register tools that clients can discover and call

## Overview

Tools are functions that your server exposes to clients. Each tool has a name, description, and input schema. Clients can list available tools and call them with arguments.

## Registering Tools

Register handlers for listing and calling tools:

```swift
// List available tools
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

// Handle tool calls
await server.withRequestHandler(CallTool.self) { params, _ in
    switch params.name {
    case "weather":
        let location = params.arguments?["location"]?.stringValue ?? "Unknown"
        let weather = await getWeather(location: location)
        return CallTool.Result(content: [.text("Weather in \(location): \(weather)")])

    default:
        return CallTool.Result(content: [.text("Unknown tool")], isError: true)
    }
}
```

## Tool Input Schema

Define expected parameters using JSON Schema:

```swift
Tool(
    name: "search",
    description: "Search documents",
    inputSchema: [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Search query"
            ],
            "limit": [
                "type": "integer",
                "description": "Maximum results",
                "default": 10
            ]
        ],
        "required": ["query"]
    ]
)
```

## Tool Annotations

Provide hints about tool behavior to help clients make decisions:

```swift
Tool(
    name: "delete_file",
    description: "Delete a file from the filesystem",
    inputSchema: [...],
    annotations: .init(
        title: "Delete File",       // Human-readable title
        destructiveHint: true,      // May cause irreversible changes
        idempotentHint: false,      // Different results on repeated calls
        readOnlyHint: false,        // Modifies state
        openWorldHint: false        // Only accesses specified resources
    )
)
```

### Annotation Meanings

- **title**: Human-readable name for UI display
- **readOnlyHint**: Tool only reads data, doesn't modify anything
- **destructiveHint**: Tool may cause irreversible changes
- **idempotentHint**: Calling multiple times has same effect as once
- **openWorldHint**: Tool may access resources beyond its inputs

## Tool Icons

Add visual representation for UI display:

```swift
Tool(
    name: "search",
    description: "Search the web",
    inputSchema: [...],
    icons: [
        Icon(src: "https://example.com/search-icon.png", mimeType: "image/png")
    ]
)
```

## Response Content Types

Tool results support multiple content types:

### Text

```swift
CallTool.Result(content: [.text("Hello, world!")])
```

### Images

```swift
let imageData = // base64-encoded image data
CallTool.Result(content: [
    .image(data: imageData, mimeType: "image/png")
])
```

### Audio

```swift
let audioData = // base64-encoded audio data
CallTool.Result(content: [
    .audio(data: audioData, mimeType: "audio/mp3")
])
```

### Multiple Content Items

```swift
CallTool.Result(content: [
    .text("Here's the chart:"),
    .image(data: chartData, mimeType: "image/png")
])
```

## Error Responses

Indicate tool errors using the `isError` flag:

```swift
CallTool.Result(
    content: [.text("File not found: /path/to/file")],
    isError: true
)
```

## Output Schema and Structured Content

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

Return structured content alongside human-readable text:

```swift
await server.withRequestHandler(CallTool.self) { params, _ in
    let data: [String: Value] = [
        "temperature": 22.5,
        "conditions": "Partly cloudy"
    ]

    return CallTool.Result(
        content: [.text("Temperature: 22.5°C, Partly cloudy")],
        structuredContent: .object(data)
    )
}
```

## Notifying Tool Changes

If your server declared `tools.listChanged` capability, notify clients when tools change:

```swift
// After adding/removing tools
try await context.sendToolListChanged()
```

## See Also

- <doc:server-setup>
- <doc:client-tools>
- ``Server``
- ``Tool``
