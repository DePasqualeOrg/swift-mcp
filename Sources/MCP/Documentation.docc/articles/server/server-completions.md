# Completions

Offer autocomplete suggestions for prompt arguments and resource templates

## Overview

Completions enable your server to provide autocomplete suggestions when clients enter prompt arguments or resource template parameters. This improves usability by helping users discover valid values.

## Handling Completion Requests

Register a handler for completion requests:

```swift
await server.withRequestHandler(Complete.self) { params, _ in
    switch params.ref {
    case .prompt(let promptRef):
        return handlePromptCompletion(promptRef, argument: params.argument)

    case .resource(let resourceRef):
        return handleResourceCompletion(resourceRef, argument: params.argument)
    }
}
```

## Prompt Argument Completions

Provide suggestions for prompt arguments:

```swift
func handlePromptCompletion(
    _ ref: PromptReference,
    argument: CompletionArgument
) -> Complete.Result {
    if ref.name == "code-review" && argument.name == "language" {
        let prefix = argument.value
        let languages = ["python", "javascript", "swift", "rust", "go", "java"]
        let matches = languages.filter { $0.hasPrefix(prefix) }
        return Complete.Result(completion: .init(values: matches))
    }

    return Complete.Result(completion: .init(values: []))
}
```

## Resource Template Completions

Provide suggestions for resource template parameters:

```swift
func handleResourceCompletion(
    _ ref: ResourceTemplateReference,
    argument: CompletionArgument
) -> Complete.Result {
    // Template: "file:///{path}"
    if ref.uri == "file:///{path}" && argument.name == "path" {
        let prefix = argument.value
        let files = listFilesWithPrefix(prefix)
        return Complete.Result(completion: .init(values: files))
    }

    return Complete.Result(completion: .init(values: []))
}
```

## Pagination

Indicate when more results are available:

```swift
let allMatches = fetchAllMatches(prefix)
let displayedMatches = Array(allMatches.prefix(20))

return Complete.Result(completion: .init(
    values: displayedMatches,
    total: allMatches.count,
    hasMore: allMatches.count > 20
))
```

## Complete Example

```swift
let server = Server(
    name: "CompletionServer",
    version: "1.0.0",
    capabilities: Server.Capabilities(
        prompts: .init(),
        completions: .init()
    )
)

await server.withRequestHandler(Complete.self) { params, _ in
    switch params.ref {
    case .prompt(let promptRef):
        if promptRef.name == "translate" {
            if params.argument.name == "from" || params.argument.name == "to" {
                let prefix = params.argument.value.lowercased()
                let languages = [
                    "english", "spanish", "french", "german",
                    "italian", "portuguese", "chinese", "japanese"
                ]
                let matches = languages.filter { $0.hasPrefix(prefix) }
                return Complete.Result(completion: .init(values: matches))
            }
        }

    case .resource(let resourceRef):
        // Handle resource template completions
        break
    }

    return Complete.Result(completion: .init(values: []))
}
```

## See Also

- <doc:server-prompts>
- <doc:server-resources>
- <doc:client-completions>
- ``Server``
