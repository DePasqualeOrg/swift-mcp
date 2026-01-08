# Sampling

Request LLM completions from MCP clients

## Overview

Sampling enables servers to request LLM completions from clients. The client handles the actual model interaction while the server focuses on its domain logic. This is useful when your server needs AI assistance to process data or generate content.

> Note: Sampling is a client capability, not a server capability. Your server requests sampling from clients that support it.

## Basic Sampling

Request a completion using ``Server/createMessage(_:)``:

```swift
await server.withRequestHandler(CallTool.self) { [server] params, context in
    guard params.name == "summarize" else { ... }

    let data = params.arguments?["data"]?.stringValue ?? ""

    let result = try await server.createMessage(
        CreateSamplingMessage.Parameters(
            messages: [.user(.text("Summarize this data: \(data)"))],
            maxTokens: 500
        )
    )

    // Extract the response
    if let text = result.content.first, case .text(let summary, _, _) = text {
        return CallTool.Result(content: [.text(summary)])
    }

    return CallTool.Result(content: [.text("Failed to generate summary")], isError: true)
}
```

## Sampling Parameters

Configure the sampling request:

```swift
let result = try await server.createMessage(
    CreateSamplingMessage.Parameters(
        messages: [
            .user(.text("Translate to Spanish: Hello, world!"))
        ],
        modelPreferences: ModelPreferences(
            hints: [.init(name: "claude-3")],
            intelligencePriority: 0.8
        ),
        systemPrompt: "You are a helpful translator.",
        maxTokens: 200,
        temperature: 0.3,
        stopSequences: ["---"]
    )
)
```

### Parameters

- `messages`: Conversation history
- `systemPrompt`: System prompt for the model
- `maxTokens`: Maximum tokens in response
- `temperature`: Sampling temperature
- `modelPreferences`: Model selection hints
- `stopSequences`: Sequences that stop generation
- `includeContext`: Whether to include conversation context

## Multi-turn Conversations

Build a conversation with multiple messages:

```swift
let result = try await server.createMessage(
    CreateSamplingMessage.Parameters(
        messages: [
            .user(.text("What is 2 + 2?")),
            .assistant(.text("2 + 2 equals 4.")),
            .user(.text("And if I add 3 more?"))
        ],
        maxTokens: 100
    )
)
```

## Sampling with Tools

Request completions that can use tools with ``Server/createMessageWithTools(_:)``:

```swift
let result = try await server.createMessageWithTools(
    CreateSamplingMessageWithTools.Parameters(
        messages: [.user(.text("What's the weather in Paris?"))],
        maxTokens: 500,
        tools: [
            Tool(
                name: "get_weather",
                description: "Get current weather",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "location": ["type": "string"]
                    ]
                ]
            )
        ],
        toolChoice: ToolChoice(mode: .auto)
    )
)

// Check if model wants to use a tool
for content in result.content {
    if case .toolUse(let toolUse) = content {
        print("Model wants to call: \(toolUse.name)")
        print("With arguments: \(toolUse.input)")
    }
}
```

## Handling Responses

The response contains content blocks:

```swift
let result = try await server.createMessage(...)

for content in result.content {
    switch content {
    case .text(let text, _, _):
        print("Text: \(text)")
    case .image(let data, let mimeType, _, _):
        print("Image: \(mimeType)")
    case .toolUse(let toolUse):
        print("Tool call: \(toolUse.name)")
    default:
        break
    }
}

// Check stop reason
switch result.stopReason {
case .endTurn:
    print("Natural end of response")
case .maxTokens:
    print("Hit token limit")
case .toolUse:
    print("Stopped for tool use")
default:
    break
}
```

## Error Handling

Handle cases where sampling isn't available:

```swift
do {
    let result = try await server.createMessage(...)
} catch let error as MCPError {
    if case .invalidRequest(let message) = error,
       message.contains("sampling") {
        // Client doesn't support sampling
        return CallTool.Result(
            content: [.text("This feature requires an AI-capable client")],
            isError: true
        )
    }
    throw error
}
```

## See Also

- <doc:server-setup>
- <doc:client-sampling>
- ``Server``
