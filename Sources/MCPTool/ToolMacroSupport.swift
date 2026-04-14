// Copyright © Anthony DePasquale

import JSONSchemaBuilder
import MCP

/// Public runtime support used by `@Tool` macro expansions.
///
/// Lives in `MCPTool` so generated-code plumbing doesn't leak through the `MCP`
/// library target.
public enum ToolMacroSupport {
    /// Runtime schema metadata for a single generated tool parameter.
    public struct SchemaParameterDescriptor: Sendable {
        public let name: String
        public let title: String?
        public let description: String?
        public let jsonSchemaType: String
        public let jsonSchemaProperties: [String: Value]
        public let isOptional: Bool
        public let hasDefault: Bool
        public let defaultValue: Value?
        public let minLength: Int?
        public let maxLength: Int?
        public let minimum: Double?
        public let maximum: Double?

        public init(
            name: String,
            title: String? = nil,
            description: String? = nil,
            jsonSchemaType: String,
            jsonSchemaProperties: [String: Value] = [:],
            isOptional: Bool,
            hasDefault: Bool = false,
            defaultValue: Value? = nil,
            minLength: Int? = nil,
            maxLength: Int? = nil,
            minimum: Double? = nil,
            maximum: Double? = nil,
        ) {
            self.name = name
            self.title = title
            self.description = description
            self.jsonSchemaType = jsonSchemaType
            self.jsonSchemaProperties = jsonSchemaProperties
            self.isOptional = isOptional
            self.hasDefault = hasDefault
            self.defaultValue = defaultValue
            self.minLength = minLength
            self.maxLength = maxLength
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    /// Builds a runtime schema descriptor from a `JSONSchemaComponent` produced
    /// by `@Schemable` (or the built-in conformances for primitives).
    ///
    /// The component's schema is converted to the internal `[String: Value]`
    /// representation and split into the legacy `jsonSchemaType` /
    /// `jsonSchemaProperties` fields so the shared strict-mode normalizer
    /// continues to work unchanged.
    ///
    /// This call is non-throwing — if Schemable conversion fails (programmer
    /// error), the descriptor is returned with an empty schema and the failure
    /// surfaces as a broken tool schema at the strict-mode check.
    public static func makeSchemaParameterDescriptor(
        name: String,
        title: String? = nil,
        description: String? = nil,
        schema component: some JSONSchemaComponent,
        isOptional: Bool,
        hasDefault: Bool = false,
        defaultValue: Value? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
    ) -> SchemaParameterDescriptor {
        let jsonSchemaType: String
        let jsonSchemaProperties: [String: Value]
        if var properties = try? SchemableAdapter.valueDictionary(from: component) {
            // Split `type` back out so the existing strict-mode nullable-wrapping
            // logic can operate on a simple scalar type string. Composite schemas
            // (`oneOf`, `anyOf`) with no top-level `type` fall through with an
            // empty string — nullable wrapping of composites is not supported and
            // surfaces as a strict-mode error if needed.
            jsonSchemaType = if case let .string(typeName) = properties.removeValue(forKey: "type") {
                typeName
            } else {
                ""
            }
            jsonSchemaProperties = properties
        } else {
            jsonSchemaType = ""
            jsonSchemaProperties = [:]
        }
        return SchemaParameterDescriptor(
            name: name,
            title: title,
            description: description,
            jsonSchemaType: jsonSchemaType,
            jsonSchemaProperties: jsonSchemaProperties,
            isOptional: isOptional,
            hasDefault: hasDefault,
            defaultValue: defaultValue,
            minLength: minLength,
            maxLength: maxLength,
            minimum: minimum,
            maximum: maximum,
        )
    }

    /// Parses a `Value` into a Swift value using the given schema component.
    /// Thin wrapper over `SchemableAdapter.parse` so macro-emitted parse sites
    /// only reference symbols in `MCPTool`.
    public static func parseParameter<Component: JSONSchemaComponent>(
        _ component: Component,
        from value: Value,
        parameterName: String,
    ) throws -> Component.Output {
        try SchemableAdapter.parse(component, from: value, parameterName: parameterName)
    }

    /// Builds a raw, provider-agnostic object JSON Schema from parameter descriptors.
    ///
    /// MCP is a provider-agnostic wire format, so OpenAI-specific normalization
    /// happens on the client side of the wire — never at build time here.
    public static func buildObjectSchema(
        parameters: [SchemaParameterDescriptor],
    ) throws -> [String: Value] {
        try ToolSchemaRuntime.buildObjectSchema(
            parameters: parameters,
            name: \.name,
            title: \.title,
            description: \.description,
            jsonSchemaType: \.jsonSchemaType,
            jsonSchemaProperties: \.jsonSchemaProperties,
            isOptional: \.isOptional,
            hasDefault: \.hasDefault,
            defaultValue: \.defaultValue,
            minLength: \.minLength,
            maxLength: \.maxLength,
            minimum: \.minimum,
            maximum: \.maximum,
        )
    }

    /// Asserts that `schema` is strict JSON Schema-compatible.
    ///
    /// Intended for use from macro-generated `@Tool` code when the tool author
    /// writes `static let strictSchema = true`. Failures are invariant violations
    /// (a broken programmer assertion); the macro wraps this call in `try!` so
    /// the result is a clear runtime trap with the tool name in the message.
    public static func validateStrictCompatibility(
        _ schema: [String: Value],
        toolName: String,
    ) throws {
        do {
            try ToolSchemaRuntime.validateStrictCompatibility(schema)
        } catch {
            throw StrictSchemaAssertionFailure(toolName: toolName, underlying: error)
        }
    }

    /// Error thrown when a tool declares `strictSchema: true` but its schema is
    /// not strict JSON Schema-compatible. Carries the tool name so the trap
    /// message produced by `try!` points at the offending tool.
    public struct StrictSchemaAssertionFailure: Error, CustomStringConvertible {
        public let toolName: String
        public let underlying: Error

        public var description: String {
            "@Tool '\(toolName)' declares strictSchema: true but its schema is not strict JSON Schema-compatible: \(underlying.localizedDescription)"
        }
    }
}
