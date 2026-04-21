# Sampling

Handle LLM completion requests from MCP servers

## Overview

Sampling enables servers to request LLM completions through the client. This allows servers to perform sophisticated AI-powered tasks while the client maintains control over model access. When a server needs AI assistance, it sends a sampling request to the client, which processes it using its LLM service.

## Human in the Loop

Client implementations should include human oversight for sampling requests:

- Provide UI to review sampling requests before processing
- Allow users to view and edit prompts before sending to the LLM
- Present generated responses for review before returning to the server
- Give users the ability to deny or modify any sampling request

This ensures users maintain control over AI interactions initiated by servers.

## Registering a Sampling Handler

Use ``Client/withSamplingHandler(supportsContext:supportsTools:handler:)`` to register a handler for sampling requests. The sampling capability is automatically advertised when you register a handler:

```swift
let client = Client(name: "MyApp", version: "1.0.0")

// Register with sub-capabilities
await client.withSamplingHandler(
    supportsContext: true,  // Support includeContext parameter
    supportsTools: true     // Support tools in sampling requests
) { params, context in
    // Handle the request...
}

try await client.connect(transport: transport)
```

> Important: Register handlers before calling `connect()`. Attempting to register handlers after connecting will result in an error.

### Basic Handler

```swift
await client.withSamplingHandler { params, context in
    // params contains the request parameters
    // context provides cancellation checking and progress reporting

    // Call your LLM service
    let response = try await yourLLMService.complete(
        messages: params.messages,
        systemPrompt: params.systemPrompt,
        maxTokens: params.maxTokens,
        temperature: params.temperature
    )

    // Return the result
    return ClientSamplingRequest.Result(
        model: "your-model-name",
        stopReason: .endTurn,
        role: .assistant,
        content: .text(response.text)
    )
}
```

## Request Parameters

The handler receives ``/MCPCore/ClientSamplingParameters`` with:

- `messages`: The conversation history as `[Sampling.Message]`
- `systemPrompt`: Optional system prompt
- `maxTokens`: Maximum tokens for the response
- `temperature`: Optional sampling temperature
- `modelPreferences`: Optional model selection hints
- `tools`: Optional array of tools the model can use
- `toolChoice`: How the model should use tools (auto, required, none)
- `stopSequences`: Optional sequences that stop generation

Check if tools are included:

```swift
await client.withSamplingHandler { params, context in
    if params.hasTools {
        // Handle with tool support
        return try await handleWithTools(params)
    } else {
        // Handle without tools
        return try await handleSimple(params)
    }
}
```

## Result Types

Return a ``/MCPCore/ClientSamplingRequest/Result`` with:

- `model`: The name of the model used
- `stopReason`: Why generation stopped (`.endTurn`, `.stopSequence`, `.maxTokens`, `.toolUse`)
- `role`: Always `.assistant`
- `content`: The response content

### Text Response

```swift
return ClientSamplingRequest.Result(
    model: "gpt-4",
    stopReason: .endTurn,
    role: .assistant,
    content: .text("Here's my response...")
)
```

### Multiple Content Blocks

```swift
return ClientSamplingRequest.Result(
    model: "gpt-4",
    stopReason: .endTurn,
    role: .assistant,
    content: [
        .text("Here's the analysis:"),
        .image(data: imageBase64, mimeType: "image/png")
    ]
)
```

### Tool Use Response

When the model decides to use a tool:

```swift
return ClientSamplingRequest.Result(
    model: "gpt-4",
    stopReason: .toolUse,
    role: .assistant,
    content: .toolUse(ToolUseContent(
        name: "search",
        id: "call_123",
        input: ["query": "Swift programming"]
    ))
)
```

## Cancellation Support

Check for cancellation during long operations:

```swift
await client.withSamplingHandler { params, context in
    // Check if cancelled before expensive operations
    try context.checkCancellation()

    let response = try await llm.complete(...)

    // Or check the property directly
    if context.isCancelled {
        throw CancellationError()
    }

    return ClientSamplingRequest.Result(...)
}
```

## Progress Reporting

Report progress back to the server:

```swift
await client.withSamplingHandler { params, context in
    if let token = context._meta?.progressToken {
        try await context.sendProgress(
            token: token,
            progress: 50.0,
            total: 100.0,
            message: "Processing request..."
        )
    }

    // Continue processing...
    return ClientSamplingRequest.Result(...)
}
```

## See Also

- <doc:client-setup>
- <doc:server-sampling>
- ``Client``
