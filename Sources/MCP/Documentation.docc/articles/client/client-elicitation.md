# Elicitation

Collect user input requested by MCP servers

## Overview

Elicitation enables servers to request information from users through the client. This supports interactive workflows where a server needs user input during an operation, such as confirming an action, providing credentials, or making choices.

There are two modes of elicitation:
- **Form mode**: Display a form with fields defined by a schema
- **URL mode**: Direct the user to an external URL (e.g., OAuth flow)

## Declaring Elicitation Capability

Before handling elicitation requests, declare the capability when setting up your client:

```swift
let client = Client(name: "MyApp", version: "1.0.0")

await client.setCapabilities(Client.Capabilities(
    elicitation: .init(
        form: .init(applyDefaults: true),  // Support form mode
        url: .init()                        // Support URL mode
    )
))
```

## Registering an Elicitation Handler

Use ``Client/withElicitationHandler(_:)`` to register a handler:

```swift
client.withElicitationHandler { params, context in
    switch params {
    case .form(let formParams):
        return try await handleFormElicitation(formParams)
    case .url(let urlParams):
        return try await handleURLElicitation(urlParams)
    }
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

In URL mode, direct the user to complete an external flow:

```swift
func handleURLElicitation(_ params: ElicitRequestURLParams) async throws -> ElicitResult {
    // params.message - Why the user needs to visit the URL
    // params.url - The URL to open
    // params.elicitationId - ID to track this elicitation

    // Open the URL in a browser
    await openURL(URL(string: params.url)!)

    // Wait for the server to notify completion
    // The server sends ElicitationCompleteNotification when done

    return ElicitResult(action: .accept)
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
