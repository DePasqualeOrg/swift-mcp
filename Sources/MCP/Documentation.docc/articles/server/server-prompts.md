# Prompts

Register prompt templates that clients can discover and use.

## Overview

Prompts are templated conversation starters that your server exposes to clients. Each prompt can accept arguments to customize its content. Clients can list prompts and retrieve rendered messages.

The Swift SDK provides two approaches:
- **`@Prompt` macro**: Define prompts as Swift types with automatic argument handling (recommended)
- **Closure-based**: Register prompts dynamically at runtime

## Defining Prompts

The `@Prompt` macro generates argument definitions and handles parsing automatically. Import `MCPPrompt` to use the `@Prompt` macro and `@Argument` property wrapper:

```swift
import MCP
import MCPPrompt
```

Here's a complete prompt definition:

```swift
@Prompt
struct CodeReview {
    static let name = "code-review"
    static let description = "Review code for best practices"

    @Argument(description: "Programming language")
    var language: String

    @Argument(description: "Code to review")
    var code: String

    func render() async throws -> [Prompt.Message] {
        [
            .user("Please review this \(language) code for best practices:\n\n```\(language)\n\(code)\n```"),
            .assistant("I'll analyze this code for potential improvements...")
        ]
    }
}
```

Most prompts don't need the ``HandlerContext``, so you can write `render()` without any parameters. If needed, you can include a `context` parameter to access logging or request metadata.

### Argument Options

Use `@Argument` to define prompt parameters:

```swift
@Prompt
struct Summarize {
    static let name = "summarize"
    static let description = "Summarize content"

    @Argument(title: "Content", description: "Content to summarize")
    var content: String

    @Argument(title: "Length", description: "Summary length: short, medium, long")
    var length: String?  // Optional argument

    func render() async throws -> [Prompt.Message] {
        let lengthHint = length.map { " Keep it \($0)." } ?? ""
        return [.user("Summarize the following:\n\n\(content)\(lengthHint)")]
    }
}
```

The `title` parameter provides a user-facing label for display in UIs. If omitted, the property name is used as the default.

## Registering Prompts

Use ``MCPServer`` to register prompts:

```swift
let server = MCPServer(name: "MyServer", version: "1.0.0")

// Register multiple prompts with result builder
try await server.register {
    CodeReview.self
    Summarize.self
}

// Or register individually
try await server.register(CodeReview.self)
```

## Dynamic Prompt Registration

For prompts defined at runtime, use closure-based registration:

```swift
let prompt = try await server.registerPrompt(
    name: "greeting",
    description: "A friendly greeting"
) {
    [.user(.text("Hello! How can I help you today?"))]
}
```

With arguments:

```swift
let prompt = try await server.registerPrompt(
    name: "translate",
    description: "Translate text between languages",
    arguments: [
        .init(name: "text", title: "Text", description: "Text to translate", required: true),
        .init(name: "from", title: "Source Language", description: "Source language", required: true),
        .init(name: "to", title: "Target Language", description: "Target language", required: true)
    ]
) { arguments, context in
    let text = arguments?["text"] ?? ""
    let from = arguments?["from"] ?? "English"
    let to = arguments?["to"] ?? "Spanish"
    return [.user("Translate from \(from) to \(to):\n\n\(text)")]
}
```

## Prompt Lifecycle

Registered prompts return a handle for lifecycle management:

```swift
let prompt = try await server.register(CodeReview.self)

// Temporarily hide from clients
await prompt.disable()

// Make available again
await prompt.enable()

// Permanently remove
await prompt.remove()
```

Disabled prompts don't appear in `listPrompts` responses and reject get attempts.

## Prompt Metadata

Add metadata for display in clients:

```swift
@Prompt
struct CodeReview {
    static let name = "code-review"
    static let title = "Code Review Assistant"
    static let description = "Review code for best practices"
    // ...
}
```

Or for dynamic prompts:

```swift
try await server.registerPrompt(
    name: "code-review",
    title: "Code Review Assistant",
    description: "Review code for best practices"
) { ... }
```

## Message Types

Prompt messages can have different roles:

### User Messages

```swift
func render() async throws -> [Prompt.Message] {
    [.user("Analyze this data...")]
}
```

### Assistant Messages

```swift
[.assistant("I'll help you analyze the data.")]
```

### Multi-turn Conversations

```swift
[
    .user("What is the capital of France?"),
    .assistant("The capital of France is Paris."),
    .user("What is its population?")
]
```

## Rich Content

Messages can contain different content types:

### Text

```swift
Prompt.Message.user(.text("Hello, world!"))
```

### Images

```swift
Prompt.Message.user(.image(data: imageBase64, mimeType: "image/png"))
```

### Audio

```swift
Prompt.Message.user(.audio(data: audioBase64, mimeType: "audio/wav"))
```

### Resources

Include resource content in messages:

```swift
Prompt.Message.user(.resource(uri: "file:///data.json", mimeType: "application/json", text: jsonContent))
```

## Notifying Changes

``MCPServer`` automatically sends list change notifications when prompts are registered, enabled, disabled, or removed. You can also send manually:

```swift
await server.sendPromptListChanged()
```

## Complete Example

```swift
@Prompt
struct Explain {
    static let name = "explain"
    static let description = "Explain a concept at different levels"

    @Argument(description: "Topic to explain")
    var topic: String

    @Argument(description: "Level: beginner, intermediate, expert")
    var level: String?

    func render() async throws -> [Prompt.Message] {
        let levelText = level ?? "beginner"
        return [.user("Explain \(topic) at a \(levelText) level.")]
    }
}

@Prompt
struct Translate {
    static let name = "translate"
    static let title = "Translation Helper"
    static let description = "Translate text between languages"

    @Argument(title: "Text", description: "Text to translate")
    var text: String

    @Argument(title: "Source Language", description: "Source language")
    var from: String

    @Argument(title: "Target Language", description: "Target language")
    var to: String

    func render() async throws -> [Prompt.Message] {
        [.user("Translate the following from \(from) to \(to):\n\n\(text)")]
    }
}

let server = MCPServer(name: "PromptServer", version: "1.0.0")

try await server.register {
    Explain.self
    Translate.self
}

try await server.run(transport: .stdio)
```

## Low-Level API

For advanced use cases like custom request handling, see <doc:server-advanced> for the manual `withRequestHandler` approach.

## See Also

- <doc:server-setup>
- <doc:server-completions>
- <doc:client-prompts>
- ``MCPServer``
- ``Prompt``
- ``PromptSpec``
