# Prompts

Discover and use prompt templates from MCP servers

## Overview

Prompts are templated conversation starters that servers expose to clients. Each prompt can accept arguments to customize its content. This guide covers listing available prompts and retrieving their messages.

## Listing Prompts

Use ``Client/listPrompts(cursor:)`` to discover available prompts:

```swift
let result = try await client.listPrompts()
for prompt in result.prompts {
    print("\(prompt.name): \(prompt.description ?? "")")
}
```

### Pagination

For servers with many prompts, use the cursor:

```swift
var cursor: String? = nil
repeat {
    let result = try await client.listPrompts(cursor: cursor)
    for prompt in result.prompts {
        print(prompt.name)
    }
    cursor = result.nextCursor
} while cursor != nil
```

### Prompt Arguments

Prompts can define arguments that customize their content:

```swift
let result = try await client.listPrompts()
for prompt in result.prompts {
    print("Prompt: \(prompt.name)")
    if let arguments = prompt.arguments {
        for arg in arguments {
            let required = arg.required == true ? "(required)" : "(optional)"
            print("  - \(arg.name) \(required): \(arg.description ?? "")")
        }
    }
}
```

## Getting a Prompt

Use ``Client/getPrompt(name:arguments:)`` to retrieve a prompt's messages:

```swift
let result = try await client.getPrompt(
    name: "code-review",
    arguments: [
        "language": "swift",
        "code": "func hello() { print(\"Hello\") }"
    ]
)

// The result contains the rendered messages
if let description = result.description {
    print("Description: \(description)")
}

for message in result.messages {
    print("\(message.role):")
    switch message.content {
    case .text(let text, _, _):
        print("  \(text)")
    case .image(let data, let mimeType, _, _):
        print("  [Image: \(mimeType)]")
    case .audio(let data, let mimeType, _, _):
        print("  [Audio: \(mimeType)]")
    case .resource(let resource, _, _):
        print("  [Resource: \(resource.uri)]")
    case .resourceLink(let link):
        print("  [Link: \(link.uri)]")
    }
}
```

## Listening for Prompt List Changes

Servers can notify clients when available prompts change:

```swift
await client.onNotification(PromptListChangedNotification.self) { _ in
    // Refresh the prompt list
    let updated = try await client.listPrompts()
    print("Prompts updated: \(updated.prompts.count) prompts available")
}
```

## See Also

- <doc:client-setup>
- <doc:client-completions>
- <doc:server-prompts>
- ``Client``
- ``Prompt``
