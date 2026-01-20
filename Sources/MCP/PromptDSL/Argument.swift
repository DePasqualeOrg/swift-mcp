/// Protocol for types that can be used as prompt argument values.
///
/// Per the MCP specification, prompt arguments are always strings.
/// Only `String` and `Optional<String>` conform to this protocol.
public protocol ArgumentValue: Sendable {
    /// Whether this type represents an optional value.
    static var isOptional: Bool { get }

    /// Initialize from an argument string.
    /// - Parameter argumentString: The string value from the arguments dictionary.
    /// - Returns: The parsed value, or nil if parsing fails.
    init?(argumentString: String?)
}

extension String: ArgumentValue {
    public static var isOptional: Bool { false }

    public init?(argumentString: String?) {
        guard let value = argumentString else { return nil }
        self = value
    }
}

extension String?: ArgumentValue {
    public static var isOptional: Bool { true }

    public init?(argumentString: String?) {
        self = argumentString
    }
}

/// Property wrapper for MCP prompt arguments.
///
/// The `@Argument` property wrapper marks a property as a prompt argument and provides
/// metadata for the `Prompt.Argument` generation. The `@Prompt` macro inspects these
/// properties to generate the prompt's `arguments` array.
///
/// Per the MCP specification, prompt arguments are always strings. Use `String` for
/// required arguments and `String?` for optional arguments.
///
/// Example:
/// ```swift
/// @Prompt
/// struct GreetingPrompt {
///     static let name = "greeting"
///     static let description = "A personalized greeting"
///
///     // Required argument (non-optional type)
///     @Argument(description: "The person's name")
///     var name: String
///
///     // Optional argument
///     @Argument(description: "Preferred language")
///     var language: String?
///
///     // Argument with custom key
///     @Argument(key: "greeting_style", description: "Formal or casual")
///     var greetingStyle: String?
///
///     // Argument with display title
///     @Argument(title: "User's Name", description: "The person to greet")
///     var userName: String
/// }
/// ```
@propertyWrapper
public struct Argument<Value: ArgumentValue>: Sendable {
    public var wrappedValue: Value

    /// The argument name (key) used in the prompt definition.
    /// If nil, the Swift property name is used.
    public let key: String?

    /// A human-readable title for UI display.
    public let title: String?

    /// A description of the argument.
    public let description: String?

    /// Explicit required override (nil means infer from type).
    public let requiredOverride: Bool?

    /// Creates an argument with the specified metadata.
    ///
    /// - Parameters:
    ///   - wrappedValue: The default value for this argument.
    ///   - key: The argument key (defaults to property name).
    ///   - title: Human-readable display title.
    ///   - description: A description of the argument.
    ///   - required: Whether required (defaults to type inference).
    public init(
        wrappedValue: Value,
        key: String? = nil,
        title: String? = nil,
        description: String? = nil,
        required: Bool? = nil
    ) {
        self.wrappedValue = wrappedValue
        self.key = key
        self.title = title
        self.description = description
        requiredOverride = required
    }
}

public extension Argument where Value == String {
    /// Creates a required argument (value will be set during parsing).
    ///
    /// Use this initializer for required arguments without a default value.
    /// The argument's value will be set during parsing from prompt arguments.
    ///
    /// - Parameters:
    ///   - key: The argument key (defaults to property name).
    ///   - title: Human-readable display title.
    ///   - description: A description of the argument.
    ///   - required: Whether required (defaults to true for non-optional).
    init(
        key: String? = nil,
        title: String? = nil,
        description: String? = nil,
        required: Bool? = nil
    ) {
        wrappedValue = ""
        self.key = key
        self.title = title
        self.description = description
        requiredOverride = required
    }
}

public extension Argument where Value: ExpressibleByNilLiteral {
    /// Creates an optional argument.
    ///
    /// Use this initializer for optional arguments where no default value is needed.
    ///
    /// - Parameters:
    ///   - key: The argument key (defaults to property name).
    ///   - title: Human-readable display title.
    ///   - description: A description of the argument.
    ///   - required: Whether required (defaults to false for optional).
    init(
        key: String? = nil,
        title: String? = nil,
        description: String? = nil,
        required: Bool? = nil
    ) {
        wrappedValue = nil
        self.key = key
        self.title = title
        self.description = description
        requiredOverride = required
    }
}
