# Elicitation

Request user input from MCP clients

## Overview

Elicitation enables servers to request information from users through the client. This supports interactive workflows where your server needs user input, such as confirming actions, providing credentials, or making choices.

There are two modes:
- **Form mode**: Present a form with structured fields
- **URL mode**: Direct users to an external URL (e.g., OAuth)

## Form Elicitation

Request structured input using ``Server/RequestHandlerContext/elicit(message:requestedSchema:)``:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    // Request user input
    let result = try await context.elicit(
        message: "Please provide your information",
        requestedSchema: ElicitationSchema(properties: [
            "username": .string(StringSchema(title: "Username")),
            "email": .string(StringSchema(title: "Email", format: .email))
        ], required: ["username", "email"])
    )

    // Check the user's response
    guard result.action == .accept, let content = result.content else {
        return CallTool.Result(content: [.text("Operation cancelled")], isError: true)
    }

    // Use the provided values
    let username = content["username"]
    return CallTool.Result(content: [.text("Welcome, \(username)")])
}
```

## Schema Field Types

### String Fields

```swift
ElicitationSchema(properties: [
    "name": .string(StringSchema(title: "Full Name")),
    "email": .string(StringSchema(title: "Email", format: .email)),
    "website": .string(StringSchema(title: "Website", format: .uri)),
    "birthdate": .string(StringSchema(title: "Birth Date", format: .date)),
    "zipcode": .string(StringSchema(
        title: "ZIP Code",
        pattern: "^[0-9]{5}$",
        minLength: 5,
        maxLength: 5
    ))
])
```

### Number Fields

```swift
ElicitationSchema(properties: [
    "age": .number(NumberSchema(
        isInteger: true,
        title: "Age",
        minimum: 0,
        maximum: 150
    )),
    "price": .number(NumberSchema(
        title: "Price",
        minimum: 0
    ))
])
```

### Boolean Fields

```swift
ElicitationSchema(properties: [
    "agree": .boolean(BooleanSchema(
        title: "I agree to the terms",
        description: "You must accept the terms to continue",
        defaultValue: false
    ))
])
```

### Single-Select Enums

```swift
// Simple values
ElicitationSchema(properties: [
    "color": .untitledEnum(UntitledEnumSchema(
        title: "Favorite Color",
        enumValues: ["red", "green", "blue"]
    ))
])

// Values with display labels
ElicitationSchema(properties: [
    "priority": .titledEnum(TitledEnumSchema(
        title: "Priority",
        oneOf: [
            TitledEnumOption(const: "high", title: "High Priority"),
            TitledEnumOption(const: "medium", title: "Medium Priority"),
            TitledEnumOption(const: "low", title: "Low Priority")
        ]
    ))
])
```

### Multi-Select

```swift
ElicitationSchema(properties: [
    "features": .titledMultiSelect(TitledMultiSelectEnumSchema(
        title: "Features to enable",
        options: [
            TitledEnumOption(const: "logging", title: "Enable Logging"),
            TitledEnumOption(const: "metrics", title: "Enable Metrics"),
            TitledEnumOption(const: "tracing", title: "Enable Tracing")
        ],
        minItems: 1
    ))
])
```

## Required Fields

Specify which fields are required:

```swift
ElicitationSchema(
    properties: [
        "name": .string(StringSchema(title: "Name")),
        "email": .string(StringSchema(title: "Email")),
        "phone": .string(StringSchema(title: "Phone"))
    ],
    required: ["name", "email"]  // Phone is optional
)
```

## URL Elicitation

Direct users to an external URL for authentication or other flows:

```swift
try await context.elicitUrl(
    message: "Please authorize access to your account",
    url: "https://auth.example.com/authorize?client_id=...",
    elicitationId: UUID().uuidString
)
```

Use this for OAuth flows or any process that requires visiting an external website.

## Handling Responses

Check how the user responded:

```swift
let result = try await context.elicit(...)

switch result.action {
case .accept:
    // User submitted the form
    if let content = result.content {
        let name = content["name"]
        // Process the input
    }

case .decline:
    // User explicitly declined
    return CallTool.Result(content: [.text("Operation declined")], isError: true)

case .cancel:
    // User dismissed without making a choice
    return CallTool.Result(content: [.text("Operation cancelled")], isError: true)
}
```

## Extracting Values

Extract typed values from the response:

```swift
if let content = result.content {
    // String values
    if case .string(let name) = content["name"] {
        print("Name: \(name)")
    }

    // Integer values
    if case .int(let age) = content["age"] {
        print("Age: \(age)")
    }

    // Boolean values
    if case .bool(let agreed) = content["agree"] {
        print("Agreed: \(agreed)")
    }

    // Multi-select values
    if case .strings(let features) = content["features"] {
        print("Features: \(features)")
    }
}
```

## See Also

- <doc:server-setup>
- <doc:client-elicitation>
- ``Server``
- ``ElicitationSchema``
