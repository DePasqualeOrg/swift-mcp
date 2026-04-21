# Tools

Register tools that clients can discover and call.

## Overview

Tools are functions that your server exposes to clients. Each tool has a name, description, and input schema. Clients can [list](<doc:client-tools#Listing-Tools>) available tools and [call](<doc:client-tools#Calling-Tools>) them with arguments.

The Swift SDK provides two approaches:

- **`@Tool` macro**: Define tools as Swift types with automatic schema generation (recommended)
- **Closure-based**: Register tools dynamically at runtime

## Defining Tools

The `@Tool` macro generates JSON Schema from Swift types and handles argument parsing automatically. Import `MCPTool` to use the `@Tool` macro and `@Parameter` property wrapper:

```swift
import MCP
import MCPTool
```

Here's a complete tool definition:

```swift
@Tool
struct GetWeather {
    static let name = "get_weather"
    static let description = "Get current weather for a location"

    @Parameter(title: "Location", description: "City name")
    var location: String

    @Parameter(title: "Units", description: "Temperature units", default: "metric")
    var units: String

    func perform() async throws -> String {
        let weather = await fetchWeather(location: location, units: units)
        return "Weather in \(location): \(weather.temperature)° \(weather.conditions)"
    }
}
```

Most tools don't need the ``HandlerContext``, so you can write `perform()` without any parameters. If your tool needs progress reporting, logging, or request metadata, include the `context` parameter – see [Using HandlerContext](#Using-HandlerContext) below.

### Parameter Options

Use `@Parameter` to customize how arguments are parsed:

```swift
@Tool
struct Search {
    static let name = "search"
    static let description = "Search documents"

    @Parameter(title: "Query", description: "Search query")
    var query: String

    @Parameter(title: "Limit", description: "Maximum results", default: 10)
    var limit: Int

    @Parameter(title: "Include Archived", description: "Include archived", default: false)
    var includeArchived: Bool

    func perform() async throws -> String {
        // ...
    }
}
```

The `title` parameter provides a user-facing label for display in UIs. If omitted, the property name is used as the default.

> Note: Parameter titles are included in the tool's `inputSchema` as standard JSON Schema `title` properties. Client applications can use these for form labels, documentation, or other display purposes, but they're optional metadata – clients that don't look for them simply ignore them.

### Supported Parameter Types

Built-in parameter types include:

- **Basic types**: `String`, `Int`, `Double`, `Bool`
- **Date**: Parsed from ISO 8601 strings
- **Data**: Parsed from base64-encoded strings
- **Optional**: `T?` where T is any supported type
- **Array**: `[T]` where T is any supported type
- **Dictionary**: `[String: T]` where T is any supported type
- **Enums**: String-raw enums annotated with `@Schemable`, or richer enums with associated values
- **Custom types**: Any Swift type annotated with `@Schemable` (from `JSONSchemaBuilder`)

### Optional Parameters

Optional parameters don't require a default value:

```swift
@Parameter(description: "Filter by category")
var category: String?
```

### Validation Constraints

Add validation constraints for strings and numbers. When using ``MCPServer``, these constraints are automatically enforced at runtime – invalid arguments are rejected with an error before your tool's `perform` method is called:

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

For validation beyond these constraints – such as cross-field validation, pattern matching, or business logic – validate in your `perform` method and throw `MCPError.invalidParams` with a descriptive message.

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

Use `@Schemable` on a string-raw enum for automatic schema generation:

```swift
@Schemable
enum Priority: String, CaseIterable {
    case low, medium, high, urgent
}

@Schemable
enum OutputFormat: String, CaseIterable {
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
            "message": [
                "type": "string",
                "title": "Message",  // Optional: displayed in UIs
                "description": "Message to echo"
            ]
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
    // Proceed with deletion...
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

- `readOnlyHint: false` – tool may modify state
- `destructiveHint: true` – tool may destroy data
- `idempotentHint: false` – repeated calls may have different effects
- `openWorldHint: true` – tool interacts with external systems

## Returning Results

| Category | Return types |
| :--- | :--- |
| Value | `String`, `Int`, `Double`, `Bool`, `Date`, `[T]`, `T?`, `[String: V]`, `Void`, `@Schemable @StructuredOutput` struct |
| Image / audio | ``/MCPCore/Media``, ``/MCPCore/MediaWithMetadata`` |
| Asset (file / link) | ``/MCPCore/Asset``, ``/MCPCore/AssetWithMetadata`` |

Pick the category that matches what your tool produces. Each handles encoding automatically: value returns come with a published JSON schema and typed JSON output; media and asset returns emit content blocks the client renders directly; the `WithMetadata<T>` forms combine a media or asset block with typed JSON, so an agent can parse the result programmatically.

### Value

Most tools return a value. Declare the return type you want – an `Int`, a `String`, an array, a dictionary, or a typed struct – and the library encodes it for you in two forms: a text rendering for display and a typed JSON value matching a published schema.

**Primitives.** `Int`, `Double`, `Bool`, `String`, and `Date` all work directly:

```swift
func perform() async throws -> Int {
    42
}
```

The primitive set is deliberately narrow – no sized-int variants (`Int32`, `Int64`, `UInt`, …), `Float`, `Decimal`, or `URL`. Mapping Swift's richer numeric hierarchy onto JSON's two numeric types is a policy question better left to the author. If you need one of these, wrap the value in a `@StructuredOutput` struct whose Swift field type matches the intended JSON shape (`Int` for "JSON integer", `Double` for "JSON number").

**Arrays and optionals.** Nest them arbitrarily – `[Int]`, `[[String]]`, `Int?`, `[MyStruct]?`, and so on. A `nil` return encodes as JSON `null`, which agents can distinguish from a thrown error.

**Dictionaries.** `-> [String: V]` emits the map as a top-level JSON object:

```swift
func perform() async throws -> [String: Int] {
    ["alpha": 1, "beta": 2]
}
```

Only `String` keys are supported. Keys are emitted in sorted order, so the output is stable across invocations and platforms. An array *of* dictionaries (`[[String: Int]]`) works too.

**Void.** Action tools with no meaningful return value can omit the return clause:

```swift
@Tool
struct Ping {
    static let name = "ping"
    static let description = "Side-effect-only action"

    func perform() async throws {
        // ...
    }
}
```

The result encodes as JSON `null` – the same shape an `Optional<T>` returning `nil` produces – so agents don't have to special-case "tool ran, no value."

**`@Schemable @StructuredOutput` struct.** The most common case for tools returning structured data. Pair `@Schemable` (from JSONSchemaBuilder) with `@StructuredOutput` (from MCPCore):

```swift
import JSONSchemaBuilder

@Schemable
@StructuredOutput
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
        WeatherData(temperature: 22.5, conditions: "Partly cloudy", humidity: 65)
    }
}
```

`@Schemable` derives the JSON schema from the struct's fields. `@StructuredOutput` generates an encoder that emits every declared property explicitly – `nil` optionals become JSON `null` rather than being dropped, so consumers can rely on a stable shape. The server validates every tool result against the schema before sending it, catching output bugs early. See ``/MCPCore/StructuredOutput`` for the full contract.

### Media

Image or audio a multimodal model should see or hear directly.

```swift
func perform() async throws -> Media {
    let pngData = try await captureScreen()
    return Media(.image(data: pngData, mimeType: "image/png"))
}
```

Pass an array for multiple blocks: `Media([.image(...), .audio(...)])`. Blocks carry raw `Data`; the library handles base64 encoding.

### MediaWithMetadata<T>

Image or audio plus typed JSON metadata – for tools where an agent wants to reason about the result programmatically. For example, a screenshot tool that returns the image alongside its dimensions and file path:

```swift
@Schemable
@StructuredOutput
struct ScreenshotMetadata: Sendable {
    let width: Int
    let height: Int
    let displayID: Int
    let filePath: String?
}

@Tool
struct TakeScreenshot {
    static let name = "take_screenshot"
    static let description = "Capture the screen"

    func perform() async throws -> MediaWithMetadata<ScreenshotMetadata> {
        let (pngData, metadata) = try await captureScreen()
        return MediaWithMetadata(
            .image(data: pngData, mimeType: "image/png"),
            metadata: metadata,
        )
    }
}
```

Pass an array for multiple blocks: `MediaWithMetadata([.image(...), .image(...)], metadata: m)`.

The library publishes a schema derived from the metadata struct, so an agent can decode the typed fields directly; the media blocks are emitted alongside, so UIs still render the image or audio inline.

### Asset

A generated file (PDF, ZIP, video, …) or a URL reference to one.

```swift
func perform() async throws -> Asset {
    let pdfData = try await renderReport()
    return Asset(
        .binary(
            pdfData,
            uri: "file:///tmp/report.pdf",
            mimeType: "application/pdf",
        )
    )
}
```

Pass an array for multiple blocks: `Asset([.binary(...), .link(...)])`.

Three block cases:

- `.binary`: inline bytes with a URI the client tracks as a resource. Pass raw `Data`.
- `.text`: inline generated text (markdown, CSV, code) with a URI – distinct from `String`, which has no URI.
- `.link`: a URL the client fetches lazily. Optional fields mirror `ResourceLink` (size, title, icons).

Filesystem paths (`/tmp/report.pdf`) are not valid URIs – prefix with `file://`.

### AssetWithMetadata<T>

An asset plus typed JSON metadata, mirroring `MediaWithMetadata<T>`.

```swift
@Schemable
@StructuredOutput
struct PDFInfo: Sendable {
    let uri: String
    let pageCount: Int
    let tableOfContents: [String]
}

@Tool
struct GeneratePDF {
    static let name = "generate_pdf"
    static let description = "Render a report as PDF"

    func perform() async throws -> AssetWithMetadata<PDFInfo> {
        let (pdfData, info) = try await renderReport()
        return AssetWithMetadata(
            .binary(pdfData, uri: info.uri, mimeType: "application/pdf"),
            metadata: info,
        )
    }
}
```

Pass an array for multiple blocks: `AssetWithMetadata([.binary(...), .link(...)], metadata: m)`.

Include the asset's URI as a field on the metadata struct, so an agent reading the typed JSON can reference the asset directly without having to inspect the attached blocks.

### When to use the `WithMetadata<T>` pair

Pick `Media` or `Asset` when the output is purely for display or ingestion – a multimodal model looking at an image, a user clicking a link, a client previewing a generated file.

Pick `MediaWithMetadata<T>` or `AssetWithMetadata<T>` when an agent also needs to work with the result in code – extracting fields, chaining it into another tool call, matching against types. The typed metadata is published alongside a schema the agent can decode against.

When in doubt, prefer the schema-bearing form. Value returns don't have this split because a value is always typed.

### Choosing between Media and Asset for image / audio bytes

Same bytes, different intent:

- `Media` → hand the bytes directly to a multimodal model that will ingest them.
- `Asset` with `.binary` (or `.link`) → hand a *reference* to an agent that will forward the file or decide what to do with it.

A TTS tool feeding a voice-capable chat UI wants `Media`. A podcast-download tool feeding an agent that orchestrates transcription wants `Asset`.

### Escape hatches

Two escape hatches for cases the built-in return types don't handle.

**`@ManualEncoding`** opts out of the synthesized `encode(to:)` when you need to emit something the macro can't produce – for example, an additive computed field alongside the declared properties:

```swift
@Schemable
@StructuredOutput
@ManualEncoding
struct RepositoryInfo: Sendable {
    let owner: String
    let name: String
    let description: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(owner, forKey: .owner)
        try container.encode(name, forKey: .name)
        // Stable-shape contract: every declared optional emits as
        // explicit `null`. Use `encode`, not `encodeIfPresent`.
        try container.encode(description, forKey: .description)
        // Additive computed field. The output validator accepts keys
        // beyond those declared in the schema.
        try container.encode("\(owner)/\(name)", forKey: .fullPath)
    }

    enum CodingKeys: String, CodingKey {
        case owner, name, description, fullPath
    }
}
```

Whatever the hand-rolled encoder emits is still validated against the schema `@Schemable` generates from the Swift struct. Safe divergences are narrow: byte-level reformatting within a declared type, or adding extra keys not declared on the schema. Changing a declared property's wire type (emitting a number where the schema declares a string, for example Unix seconds for a `Date` field) fails validation – to emit Unix seconds, declare the Swift field as `Int` instead. To rename a key, add a `CodingKeys` enum; `@Schemable` honors it for the schema too.

**Custom return types** cover the rare case where none of the built-in categories fits – for example, a tool that genuinely needs image and PDF in one result. Conform a custom type to ``/MCPCore/ToolOutput`` and build the `CallTool.Result` by hand:

```swift
struct MixedMediaReport: ToolOutput, Sendable {
    let summary: String
    let chartPNG: Data
    let pdfData: Data
    let pdfURI: String

    func toCallToolResult() throws -> CallTool.Result {
        CallTool.Result(content: [
            .text(summary),
            .image(data: chartPNG.base64EncodedString(), mimeType: "image/png"),
            .resource(uri: pdfURI, mimeType: "application/pdf", blob: pdfData),
        ])
    }
}
```

Use this only after the built-in return types have been ruled out – constructing `CallTool.Result` bypasses the typed-return surface on purpose.

## Error Handling

Errors during tool execution are returned with `isError: true`, providing actionable feedback that language models can use to self-correct and retry. Throw errors from your `perform` method; the SDK catches and surfaces them.

### Simple errors

For simple error messages, throw from `perform`:

```swift
func perform() async throws -> String {
    guard isValidDate(date) else {
        throw MCPError.invalidParams("Invalid date: must be in the future")
    }
    return "Event created"
}
```

Any `Error` works. Errors conforming to `LocalizedError` surface their `errorDescription` as a single `.text` block:

```swift
enum MyToolError: LocalizedError {
    case invalidDate(String)
    case resourceNotFound(String)

    var errorDescription: String? {
        switch self {
            case .invalidDate(let date):
                return "Invalid date '\(date)': must be in the future"
            case .resourceNotFound(let path):
                return "Resource not found: \(path)"
        }
    }
}

// In your tool:
throw MyToolError.invalidDate(date)
```

Plain errors (not `LocalizedError` conformers) fall back to `String(describing:)`, which produces output like `invalidDate("2020-01-01")`. Prefer `LocalizedError` for user-facing messages.

### Rich errors with ToolError

For errors that need multiple content blocks – a text explanation plus an image of the failing chart, a diagnostic plus a resource link, etc. – conform to ``/MCPCore/ToolError``:

```swift
struct RenderFailure: ToolError {
    let message: String
    let failingChart: Data

    var content: [ContentBlock] {
        [
            .text(message),
            .image(data: failingChart.base64EncodedString(), mimeType: "image/png"),
        ]
    }
}

// In your tool:
throw RenderFailure(message: "Render failed at step 3", failingChart: chartBytes)
```

`ToolError` refines `LocalizedError`, so `Error.localizedDescription` bridging still works: the default `errorDescription` joins the `.text` blocks. Thrown `ToolError` conformers pass `content` through verbatim with `isError: true`.

### Protocol errors

Protocol-level errors (unknown tool, disabled tool, malformed request) are handled automatically by the SDK before your tool executes. You don't need to handle these cases in your `perform` method.

## Notifying Tool Changes

``MCPServer`` automatically broadcasts list-changed notifications to all connected sessions when tools are registered, enabled, disabled, or removed. For single-session servers (stdio), this notifies the connected client. For HTTP servers with multiple sessions, all active sessions receive the notification concurrently. Sessions that have disconnected are automatically cleaned up during broadcast.

You can also send a notification manually from a specific session's handler context:

```swift
try await context.sendToolListChanged()
```

## Concurrent Execution

When multiple tool calls arrive concurrently (e.g., from a client using a task group), they execute in parallel. The tool registry resolves each tool on its serial executor, then dispatches execution to the global concurrent executor. This means long-running tools don't block other tool calls.

## Tool Naming

Tool names should follow these conventions:

- Between 1 and 128 characters
- Case-sensitive
- Use only: letters (A-Z, a-z), digits (0-9), underscore (\_), hyphen (-), and dot (.)
- Unique within your server

Examples: `getUser`, `DATA_EXPORT_v2`, `admin.tools.list`

## Low-Level API

For advanced use cases like custom request handling or mixing with other handlers, see <doc:server-advanced> for the manual `withRequestHandler` approach.

## See Also

- <doc:server-setup>
- <doc:client-tools>
- ``MCPServer``
- ``/MCPCore/Tool``
- ``ToolSpec``
- ``/MCPCore/StructuredOutput``
- ``/MCPCore/Media``
- ``/MCPCore/MediaWithMetadata``
- ``/MCPCore/Asset``
- ``/MCPCore/AssetWithMetadata``
- ``/MCPCore/ToolError``
- ``/MCPCore/ToolOutput``
