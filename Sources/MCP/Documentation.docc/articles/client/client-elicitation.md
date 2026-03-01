# Elicitation

Collect user input requested by MCP servers

## Overview

Elicitation enables servers to request information from users through the client. This supports interactive workflows where a server needs user input during an operation, such as confirming an action, providing credentials, or making choices.

There are two modes of elicitation:
- **Form mode**: Display a form with fields defined by a schema
- **URL mode**: Direct the user to an external URL (e.g., OAuth flow)

## Registering an Elicitation Handler

Use ``Client/withElicitationHandler(formMode:urlMode:handler:)`` to register a handler. The elicitation capability is automatically advertised when you register a handler:

```swift
let client = Client(name: "MyApp", version: "1.0.0")

// Enable both form and URL modes
await client.withElicitationHandler(
    formMode: .enabled(applyDefaults: true),  // Support form mode with defaults
    urlMode: .enabled                         // Support URL mode
) { params, context in
    switch params {
        case .form(let formParams):
            return try await handleFormElicitation(formParams)
        case .url(let urlParams):
            return try await handleURLElicitation(urlParams)
    }
}

try await client.connect(transport: transport)
```

> Important: Register handlers before calling `connect()`. Attempting to register handlers after connecting will result in an error.

### Mode Configuration

You can enable specific modes:

```swift
// Form mode only
await client.withElicitationHandler(formMode: .enabled(), urlMode: nil) { params, _ in
    // Only .form cases will be received
}

// URL mode only
await client.withElicitationHandler(formMode: nil, urlMode: .enabled) { params, _ in
    // Only .url cases will be received
}

// Both modes (default when using .enabled())
await client.withElicitationHandler(formMode: .enabled(), urlMode: .enabled) { params, _ in
    // Both .form and .url cases can be received
}
```

## Form Mode Elicitation

In form mode, the server provides a schema defining the fields to display:

```swift
func handleFormElicitation(_ params: ElicitRequestFormParams) async throws -> ElicitResult {
    // params.message - The message explaining what's needed
    // params.requestedSchema - The form schema

    // Display UI to the user based on the schema
    let userInput = try await showFormUI(
        message: params.message,
        schema: params.requestedSchema
    )

    // Return the result
    if let input = userInput {
        return ElicitResult(
            action: .accept,
            content: input
        )
    } else {
        return ElicitResult(action: .cancel)
    }
}
```

### Schema Field Types

The ``ElicitationSchema`` contains fields with various types:

```swift
for (fieldName, fieldSchema) in params.requestedSchema.properties {
    switch fieldSchema {
        case .string(let schema):
            // Text field with optional format (email, uri, date)
            print("String field: \(schema.title ?? fieldName)")
            if let format = schema.format {
                print("Format: \(format)")
            }
        case .number(let schema):
            // Numeric field (integer or decimal)
            print("Number field: \(schema.title ?? fieldName)")
        case .boolean(let schema):
            // Checkbox/toggle
            print("Boolean field: \(schema.title ?? fieldName)")
        case .untitledEnum(let schema):
            // Single-select dropdown
            print("Choices: \(schema.enumValues)")
        case .titledEnum(let schema):
            // Single-select with display labels
            for option in schema.oneOf {
                print("\(option.title): \(option.const)")
            }
        case .untitledMultiSelect(let schema):
            // Multi-select list
            print("Multi-select: \(schema.items.enumValues)")
        case .titledMultiSelect(let schema):
            // Multi-select with display labels
            for option in schema.items.anyOf {
                print("\(option.title): \(option.const)")
            }
        case .legacyTitledEnum(let schema):
            // Legacy format with enumNames
            print("Choices: \(schema.enumValues)")
    }
}
```

### Returning Form Data

Return the collected data matching the schema field types:

```swift
return ElicitResult(
    action: .accept,
    content: [
        "name": .string("John Doe"),
        "age": .int(30),
        "price": .double(19.99),
        "agree": .bool(true),
        "colors": .strings(["red", "blue"])
    ]
)
```

## URL Mode Elicitation

In URL mode, direct the user to complete an external flow. URL mode is used for sensitive interactions like OAuth flows and credential entry that should not pass through the MCP client.

### Security Requirements

When handling URL elicitation:

- Do not automatically open URLs without user consent
- Show the full URL to the user before opening
- Open URLs in a secure browser context (e.g., `SFSafariViewController` on iOS, not `WKWebView`)
- Highlight the domain to help users identify the destination

```swift
func handleURLElicitation(_ params: ElicitRequestURLParams) async throws -> ElicitResult {
    // params.message - Why the user needs to visit the URL
    // params.url - The URL to open
    // params.elicitationId - ID to track this elicitation

    // Show URL to user and get consent before opening
    guard await getUserConsent(url: params.url, message: params.message) else {
        return ElicitResult(action: .decline)
    }

    // Open in a secure browser context
    await openURLSecurely(URL(string: params.url)!)

    // The server sends ElicitationCompleteNotification when done
    return ElicitResult(action: .accept)
}
```

## Elicitation Complete Notification

For URL mode elicitation, the server sends an ``ElicitationCompleteNotification`` when the external flow finishes. Register a notification handler to react to completion:

```swift
await client.onNotification(ElicitationCompleteNotification.self) { message in
    let elicitationId = message.params.elicitationId
    // Dismiss the browser or update UI to reflect completion
}
```

## User Actions

The ``ElicitResult`` action indicates how the user responded:

- `.accept`: User submitted the form or completed the flow
- `.decline`: User explicitly declined
- `.cancel`: User dismissed without making a choice

```swift
// User accepted
ElicitResult(action: .accept, content: ["field": .string("value")])

// User declined
ElicitResult(action: .decline)

// User cancelled
ElicitResult(action: .cancel)
```

## See Also

- <doc:client-setup>
- <doc:server-elicitation>
- ``Client``
