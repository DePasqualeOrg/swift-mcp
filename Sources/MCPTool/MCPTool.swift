// MCPTool - Macros and property wrappers for defining MCP tools.
//
// Import this module alongside MCP when you need to define tools:
//
//     import MCP
//     import MCPTool
//
//     @Tool
//     struct MyTool {
//         @Parameter(description: "Input value")
//         var input: String
//
//         func perform() async throws -> String { ... }
//     }
//
// This separation allows using MCP types alongside other frameworks (like AI)
// that have their own @Tool and @Parameter without naming collisions.
//
// For prompts, use MCPPrompt instead which provides @Prompt and @Argument.

import MCP

// MARK: - Parameter Property Wrapper

/// Property wrapper for MCP tool parameters.
///
/// The `@Parameter` property wrapper marks a property as a tool parameter and provides
/// metadata for JSON Schema generation. The `@Tool` macro inspects these properties
/// to generate the tool's `inputSchema`.
///
/// Example:
/// ```swift
/// @Tool
/// struct CreateEvent {
///     static let name = "create_event"
///     static let description = "Create a calendar event"
///
///     // Required parameter (non-optional type)
///     @Parameter(description: "The title of the event", maxLength: 500)
///     var title: String
///
///     // Optional parameter
///     @Parameter(description: "Location of the event")
///     var location: String?
///
///     // Parameter with custom JSON key
///     @Parameter(key: "start_date", description: "Start date in ISO 8601 format")
///     var startDate: Date
///
///     // Parameter with default value (not required in schema)
///     @Parameter(description: "Max events to return", minimum: 1, maximum: 100)
///     var limit: Int = 25
/// }
/// ```
@propertyWrapper
public struct Parameter<Value: ParameterValue>: Sendable {
    public var wrappedValue: Value

    /// The JSON key used in the schema and argument parsing.
    /// If nil, the Swift property name is used.
    public let key: String?

    /// A user-facing title for display in UIs.
    /// If nil, defaults to the property name.
    public let title: String?

    /// A description of the parameter for the JSON Schema.
    public let description: String?

    // MARK: - Validation Constraints

    /// Minimum length for string parameters.
    public let minLength: Int?

    /// Maximum length for string parameters.
    public let maxLength: Int?

    /// Minimum value for numeric parameters.
    public let minimum: Double?

    /// Maximum value for numeric parameters.
    public let maximum: Double?

    /// Creates a parameter with the specified metadata and constraints.
    ///
    /// - Parameters:
    ///   - wrappedValue: The default value for this parameter.
    ///   - key: The JSON key (defaults to property name).
    ///   - title: A user-facing title for display in UIs.
    ///   - description: A description of the parameter.
    ///   - minLength: Minimum string length.
    ///   - maxLength: Maximum string length.
    ///   - minimum: Minimum numeric value.
    ///   - maximum: Maximum numeric value.
    public init(
        wrappedValue: Value,
        key: String? = nil,
        title: String? = nil,
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.wrappedValue = wrappedValue
        self.key = key
        self.title = title
        self.description = description
        self.minLength = minLength
        self.maxLength = maxLength
        self.minimum = minimum
        self.maximum = maximum
    }
}

public extension Parameter where Value: ExpressibleByNilLiteral {
    /// Creates an optional parameter with the specified metadata and constraints.
    init(
        key: String? = nil,
        title: String? = nil,
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        wrappedValue = nil
        self.key = key
        self.title = title
        self.description = description
        self.minLength = minLength
        self.maxLength = maxLength
        self.minimum = minimum
        self.maximum = maximum
    }
}

public extension Parameter {
    /// Creates a required parameter with the specified metadata and constraints.
    init(
        key: String? = nil,
        title: String? = nil,
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        wrappedValue = Value.placeholderValue
        self.key = key
        self.title = title
        self.description = description
        self.minLength = minLength
        self.maxLength = maxLength
        self.minimum = minimum
        self.maximum = maximum
    }
}

// MARK: - Tool Macro

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
///         "Weather for \(city): 22C, sunny"
///     }
/// }
/// ```
@attached(member, names: named(toolDefinition), named(parse), named(init), named(perform))
@attached(extension, conformances: ToolSpec, Sendable)
public macro Tool() = #externalMacro(module: "MCPMacros", type: "ToolMacro")

// MARK: - OutputSchema Macro

/// Macro that generates a JSON Schema for a tool's output type.
@attached(member, names: named(outputSchema))
@attached(extension, conformances: ToolOutput)
public macro OutputSchema() = #externalMacro(module: "MCPMacros", type: "OutputSchemaMacro")
