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
    ///   - description: A description of the parameter.
    ///   - minLength: Minimum string length.
    ///   - maxLength: Maximum string length.
    ///   - minimum: Minimum numeric value.
    ///   - maximum: Maximum numeric value.
    public init(
        wrappedValue: Value,
        key: String? = nil,
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.wrappedValue = wrappedValue
        self.key = key
        self.description = description
        self.minLength = minLength
        self.maxLength = maxLength
        self.minimum = minimum
        self.maximum = maximum
    }
}

public extension Parameter where Value: ExpressibleByNilLiteral {
    /// Creates an optional parameter with the specified metadata and constraints.
    ///
    /// Use this initializer for optional parameters where no default value is needed.
    ///
    /// - Parameters:
    ///   - key: The JSON key (defaults to property name).
    ///   - description: A description of the parameter.
    ///   - minLength: Minimum string length.
    ///   - maxLength: Maximum string length.
    ///   - minimum: Minimum numeric value.
    ///   - maximum: Maximum numeric value.
    init(
        key: String? = nil,
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        wrappedValue = nil
        self.key = key
        self.description = description
        self.minLength = minLength
        self.maxLength = maxLength
        self.minimum = minimum
        self.maximum = maximum
    }
}

// MARK: - ParameterValue Protocol

/// Types that can be used as MCP tool parameters.
///
/// This protocol provides the information needed to:
/// 1. Generate JSON Schema for the parameter type
/// 2. Parse MCP `Value` into the Swift type
///
/// Built-in conformances include:
/// - `String`, `Int`, `Double`, `Bool` - Basic types
/// - `Date` - Parsed as ISO 8601 strings
/// - `Data` - Base64-encoded strings
/// - `Optional<T>` where T: ParameterValue
/// - `Array<T>` where T: ParameterValue
/// - `Dictionary<String, T>` where T: ParameterValue
///
/// ## Creating Custom Types
///
/// To use a custom type as a tool parameter, conform it to `ParameterValue`:
///
/// ```swift
/// struct Money: ParameterValue {
///     let amount: Double
///     let currency: String
///
///     static var jsonSchemaType: String { "object" }
///
///     static var jsonSchemaProperties: [String: Value] {
///         [
///             "properties": .object([
///                 "amount": .object(["type": .string("number")]),
///                 "currency": .object(["type": .string("string")])
///             ]),
///             "required": .array([.string("amount"), .string("currency")])
///         ]
///     }
///
///     static var placeholderValue: Money {
///         Money(amount: 0, currency: "USD")
///     }
///
///     init?(parameterValue value: Value) {
///         guard case .object(let obj) = value,
///               let amountVal = obj["amount"], case .double(let amount) = amountVal,
///               let currencyVal = obj["currency"], case .string(let currency) = currencyVal
///         else { return nil }
///         self.amount = amount
///         self.currency = currency
///     }
/// }
/// ```
///
/// For string enums, use the ``ToolEnum`` protocol instead, which provides
/// automatic conformance for `RawRepresentable` types with `String` raw values.
public protocol ParameterValue: Sendable {
    /// The JSON Schema type name (e.g., "string", "integer", "number", "boolean").
    static var jsonSchemaType: String { get }

    /// Additional schema properties (e.g., format, enum values, items).
    static var jsonSchemaProperties: [String: Value] { get }

    /// Parse from MCP Value.
    /// - Parameter value: The MCP Value to parse.
    /// - Returns: The parsed value, or nil if parsing fails.
    init?(parameterValue value: Value)

    /// A placeholder value used during tool initialization.
    /// This value is replaced during parsing from arguments.
    static var placeholderValue: Self { get }
}

public extension ParameterValue {
    /// Default: no additional properties.
    static var jsonSchemaProperties: [String: Value] { [:] }
}

public extension Parameter {
    /// Creates a required parameter with the specified metadata and constraints.
    ///
    /// Use this initializer for required parameters without a default value.
    /// The parameter's value will be set during parsing from tool arguments.
    ///
    /// - Parameters:
    ///   - key: The JSON key (defaults to property name).
    ///   - description: A description of the parameter.
    ///   - minLength: Minimum string length.
    ///   - maxLength: Maximum string length.
    ///   - minimum: Minimum numeric value.
    ///   - maximum: Maximum numeric value.
    init(
        key: String? = nil,
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        wrappedValue = Value.placeholderValue
        self.key = key
        self.description = description
        self.minLength = minLength
        self.maxLength = maxLength
        self.minimum = minimum
        self.maximum = maximum
    }
}

// MARK: - String Conformance

extension String: ParameterValue {
    public static var jsonSchemaType: String { "string" }
    public static var placeholderValue: String { "" }

    /// Parse a string from an MCP Value.
    /// Uses strict mode: only `.string` values are accepted.
    public init?(parameterValue value: Value) {
        self.init(value, strict: true)
    }
}

// MARK: - Int Conformance

extension Int: ParameterValue {
    public static var jsonSchemaType: String { "integer" }
    public static var placeholderValue: Int { 0 }

    /// Parse an integer from an MCP Value.
    /// Uses strict mode: only `.int` values are accepted.
    public init?(parameterValue value: Value) {
        self.init(value, strict: true)
    }
}

// MARK: - Double Conformance

extension Double: ParameterValue {
    public static var jsonSchemaType: String { "number" }
    public static var placeholderValue: Double { 0 }

    /// Parse a double from an MCP Value.
    /// Uses strict mode: only `.double` and `.int` values are accepted.
    public init?(parameterValue value: Value) {
        self.init(value, strict: true)
    }
}

// MARK: - Bool Conformance

extension Bool: ParameterValue {
    public static var jsonSchemaType: String { "boolean" }
    public static var placeholderValue: Bool { false }

    /// Parse a boolean from an MCP Value.
    /// Uses strict mode: only `.bool` values are accepted.
    public init?(parameterValue value: Value) {
        self.init(value, strict: true)
    }
}

// MARK: - Date Conformance

import Foundation

extension Date: ParameterValue {
    public static var jsonSchemaType: String { "string" }
    public static var placeholderValue: Date { Date(timeIntervalSince1970: 0) }

    public static var jsonSchemaProperties: [String: Value] {
        ["format": .string("date-time")]
    }

    /// Parse a Date from an MCP Value containing an ISO 8601 string.
    public init?(parameterValue value: Value) {
        guard case let .string(str) = value else { return nil }

        // Try ISO 8601 with fractional seconds first
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) {
            self = date
            return
        }

        // Fall back to without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: str) {
            self = date
            return
        }

        return nil
    }
}

// MARK: - Data Conformance

extension Data: ParameterValue {
    public static var jsonSchemaType: String { "string" }
    public static var placeholderValue: Data { Data() }

    public static var jsonSchemaProperties: [String: Value] {
        ["contentEncoding": .string("base64")]
    }

    /// Parse Data from an MCP Value containing a base64-encoded string.
    public init?(parameterValue value: Value) {
        guard case let .string(str) = value,
              let data = Data(base64Encoded: str)
        else {
            return nil
        }
        self = data
    }
}

// MARK: - Optional Conformance

extension Optional: ParameterValue where Wrapped: ParameterValue {
    public static var jsonSchemaType: String { Wrapped.jsonSchemaType }
    public static var placeholderValue: Wrapped? { nil }

    public static var jsonSchemaProperties: [String: Value] { Wrapped.jsonSchemaProperties }

    /// Parse an optional value from an MCP Value.
    /// Returns nil (success with nil value) for Value.null, otherwise delegates to wrapped type.
    public init?(parameterValue value: Value) {
        if case .null = value {
            self = .none
            return
        }
        if let wrapped = Wrapped(parameterValue: value) {
            self = .some(wrapped)
        } else {
            return nil
        }
    }
}

// MARK: - Array Conformance

extension Array: ParameterValue where Element: ParameterValue {
    public static var jsonSchemaType: String { "array" }
    public static var placeholderValue: [Element] { [] }

    public static var jsonSchemaProperties: [String: Value] {
        var props: [String: Value] = [
            "items": .object([
                "type": .string(Element.jsonSchemaType),
            ]),
        ]
        // Merge element's additional properties into items
        let elementProps = Element.jsonSchemaProperties
        if !elementProps.isEmpty {
            var itemsObj: [String: Value] = ["type": .string(Element.jsonSchemaType)]
            for (key, val) in elementProps {
                itemsObj[key] = val
            }
            props["items"] = .object(itemsObj)
        }
        return props
    }

    /// Parse an array from an MCP Value.
    public init?(parameterValue value: Value) {
        guard case let .array(arr) = value else { return nil }

        var result: [Element] = []
        for item in arr {
            guard let element = Element(parameterValue: item) else {
                return nil
            }
            result.append(element)
        }
        self = result
    }
}

// MARK: - Dictionary Conformance

extension Dictionary: ParameterValue where Key == String, Value: ParameterValue {
    public static var jsonSchemaType: String { "object" }
    public static var placeholderValue: [String: Value] { [:] }

    public static var jsonSchemaProperties: [String: MCP.Value] {
        var additionalProps: [String: MCP.Value] = ["type": .string(Value.jsonSchemaType)]
        // Merge value type's additional properties
        let valueProps = Value.jsonSchemaProperties
        for (key, val) in valueProps {
            additionalProps[key] = val
        }
        return ["additionalProperties": .object(additionalProps)]
    }

    /// Parse a dictionary from an MCP Value.
    public init?(parameterValue value: MCP.Value) {
        guard case let .object(dict) = value else { return nil }

        var result: [String: Value] = [:]
        for (key, val) in dict {
            guard let parsed = Value(parameterValue: val) else {
                return nil
            }
            result[key] = parsed
        }
        self = result
    }
}

// MARK: - ToolEnum Protocol

/// Protocol for enum types that can be used as tool parameters.
///
/// Conforming types must be `RawRepresentable` with a `String` raw value
/// and provide the list of all possible cases for JSON Schema generation.
///
/// Example:
/// ```swift
/// enum Priority: String, ToolEnum {
///     case low, medium, high
///
///     static var allCases: [Priority] { [.low, .medium, .high] }
/// }
///
/// @Tool
/// struct SetPriority {
///     static let name = "set_priority"
///     static let description = "Set task priority"
///
///     @Parameter(description: "Priority level")
///     var priority: Priority
/// }
/// ```
public protocol ToolEnum: ParameterValue, RawRepresentable, CaseIterable where RawValue == String {}

public extension ToolEnum {
    static var jsonSchemaType: String { "string" }

    /// Uses the first case as the placeholder value.
    static var placeholderValue: Self {
        guard let first = allCases.first else {
            fatalError("ToolEnum '\(Self.self)' must have at least one case")
        }
        return first
    }

    static var jsonSchemaProperties: [String: Value] {
        let cases = allCases.map { Value.string($0.rawValue) }
        return ["enum": .array(cases)]
    }

    /// Parse an enum from an MCP Value containing its raw string value.
    init?(parameterValue value: Value) {
        guard case let .string(str) = value else { return nil }
        self.init(rawValue: str)
    }
}
