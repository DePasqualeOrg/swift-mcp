# Prompts

Register prompt templates that clients can discover and use

## Overview

Prompts are templated conversation starters that your server exposes to clients. Each prompt can accept arguments to customize its content. Clients can list prompts and retrieve rendered messages.

## Registering Prompts

Register handlers for listing and getting prompts:

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
            .user("Please review this \(language) code for best practices:\n\n```\(language)\n\(code)\n```"),
            .assistant("I'll analyze this code for potential improvements...")
        ]
    )
}
```

## Prompt Arguments

Define what arguments a prompt accepts:

```swift
Prompt(
    name: "summarize",
    description: "Summarize content",
    arguments: [
        Prompt.Argument(
            name: "content",
            description: "Content to summarize",
            required: true
        ),
        Prompt.Argument(
            name: "length",
            description: "Desired summary length (short, medium, long)",
            required: false
        )
    ]
)
```

## Message Types

Prompt messages can have different roles:

### User Messages

```swift
GetPrompt.Result(messages: [
    .user("Analyze this data...")
])
```

### Assistant Messages

```swift
GetPrompt.Result(messages: [
    .assistant("I'll help you analyze the data.")
])
```

### Multi-turn Conversations

```swift
GetPrompt.Result(messages: [
    .user("What is the capital of France?"),
    .assistant("The capital of France is Paris."),
    .user("What is its population?")
])
```

## Rich Content

Messages can contain different content types:

### Text

```swift
Prompt.Message(
    role: .user,
    content: .text("Hello, world!")
)
```

### Images

```swift
Prompt.Message(
    role: .user,
    content: .image(data: imageBase64, mimeType: "image/png")
)
```

### Resources

Include resource content in messages:

```swift
Prompt.Message(
    role: .user,
    content: .resource(uri: "file:///data.json", mimeType: "application/json", text: jsonContent)
)
```

### Multiple Content Items

```swift
Prompt.Message(
    role: .user,
    content: [
        .text("Please analyze this image:"),
        .image(data: imageData, mimeType: "image/png")
    ]
)
```

## Notifying Prompt Changes

If you declared `prompts.listChanged` capability, notify clients when prompts change:

```swift
try await context.sendPromptListChanged()
```

## Complete Example

```swift
let server = Server(
    name: "PromptServer",
    version: "1.0.0",
    capabilities: Server.Capabilities(
        prompts: .init(listChanged: true)
    )
)

await server.withRequestHandler(ListPrompts.self) { _, _ in
    ListPrompts.Result(prompts: [
        Prompt(
            name: "explain",
            description: "Explain a concept at different levels",
            arguments: [
                .init(name: "topic", description: "Topic to explain", required: true),
                .init(name: "level", description: "Explanation level: beginner, intermediate, expert", required: false)
            ]
        ),
        Prompt(
            name: "translate",
            description: "Translate text between languages",
            arguments: [
                .init(name: "text", description: "Text to translate", required: true),
                .init(name: "from", description: "Source language", required: true),
                .init(name: "to", description: "Target language", required: true)
            ]
        )
    ])
}

await server.withRequestHandler(GetPrompt.self) { params, _ in
    switch params.name {
    case "explain":
        let topic = params.arguments?["topic"] ?? "topic"
        let level = params.arguments?["level"] ?? "beginner"
        return GetPrompt.Result(
            description: "Explain \(topic) for \(level) level",
            messages: [
                .user("Explain \(topic) at a \(level) level.")
            ]
        )

    case "translate":
        let text = params.arguments?["text"] ?? ""
        let from = params.arguments?["from"] ?? "English"
        let to = params.arguments?["to"] ?? "Spanish"
        return GetPrompt.Result(
            description: "Translate from \(from) to \(to)",
            messages: [
                .user("Translate the following from \(from) to \(to):\n\n\(text)")
            ]
        )

    default:
        throw MCPError.invalidParams("Unknown prompt: \(params.name)")
    }
}
```

## See Also

- <doc:server-setup>
- <doc:server-completions>
- <doc:client-prompts>
- ``Server``
- ``Prompt``
