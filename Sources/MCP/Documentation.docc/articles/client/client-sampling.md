# Sampling

Handle LLM completion requests from MCP servers

## Overview

Sampling enables servers to request LLM completions through the client. This allows servers to perform sophisticated AI-powered tasks while the client maintains control over model access. When a server needs AI assistance, it sends a sampling request to the client, which processes it using its LLM service.

## Declaring Sampling Capability

Before you can handle sampling requests, declare the sampling capability when setting up your client:

```swift
let client = Client(name: "MyApp", version: "1.0.0")

await client.setCapabilities(Client.Capabilities(
    sampling: .init(
        context: .init(),  // Support includeContext parameter
        tools: .init()     // Support tools in sampling requests
    )
))
```

## Registering a Sampling Handler

Use ``Client/withSamplingHandler(_:)`` to register a handler for sampling requests:

```swift
client.withSamplingHandler { params, context in
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

The handler receives ``ClientSamplingParameters`` with:

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
client.withSamplingHandler { params, context in
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

Return a ``ClientSamplingRequest/Result`` with:

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
client.withSamplingHandler { params, context in
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
client.withSamplingHandler { params, context in
    if let token = context._meta?.progressToken {
        try await context.sendProgressNotification(
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
