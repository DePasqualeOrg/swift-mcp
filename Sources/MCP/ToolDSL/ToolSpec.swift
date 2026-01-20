/// A tool that can be invoked via MCP.
///
/// Conformance is typically added by the `@Tool` macro, which generates:
/// - `toolDefinition`: The `Tool` definition including name, description, and JSON Schema
/// - `parse(from:)`: Parsing validated arguments into a typed instance
/// - `init()`: Required empty initializer
/// - `perform(context:)`: Bridging method (only if you write `perform()` without context)
///
/// ## Basic Usage
///
/// Most tools don't need access to `HandlerContext`. Just write `perform()` without parameters:
///
/// ```swift
/// @Tool
/// struct GetWeather {
///     static let name = "get_weather"
///     static let description = "Get weather for a city"
///
///     @Parameter(description: "City name")
///     var city: String
///
///     func perform() async throws -> String {
///         let weather = await fetchWeather(city: city)
///         return "Weather in \(city): \(weather)"
///     }
/// }
/// ```
///
/// ## Using HandlerContext
///
/// If your tool needs to report progress, log messages, or access request metadata,
/// include the `context` parameter:
///
/// ```swift
/// @Tool
/// struct CreateCalendarEvent {
///     static let name = "create_calendar_event"
///     static let description = "Create a new calendar event"
///
///     @Parameter(description: "The title of the event")
///     var title: String
///
///     @Parameter(key: "start_date", description: "Start date/time in ISO 8601 format")
///     var startDate: Date
///
///     func perform(context: HandlerContext) async throws -> String {
///         try await context.reportProgress(progress: 0.5, total: 1.0)
///         let event = try await CalendarEvents.createEvent(title: title, startDate: startDate)
///         return "Created event: \(event.id)"
///     }
/// }
/// ```
public protocol ToolSpec: Sendable {
    /// The result type returned by `perform(context:)`.
    associatedtype Output: ToolOutput

    /// The Tool definition including name, description, and JSON Schema.
    static var toolDefinition: Tool { get }

    /// Annotations describing tool behavior (read-only, idempotent, etc.).
    /// Default is empty array (MCP implicit defaults apply).
    static var annotations: [AnnotationOption] { get }

    /// Parse validated arguments into a typed instance.
    /// Called after JSON Schema validation has passed.
    /// - Parameter arguments: The validated arguments dictionary.
    /// - Returns: A configured instance of this tool.
    /// - Throws: `MCPError.internalError` if parsing fails (indicates a validation bug).
    static func parse(from arguments: [String: Value]?) throws -> Self

    /// Performs the tool's action with typed parameters.
    ///
    /// This method can throw errors for additional validation beyond JSON Schema constraints
    /// (e.g., semantic validation, business rules, or format checks like regex patterns).
    ///
    /// - Parameter context: Provides progress reporting, logging, and cancellation checking.
    /// - Returns: The tool's output, which will be converted to a `CallTool.Result`.
    /// - Throws: Any error to indicate tool failure. The error message is returned to the client.
    func perform(context: HandlerContext) async throws -> Output

    /// Required empty initializer for instance creation during parsing.
    /// Generated automatically by the `@Tool` macro.
    init()
}

public extension ToolSpec {
    /// Default: empty array (MCP implicit defaults apply).
    static var annotations: [AnnotationOption] { [] }
}

/// Macro that generates `ToolSpec` conformance for a struct.
///
/// The macro generates:
/// - `toolDefinition` with JSON Schema derived from `@Parameter` properties
/// - `parse(from:)` for converting validated arguments to typed properties
/// - `init()` empty initializer
/// - `perform(context:)` bridging method (only if you write `perform()` without context)
/// - `ToolSpec` protocol conformance
///
/// ## Basic Usage
///
/// Most tools don't need the `HandlerContext`. Just write `perform()` without parameters:
///
/// ```swift
/// @Tool
/// struct GetWeather {
///     static let name = "get_weather"
///     static let description = "Get weather for a city"
///
///     @Parameter(description: "City name")
///     var city: String
///
///     @Parameter(description: "Country code")
///     var country: String?
///
///     func perform() async throws -> String {
///         "Weather for \(city): 22C, sunny"
///     }
/// }
/// ```
///
/// ## Using HandlerContext
///
/// Include the `context` parameter when you need progress reporting, logging,
/// or request metadata:
///
/// ```swift
/// @Tool
/// struct LongRunningTask {
///     static let name = "long_task"
///     static let description = "A task that reports progress"
///
///     @Parameter(description: "Number of steps")
///     var steps: Int
///
///     func perform(context: HandlerContext) async throws -> String {
///         for i in 0..<steps {
///             try await context.reportProgress(progress: Double(i), total: Double(steps))
///             try await doWork()
///         }
///         return "Completed \(steps) steps"
///     }
/// }
/// ```
@attached(member, names: named(toolDefinition), named(parse), named(init), named(perform))
@attached(extension, conformances: ToolSpec, Sendable)
public macro Tool() = #externalMacro(module: "MCPMacros", type: "ToolMacro")
