// Copyright © Anthony DePasquale

import Foundation
import JSONSchema
import JSONSchemaBuilder

/// Bridges `JSONSchemaComponent` output (produced by `@Schemable`) into the
/// internal `[String: Value]` representation used by the tool DSL.
///
/// Called from `@Tool` macro-emitted code at the user's call site, so the
/// entry points are `public`.
public enum SchemableAdapter {
    /// Converts a `JSONSchemaComponent` into `[String: Value]` by encoding the
    /// component's `Schema` definition to JSON and decoding it into `Value`.
    ///
    /// Throws if the component produces a non-object schema (JSON Schema allows
    /// boolean schemas, but tools always model parameters as objects) or if the
    /// Codable roundtrip fails.
    public static func valueDictionary(
        from component: some JSONSchemaComponent,
    ) throws -> [String: Value] {
        let schema = component.definition()
        let value = try Value(schema)
        guard case let .object(dictionary) = value else {
            throw MCPError.invalidParams("@Schemable component produced a non-object schema: \(value)")
        }
        return dictionary
    }

    /// Builds the `[String: Value]` schema used for `StructuredOutput` result
    /// types. Calls `valueDictionary(from:)` and then post-processes the result
    /// so every property appears in `required` — recursively, at every nested
    /// object schema inside the tree.
    ///
    /// Why: JSONSchemaBuilder's default for optional stored properties produces
    /// `type: ["T", "null"]` (nullable union) and leaves the property out of
    /// `required`. That matches the Python/Zod convention, where consumers can
    /// also see the key omitted entirely. For MCP structured tool output, our
    /// wire contract says every key is always present (optional Swift values
    /// encode as explicit `null`), and code-mode consumers generate typed
    /// interfaces from this schema — `required + nullable union` produces
    /// `field: T | null` (always defined), whereas `optional + nullable`
    /// produces `field?: T | null` (caller has to handle `undefined`). The
    /// post-processing keeps the schema strict without forking JSONSchemaBuilder.
    ///
    /// Why recursive: when a `@StructuredOutput` struct has a property whose
    /// type is itself `@Schemable`, JSONSchemaBuilder inlines that nested
    /// shape — and the nested shape still follows the "optional is absent
    /// from required" default. Without recursion, only the top-level's
    /// `required` is rewritten, so nested optionals violate the wire contract
    /// on the inner layer even though they serialize as explicit `null`.
    public static func structuredOutputSchemaDictionary(
        from component: some JSONSchemaComponent,
    ) throws -> [String: Value] {
        let dictionary = try valueDictionary(from: component)
        guard case let .object(rewritten) = promoteRequired(.object(dictionary)) else {
            return dictionary
        }
        return rewritten
    }

    /// Recursively promotes every nested object schema's `required` list to
    /// include all of its declared properties. Leaves non-object schemas
    /// untouched.
    ///
    /// Recurses only through JSON Schema keywords that describe **output
    /// shape**: `properties`, `items`, `prefixItems` (tuple-style arrays),
    /// `additionalProperties`, `patternProperties` (regex-keyed property
    /// groups), `oneOf`/`anyOf`/`allOf` (alternative/combined shapes), and
    /// `$defs`/`definitions` (reusable shape definitions).
    ///
    /// Deliberately skips validation-constraint keywords — `not`, `if`/
    /// `then`/`else`, `dependentSchemas`, `contains`, `propertyNames`,
    /// `unevaluatedProperties`, `unevaluatedItems`. Those describe what an
    /// instance must or must not satisfy, not the output's shape. Promoting
    /// `required` inside them would narrow what they reject (e.g. a `not`
    /// subschema originally rejecting `{has a}` would start rejecting only
    /// `{has a and b}` instead), changing the user's validation rule rather
    /// than fixing a wire-shape bug.
    ///
    /// Internal rather than private so tests can drive it with synthetic
    /// `Value` trees — the shape-level guarantee is strong enough to deserve
    /// direct unit coverage separate from the end-to-end macro-expansion tests.
    static func promoteRequired(_ value: Value) -> Value {
        switch value {
            case var .object(dict):
                if case let .object(properties)? = dict["properties"] {
                    let rewrittenProperties = properties.mapValues(promoteRequired)
                    dict["properties"] = .object(rewrittenProperties)
                    dict["required"] = .array(rewrittenProperties.keys.sorted().map(Value.string))
                }
                // Dictionary values and array item schemas may themselves be
                // object schemas that should be promoted.
                if let items = dict["items"] { dict["items"] = promoteRequired(items) }
                if case let .array(prefix)? = dict["prefixItems"] {
                    dict["prefixItems"] = .array(prefix.map(promoteRequired))
                }
                if let addl = dict["additionalProperties"] {
                    dict["additionalProperties"] = promoteRequired(addl)
                }
                if case let .object(patterns)? = dict["patternProperties"] {
                    dict["patternProperties"] = .object(patterns.mapValues(promoteRequired))
                }
                // Composition keywords carry alternative shapes; each may be
                // an object that needs promotion.
                for key in ["oneOf", "anyOf", "allOf"] {
                    if case let .array(variants)? = dict[key] {
                        dict[key] = .array(variants.map(promoteRequired))
                    }
                }
                // Reusable shape definitions — subschemas that may be referenced
                // via `$ref` elsewhere in the tree. `definitions` is the
                // draft-07 legacy name kept for schemas predating 2020-12.
                for key in ["$defs", "definitions"] {
                    if case let .object(defs)? = dict[key] {
                        dict[key] = .object(defs.mapValues(promoteRequired))
                    }
                }
                return .object(dict)
            case let .array(items):
                return .array(items.map(promoteRequired))
            default:
                return value
        }
    }

    /// Parses a `Value` into a Swift value using the given schema component.
    /// Converts Schemable `ParseIssue` errors into a human-readable
    /// `MCPError.invalidParams` message including the parameter name.
    public static func parse<Component: JSONSchemaComponent>(
        _ component: Component,
        from value: Value,
        parameterName: String,
    ) throws -> Component.Output {
        let jsonValue = value.toJSONValue()
        switch component.parse(jsonValue) {
            case let .valid(output):
                return output
            case let .invalid(issues):
                let detail = issues.map(\.description).joined(separator: "; ")
                throw MCPError.invalidParams(
                    "Invalid value for '\(parameterName)': expected \(Component.Output.self), got \(value) — \(detail)",
                )
        }
    }
}
