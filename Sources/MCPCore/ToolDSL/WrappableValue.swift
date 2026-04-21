// Copyright © Anthony DePasquale

import Foundation

/// A type whose Swift value can be wrapped into ``CallTool/Result``'s
/// `structuredContent` as a JSON-schema-described value.
///
/// This is the element-level marker: anything that can appear inside an array,
/// an optional, a dictionary value, or as the wrapped value of a tool return
/// conforms.
///
/// The library conforms exactly these built-in types:
///
/// - Scalars: `Int`, `Double`, `Bool`, `String`, `Date`.
/// - Collections: `Array<Element>`, `Optional<Wrapped>`,
///   `Dictionary<String, Value>` — each conditionally, when the inner type
///   is itself `WrappableValue`.
/// - `@Schemable @StructuredOutput` structs — via a constrained extension.
///
/// Sized-int variants (`Int32`, `Int64`, `UInt`, …), `Float`, `Decimal`,
/// `URL`, and other common value types **do not conform**. The sealed set
/// keeps the JSON wire shape uncontroversial — JSON has one integer type
/// and one number type, and mapping Swift's richer numeric hierarchy onto
/// that is a policy question better resolved by the author than silently
/// by the library. For these cases, wrap the value in a
/// `@Schemable @StructuredOutput` struct whose Swift type is chosen to
/// match the intended wire shape (e.g. `Int` for "JSON integer",
/// `Double` for "JSON number"). The compiler surfaces a "does not conform
/// to `ToolOutput`" error at the `register(...)` / `perform()` site when
/// an unsupported type is returned directly.
///
/// The tool-output-level machinery lives on `PrimitiveToolOutput` (for types
/// that wrap under `"result"`) and `Dictionary: ToolOutput` (for the
/// unwrapped top-level-object path).
public protocol WrappableValue: Encodable, Sendable {
    /// JSON schema for the value itself, *not* wrapped in an object.
    ///
    /// - `Int` → `{"type": "integer"}`, not `{"type": "object", "properties": {"result": ...}}`.
    /// - `[Int]` → `{"type": "array", "items": {"type": "integer"}}`.
    /// - `Int?` → `{"type": ["integer", "null"]}`.
    /// - A `@StructuredOutput` struct → the struct's full `outputJSONSchema`.
    ///
    /// `PrimitiveToolOutput.toCallToolResult()` wraps this schema under
    /// `"result"` when producing the tool's `outputSchema`. Authors don't
    /// implement this directly for conforming built-in types — the library
    /// supplies it.
    static var valueSchema: Value { get }

    /// The value as a `Value`, for use as an array element, dictionary value,
    /// or to be wrapped under `"result"` in `structuredContent`.
    ///
    /// Implementations round-trip through the structured-output encoder when
    /// the value is encodable (e.g., `Date`, `@StructuredOutput` struct) so
    /// the emitted bytes stay in lockstep with the schema.
    func asJSONValue() throws -> Value

    /// The value rendered as a single text block for `content[0].text`.
    ///
    /// Scalars stringify (`Int(42)` → `"42"`, `Bool(true)` → `"true"`);
    /// `String` passes through verbatim; compound values (arrays,
    /// dictionaries, struct bodies) JSON-encode `self` directly via
    /// `MCPEncoding.defaultEncoder()` with `.prettyPrinted` so the display
    /// channel stays uniform across tools.
    ///
    /// `Optional<Wrapped>` is a special case: `.none` renders as the
    /// literal `"null"` (matching the structured channel), and `.some(value)`
    /// JSON-encodes the unwrapped `value` so an `Int?.some(42)` renders as
    /// `"42"` — the same text a bare `Int(42)` would produce. This keeps
    /// `.some(x)` visually indistinguishable from `x` for scalar display,
    /// at the cost that `String?.some("hello")` renders as `"\"hello\""`
    /// (JSON of a string is quoted) while bare `String("hello")` renders
    /// as `hello`. The structured channel is the source of truth; the
    /// display channel is a rendering convenience.
    func asDisplayText() throws -> String
}

// MARK: - Primitive conformances

extension Int: WrappableValue {
    public static var valueSchema: Value {
        .object(["type": .string("integer")])
    }

    public func asJSONValue() throws -> Value {
        .int(self)
    }

    public func asDisplayText() throws -> String {
        String(self)
    }
}

extension Double: WrappableValue {
    public static var valueSchema: Value {
        .object(["type": .string("number")])
    }

    public func asJSONValue() throws -> Value {
        // JSON has no representation for `NaN`, `Infinity`, or `-Infinity`,
        // so the wire channel fails here. The display channel
        // (`asDisplayText()`) stringifies these values normally — it's not
        // JSON, and `"nan"` is a perfectly reasonable thing for a user to
        // read.
        if isNaN || isInfinite {
            throw MCPError.internalError(
                "Double value \(self) is not representable in JSON. `NaN`, `Infinity`, and `-Infinity` have no JSON form — return a sentinel value or a `@StructuredOutput` struct that expresses the case explicitly.",
            )
        }
        return .double(self)
    }

    public func asDisplayText() throws -> String {
        String(self)
    }
}

extension Bool: WrappableValue {
    public static var valueSchema: Value {
        .object(["type": .string("boolean")])
    }

    public func asJSONValue() throws -> Value {
        .bool(self)
    }

    public func asDisplayText() throws -> String {
        String(self)
    }
}

extension String: WrappableValue {
    public static var valueSchema: Value {
        .object(["type": .string("string")])
    }

    public func asJSONValue() throws -> Value {
        .string(self)
    }

    public func asDisplayText() throws -> String {
        self
    }
}

extension Date: WrappableValue {
    public static var valueSchema: Value {
        .object([
            "type": .string("string"),
            "format": .string("date-time"),
        ])
    }

    public func asJSONValue() throws -> Value {
        // Route through the same encoder the server's runtime schema
        // validator expects. Hand-constructing `.string(iso-ish)` would
        // drift from `MCPEncoding.defaultEncoder()` if the default encoder
        // policy ever changes.
        let data = try MCPEncoding.defaultEncoder().encode(self)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func asDisplayText() throws -> String {
        // `MCPEncoding.defaultEncoder()` uses `.iso8601`, which matches
        // `ISO8601DateFormatter` with `[.withInternetDateTime]` — Foundation's
        // documented default, but pinned explicitly here so a future Foundation
        // change can't silently drift the display format away from the wire
        // format. `ISO8601DateFormatter` isn't `Sendable`, so a fresh instance
        // is built per call; formatter construction is cheap and display
        // rendering isn't a hot path.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: self)
    }
}

// MARK: - Compound conformances

extension Array: WrappableValue where Element: WrappableValue {
    public static var valueSchema: Value {
        .object([
            "type": .string("array"),
            "items": Element.valueSchema,
        ])
    }

    public func asJSONValue() throws -> Value {
        try .array(map { try $0.asJSONValue() })
    }

    public func asDisplayText() throws -> String {
        try prettyPrintedJSON(self)
    }
}

extension Optional: WrappableValue where Wrapped: WrappableValue {
    public static var valueSchema: Value {
        Value.promoteToNullable(Wrapped.valueSchema)
    }

    public func asJSONValue() throws -> Value {
        switch self {
            case .none:
                .null
            case let .some(value):
                try value.asJSONValue()
        }
    }

    public func asDisplayText() throws -> String {
        switch self {
            case .none:
                "null"
            case let .some(value):
                try prettyPrintedJSON(value)
        }
    }
}

// MARK: - StructuredOutput bridge

public extension WrappableValue where Self: StructuredOutput {
    static var valueSchema: Value {
        outputJSONSchema
    }

    func asJSONValue() throws -> Value {
        let data = try Self.encoder.encode(self)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func asDisplayText() throws -> String {
        try prettyPrintedJSON(self)
    }
}

// MARK: - Shared helpers

extension Value {
    /// Promotes a value schema to allow `null` in addition to whatever type(s)
    /// it already declares. Primitives/structs both declare `"type"` as a
    /// string; arrays declare `"type": "array"`; the object literal case is
    /// `"type": "object"`. We merge `"null"` into the `"type"` list. Schemas
    /// that describe their shape entirely through composition keywords
    /// (`anyOf`, `oneOf`, …) without a `"type"` field, or whose `"type"`
    /// field is malformed (neither a string nor an array of strings — not
    /// valid JSON Schema, but worth not corrupting further), fall back to
    /// wrapping in `{"anyOf": [<existing>, {"type": "null"}]}`.
    static func promoteToNullable(_ schema: Value) -> Value {
        guard case var .object(fields) = schema else {
            return anyOfNullable(schema)
        }
        guard let existingType = fields["type"] else {
            return anyOfNullable(schema)
        }
        switch existingType {
            case let .string(name):
                if name == "null" {
                    return schema
                }
                fields["type"] = .array([.string(name), .string("null")])
                return .object(fields)
            case let .array(elements):
                if elements.contains(.string("null")) {
                    return schema
                }
                fields["type"] = .array(elements + [.string("null")])
                return .object(fields)
            default:
                // Malformed `"type"` (not a string, not an array). Don't
                // silently mangle it further — wrap the whole schema in an
                // `anyOf` and let validators surface the original shape
                // alongside `null`.
                return anyOfNullable(schema)
        }
    }

    private static func anyOfNullable(_ schema: Value) -> Value {
        .object([
            "anyOf": .array([schema, .object(["type": .string("null")])]),
        ])
    }
}

/// Pretty-prints an `Encodable` value through `MCPEncoding.defaultEncoder()`
/// so display text stays byte-equivalent to the wire channel up to
/// indentation. Used by compound `WrappableValue` conformers (`Array`,
/// `Optional`, `Dictionary`, `@StructuredOutput` structs). Encoding `self`
/// directly — rather than first converting to a `Value` — avoids a
/// per-element encode/decode round-trip, especially for `[MyStruct]`.
func prettyPrintedJSON(_ value: some Encodable) throws -> String {
    let encoder = MCPEncoding.defaultEncoder()
    encoder.outputFormatting.insert(.prettyPrinted)
    let data = try encoder.encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
        throw MCPError.internalError("Failed to render encoded value as UTF-8 text")
    }
    return text
}
