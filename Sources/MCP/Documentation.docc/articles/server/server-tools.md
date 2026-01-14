# Tools

Register tools that clients can discover and call.

## Overview

Tools are functions that your server exposes to clients. Each tool has a name, description, and input schema. Clients can list available tools and call them with arguments.

The Swift SDK provides two approaches:
- **`@Tool` macro**: Define tools as Swift types with automatic schema generation (recommended)
- **Closure-based**: Register tools dynamically at runtime

## Tool Naming

Tool names should follow these conventions:
- Between 1 and 128 characters
- Case-sensitive
- Use only: letters (A-Z, a-z), digits (0-9), underscore (_), hyphen (-), and dot (.)
- Unique within your server

Examples: `getUser`, `DATA_EXPORT_v2`, `admin.tools.list`

## Defining Tools

The `@Tool` macro generates JSON Schema from Swift types and handles argument parsing automatically:

```swift
@Tool
struct GetWeather {
    static let name = "get_weather"
    static let description = "Get current weather for a location"

    @Parameter(description: "City name")
    var location: String

    @Parameter(description: "Temperature units", default: "metric")
    var units: String

    func perform() async throws -> String {
        let weather = await fetchWeather(location: location, units: units)
        return "Weather in \(location): \(weather.temperature)° \(weather.conditions)"
    }
}
```

Most tools don't need the `HandlerContext`, so you can write `perform()` without any parameters. If your tool needs progress reporting, logging, or request metadata, include the `context` parameter—see [Using HandlerContext](#Using-HandlerContext) below.

### Parameter Options

Use `@Parameter` to customize how arguments are parsed:

```swift
@Tool
struct Search {
    static let name = "search"
    static let description = "Search documents"

    @Parameter(description: "Search query")
    var query: String

    @Parameter(description: "Maximum results", default: 10)
    var limit: Int

    @Parameter(description: "Include archived", default: false)
    var includeArchived: Bool

    func perform() async throws -> String {
        // ...
    }
}
```

### Supported Parameter Types

Built-in parameter types include:

- **Basic types**: `String`, `Int`, `Double`, `Bool`
- **Date**: Parsed from ISO 8601 strings
- **Data**: Parsed from base64-encoded strings
- **Optional**: `T?` where T is any supported type
- **Array**: `[T]` where T is any supported type
- **Dictionary**: `[String: T]` where T is any supported type
- **Enums**: String enums conforming to ``ToolEnum``

### Optional Parameters

Optional parameters don't require a default value:

```swift
@Parameter(description: "Filter by category")
var category: String?
```

### Validation Constraints

Add validation constraints for strings and numbers. When using ``MCPServer``, these constraints are automatically enforced at runtime—invalid arguments are rejected with an error before your tool's `perform` method is called:

```swift
@Tool
struct CreateEvent {
    static let name = "create_event"
    static let description = "Create a calendar event"

    // String length constraints
    @Parameter(description: "Event title", minLength: 1, maxLength: 200)
    var title: String

    // Numeric range constraints
    @Parameter(description: "Duration in minutes", minimum: 15, maximum: 480)
    var duration: Int

    // Combine with default values
    @Parameter(description: "Priority (1-5)", minimum: 1, maximum: 5, default: 3)
    var priority: Int

    func perform() async throws -> String {
        // ...
    }
}
```

For validation beyond these constraints—such as cross-field validation, pattern matching, or business logic—validate in your `perform` method and throw `MCPError.invalidParams` with a descriptive message.

### Custom JSON Keys

Use `key` to specify a different name in the JSON schema:

```swift
@Tool
struct CreateUser {
    static let name = "create_user"
    static let description = "Create a new user"

    // Maps to "first_name" in JSON, but uses Swift naming in code
    @Parameter(key: "first_name", description: "User's first name")
    var firstName: String

    @Parameter(key: "last_name", description: "User's last name")
    var lastName: String

    func perform() async throws -> String {
        "Created user: \(firstName) \(lastName)"
    }
}
```

### Date Parameters

Dates are parsed from ISO 8601 format strings:

```swift
@Tool
struct ScheduleMeeting {
    static let name = "schedule_meeting"
    static let description = "Schedule a meeting"

    @Parameter(description: "Meeting start time (ISO 8601)")
    var startTime: Date

    @Parameter(description: "Meeting end time (ISO 8601)")
    var endTime: Date?

    func perform() async throws -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting scheduled for \(formatter.string(from: startTime))"
    }
}
```

### Array Parameters

Use arrays for parameters that accept multiple values:

```swift
@Tool
struct SendNotifications {
    static let name = "send_notifications"
    static let description = "Send notifications to users"

    @Parameter(description: "User IDs to notify")
    var userIds: [String]

    @Parameter(description: "Priority levels", default: [1, 2, 3])
    var priorities: [Int]

    func perform() async throws -> String {
        "Sent notifications to \(userIds.count) users"
    }
}
```

### Enum Parameters

Use ``ToolEnum`` for string enums with automatic schema generation:

```swift
// ToolEnum requires RawRepresentable with String and CaseIterable
// Swift auto-synthesizes both for simple enums
enum Priority: String, ToolEnum {
    case low, medium, high, urgent
}

enum OutputFormat: String, ToolEnum {
    case json, xml, csv, yaml
}

@Tool
struct ExportData {
    static let name = "export_data"
    static let description = "Export data in the specified format"

    @Parameter(description: "Data to export")
    var data: String

    @Parameter(description: "Output format")
    var format: OutputFormat

    @Parameter(description: "Priority level")
    var priority: Priority?

    func perform() async throws -> String {
        "Exported data as \(format.rawValue)"
    }
}
```

The generated JSON Schema includes an `enum` constraint with all valid values.

### Dictionary Parameters

Use dictionaries for flexible key-value data:

```swift
@Tool
struct SetMetadata {
    static let name = "set_metadata"
    static let description = "Set metadata key-value pairs"

    @Parameter(description: "Resource ID")
    var resourceId: String

    @Parameter(description: "Metadata to set")
    var metadata: [String: String]

    @Parameter(description: "Numeric settings")
    var settings: [String: Int]?

    func perform() async throws -> String {
        "Set \(metadata.count) metadata entries on \(resourceId)"
    }
}
```

## Registering Tools

Use ``MCPServer`` to register tools:

```swift
let server = MCPServer(name: "MyServer", version: "1.0.0")

// Register multiple tools with result builder
try await server.register {
    GetWeather.self
    Search.self
}

// Or register individually
try await server.register(GetWeather.self)
```

## Dynamic Tool Registration

For tools defined at runtime (from configuration, database, etc.), use closure-based registration:

```swift
let tool = try await server.register(
    name: "echo",
    description: "Echo the input message",
    inputSchema: [
        "type": "object",
        "properties": [
            "message": ["type": "string", "description": "Message to echo"]
        ],
        "required": ["message"]
    ]
) { (args: EchoArgs, context: HandlerContext) in
    "Echo: \(args.message)"
}
```

For tools with no input:

```swift
let tool = try await server.register(
    name: "get_time",
    description: "Get current server time"
) { (context: HandlerContext) in
    ISO8601DateFormatter().string(from: Date())
}
```

## Tool Lifecycle

Registered tools return a handle for lifecycle management:

```swift
let tool = try await server.register(GetWeather.self)

// Temporarily hide from clients
await tool.disable()

// Make available again
await tool.enable()

// Permanently remove
await tool.remove()
```

Disabled tools don't appear in `listTools` responses and reject execution attempts.

## Using HandlerContext

Include the `context` parameter when your tool needs capabilities like progress reporting, cancellation, or user interaction:

```swift
// Report progress for long-running operations
func perform(context: HandlerContext) async throws -> String {
    for i in 0..<items.count {
        try await context.reportProgress(Double(i), total: Double(items.count))
        process(items[i])
    }
    return "Done"
}

// Check for cancellation
func perform(context: HandlerContext) async throws -> String {
    for item in items {
        try context.checkCancellation()
        process(item)
    }
    return "Done"
}

// Request user confirmation before destructive actions
func perform(context: HandlerContext) async throws -> String {
    let schema = ElicitationSchema(
        properties: ["confirm": .boolean(description: "Delete these files?")],
        required: ["confirm"]
    )
    let result = try await context.elicit(message: "Confirm deletion", requestedSchema: schema)
    guard result.action == .accept else {
        return "Cancelled"
    }
    // proceed with deletion...
}

// Request LLM completion during tool execution
func perform(context: HandlerContext) async throws -> String {
    let result = try await context.createMessage(
        messages: [.init(role: .user, content: .text("Summarize: \(data)"))],
        maxTokens: 200
    )
    return "Summary: \(result.content)"
}
```

## Tool Annotations

Provide hints about tool behavior to help clients make decisions:

```swift
@Tool
struct DeleteFile {
    static let name = "delete_file"
    static let description = "Delete a file permanently"
    static let annotations: [AnnotationOption] = [
        .title("Delete File"),
        .idempotent
    ]
    // Note: destructive is the implicit MCP default when .readOnly is not set

    @Parameter(description: "Path to delete")
    var path: String

    func perform() async throws -> String {
        // ...
    }
}
```

Or for dynamic tools:

```swift
try await server.register(
    name: "delete_file",
    description: "Delete a file",
    inputSchema: [...],
    annotations: [.title("Delete File"), .idempotent]
) { (args: DeleteArgs, context: HandlerContext) in
    // ...
}
```

### Available Annotations

- **`.title(String)`**: Human-readable name for UI display
- **`.readOnly`**: Tool only reads data (implies non-destructive and idempotent)
- **`.idempotent`**: Calling multiple times has same effect as once
- **`.closedWorld`**: Tool does not interact with external systems

When the annotations array is empty (the default), MCP implicit defaults apply:
- `readOnlyHint: false` — tool may modify state
- `destructiveHint: true` — tool may destroy data
- `idempotentHint: false` — repeated calls may have different effects
- `openWorldHint: true` — tool interacts with external systems

## Response Content Types

Tool results support multiple content types. Return a `String` for simple text, or use ``ToolOutput`` conforming types for rich content.

### Text

```swift
func perform() async throws -> String {
    "Hello, world!"
}
```

### Multiple Content Items

Return `CallTool.Result` for complex responses:

```swift
func perform() async throws -> CallTool.Result {
    CallTool.Result(content: [
        .text("Here's the chart:"),
        .image(data: chartData, mimeType: "image/png")
    ])
}
```

### Images and Audio

```swift
// Image
CallTool.Result(content: [.image(data: base64Data, mimeType: "image/png")])

// Audio
CallTool.Result(content: [.audio(data: base64Data, mimeType: "audio/mp3")])
```

## Error Handling

Errors during tool execution are returned with `isError: true`, providing actionable feedback that language models can use to self-correct and retry.

### Simple Errors

For simple error messages, just throw from your `perform` method:

```swift
func perform() async throws -> String {
    guard isValidDate(date) else {
        throw MCPError.invalidParams("Invalid date: must be in the future")
    }
    return "Event created"
}
```

Thrown errors are caught and returned as `CallTool.Result(content: [.text(errorMessage)], isError: true)`.

### Custom Error Content

When you need richer error responses (multiple content items, images, specific formatting), return `CallTool.Result` explicitly:

```swift
func perform() async throws -> CallTool.Result {
    guard isValidDate(date) else {
        return CallTool.Result(
            content: [
                .text("Invalid date: must be in the future"),
                .text("Current time: \(ISO8601DateFormatter().string(from: Date()))")
            ],
            isError: true
        )
    }
    // ...
}
```

### Protocol Errors

Protocol-level errors (unknown tool, disabled tool, malformed request) are handled automatically by the SDK before your tool executes. You don't need to handle these cases in your `perform` method.

## Output Schema and Structured Content

For validated structured results, use `@OutputSchema` to generate a schema from a Swift type:

```swift
@OutputSchema
struct WeatherData: Sendable {
    let temperature: Double
    let conditions: String
    let humidity: Int?
}

@Tool
struct GetWeatherData {
    static let name = "get_weather_data"
    static let description = "Get weather data"

    @Parameter(description: "City name")
    var location: String

    func perform() async throws -> WeatherData {
        WeatherData(
            temperature: 22.5,
            conditions: "Partly cloudy",
            humidity: 65
        )
    }
}
```

Types conforming to `StructuredOutput` (via `@OutputSchema`) automatically:
- Include `outputSchema` in the tool definition
- Serialize to both human-readable text and structured JSON content

## Notifying Tool Changes

``MCPServer`` automatically sends list change notifications when tools are registered, enabled, disabled, or removed. You can also send manually:

```swift
await server.sendToolListChanged()
```

## Low-Level API

For advanced use cases like custom request handling or mixing with other handlers, see <doc:server-advanced> for the manual `withRequestHandler` approach.

## See Also

- <doc:server-setup>
- <doc:client-tools>
- ``MCPServer``
- ``Tool``
- ``ToolSpec``
- ``Parameter``
- ``ToolEnum``
