# Completions

Request autocomplete suggestions for prompt arguments and resource templates

## Overview

Completions provide autocomplete suggestions when entering prompt arguments or resource template parameters. Servers that support completions can help users discover valid values.

## Completing Prompt Arguments

Request suggestions for a prompt argument using ``Client/complete(ref:argument:context:)``:

```swift
let result = try await client.complete(
    ref: .prompt(PromptReference(name: "greet")),
    argument: CompletionArgument(name: "name", value: "Jo")
)

for value in result.completion.values {
    print("Suggestion: \(value)")
}
// Might print: "John", "Joanna", "Joseph"
```

## Completing Resource Template Parameters

Request suggestions for a resource template URI parameter:

```swift
let result = try await client.complete(
    ref: .resource(ResourceTemplateReference(uri: "file:///{path}")),
    argument: CompletionArgument(name: "path", value: "src/")
)

for value in result.completion.values {
    print("Path suggestion: \(value)")
}
```

## Using Context

Provide previously-resolved argument values as context to help the server return more relevant suggestions:

```swift
let result = try await client.complete(
    ref: .prompt(PromptReference(name: "code-review")),
    argument: CompletionArgument(name: "file", value: ""),
    context: CompletionContext(arguments: [
        "directory": "/src/components"
    ])
)
```

## Handling Large Result Sets

The server may have more suggestions than it returns. Check the pagination fields:

```swift
let result = try await client.complete(
    ref: .prompt(PromptReference(name: "language")),
    argument: CompletionArgument(name: "lang", value: "")
)

print("Showing \(result.completion.values.count) suggestions")
if let total = result.completion.total {
    print("Total available: \(total)")
}
if result.completion.hasMore == true {
    print("More suggestions available")
}
```

## See Also

- <doc:client-prompts>
- <doc:client-resources>
- <doc:server-completions>
- ``Client``
