// Copyright © Anthony DePasquale

import Foundation

/// A type that can be returned from an MCP tool's `perform(context:)` method.
///
/// Two roles:
/// - **Generic constraint on closure-based `register(...)`.** The high-level
///   `MCPServer.register(...)` overloads accept any `Output: ToolOutput`, so
///   a single overload covers every built-in return type without
///   multiplying call sites per shape.
/// - **Advanced escape hatch for custom return types.** When none of the six
///   built-in types (`String`, `@Schemable @StructuredOutput` struct,
///   ``Media``, ``MediaWithMetadata``, ``Asset``, ``AssetWithMetadata``) fits
///   — for example, a tool that genuinely needs to emit image + PDF in one
///   result — conform a custom type to `ToolOutput` and produce a
///   `CallTool.Result` from its `toCallToolResult()`. Use this only
///   after the built-in types have been ruled out.
///
/// Example:
/// ```swift
/// func perform() async throws -> String {
///     "Hello, world!"
/// }
/// ```
public protocol ToolOutput: Sendable {
    /// Convert to `CallTool.Result` for the response.
    /// - Throws: On encoding failure - server returns error, doesn't crash.
    func toCallToolResult() throws -> CallTool.Result
}

// `String` conforms to `ToolOutput` transitively through
// `PrimitiveToolOutput` (see `PrimitiveToolOutput.swift`). A tool returning
// `String` now emits `content = [.text(value)]` *and*
// `structuredContent = {"result": value}` — the display and wire channels are
// always populated together for every value return type.

// MARK: - Structured Output

/// A tool output type that provides a JSON Schema for validation.
///
/// Conforming types pair `@Schemable` (from JSONSchemaBuilder) for schema
/// generation with `@StructuredOutput` (from MCPCore) for a stable wire
/// encoding and automatic `StructuredOutput` conformance.
///
/// Example:
/// ```swift
/// @Schemable
/// @StructuredOutput
/// struct EventList: Sendable {
///     let events: [String]
///     let totalCount: Int
/// }
///
/// @Tool
/// struct GetEvents {
///     static let name = "get_events"
///     static let description = "Get events"
///
///     func perform() async throws -> EventList {
///         EventList(events: ["Event 1", "Event 2"], totalCount: 2)
///     }
/// }
/// ```
///
/// `@StructuredOutput` generates the `outputJSONSchema` implementation by
/// bridging to `Self.schema` (from `@Schemable`) through `SchemableAdapter`.
/// One source of truth for schema generation across inputs and outputs.
public protocol StructuredOutput: ToolOutput, Encodable {
    /// The JSON Schema for this output type, in MCP wire (`Value`) form.
    ///
    /// `@StructuredOutput` synthesizes this from the type's `@Schemable`
    /// component and post-processes the result so every property appears in
    /// `required` — matching the wire contract where optional Swift properties
    /// are always emitted as `null` rather than absent.
    static var outputJSONSchema: Value { get }

    /// The `JSONEncoder` used when encoding this type for the wire.
    ///
    /// Defaults to `MCPEncoding.defaultEncoder()` — sorted keys plus ISO8601
    /// date encoding.
    ///
    /// - Important: Whatever this encoder emits is validated against the
    ///   schema derived from the type's `@Schemable` component on every
    ///   `CallTool` response. If the encoder diverges from the schema — for
    ///   example, a `dateEncodingStrategy` that emits Unix timestamps while
    ///   the schema declares `"format": "date-time"`, or a
    ///   `keyEncodingStrategy` that rewrites property names — the server
    ///   will reject the tool's own output at runtime. Safe overrides are
    ///   limited to byte-level formatting (sorted keys, pretty printing)
    ///   and ISO8601 variants that still match `date-time`. To change the
    ///   wire shape of individual fields, declare them with the target
    ///   Swift type (e.g. `Int` for Unix seconds) or opt out of macro
    ///   synthesis with `@ManualEncoding` and write an `encode(to:)` whose
    ///   output matches the `@Schemable` schema.
    /// - Note: Consumers should treat the encoder as the single source of
    ///   truth for the byte representation of the tool's output;
    ///   pretty-printing and other presentation transforms belong at the
    ///   consumer boundary.
    static var encoder: JSONEncoder { get }
}

public extension StructuredOutput {
    static var encoder: JSONEncoder {
        MCPEncoding.defaultEncoder()
    }

    /// Default implementation that encodes to JSON (using `Self.encoder`) and
    /// includes both `content[0].text` (stringified payload) and
    /// `structuredContent` (decoded `Value` form). Tools that need a
    /// different wire shape override this method.
    func toCallToolResult() throws -> CallTool.Result {
        let data = try Self.encoder.encode(self)

        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPError.internalError("Failed to encode \(Self.self) output as UTF-8 string")
        }

        let structured = try JSONDecoder().decode(Value.self, from: data)

        return CallTool.Result(
            content: [.text(json)],
            structuredContent: structured,
        )
    }
}

// MARK: - Default Encoder Factory

/// Namespace for the library's encoder defaults. Keeping this behind a
/// dedicated `MCPEncoding` name (rather than something like `MCP.defaultEncoder`)
/// avoids ambiguity with the `MCP` module itself when consumers have both the
/// `MCP` runtime and `MCPCore` imported.
public enum MCPEncoding {
    /// The encoder used by `StructuredOutput.toCallToolResult()` unless a
    /// conforming type overrides `encoder`.
    ///
    /// - `outputFormatting: .sortedKeys` keeps the byte form stable so
    ///   consumers (including the CLI) can produce byte-equivalent output
    ///   across invocations and platforms.
    /// - `dateEncodingStrategy: .iso8601` matches the apple-mcp convention
    ///   of emitting ISO8601 date strings rather than floating-point
    ///   timestamps, and aligns with what code-mode consumers expect.
    ///
    /// Returns a fresh encoder each call so callers can mutate it locally
    /// without affecting the library-wide default.
    public static func defaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

// MARK: - MediaWithMetadata

/// A generic wrapper for media tools that preserves typed metadata at the
/// `Output` position so that `MCPSchema.outputSchema(for:)` can recover the schema
/// of `Metadata` at registration time.
///
/// A media tool defines a `@Schemable @StructuredOutput` metadata struct
/// (e.g. `ScreenshotMetadata { width, height, capture_time, display_id,
/// file_path? }`) and returns `MediaWithMetadata<ScreenshotMetadata>`. The
/// tool's declared return type is the generic instantiation — not an
/// existential `any StructuredMetadataCarrier` — so the registry can extract
/// the metadata type without runtime type erasure issues.
///
/// Example:
/// ```swift
/// @Schemable
/// @StructuredOutput
/// struct ScreenshotMetadata: Sendable {
///     let width: Int
///     let height: Int
///     let displayID: Int
///     let filePath: String?
/// }
///
/// @Tool
/// struct TakeScreenshot {
///     static let name = "take_screenshot"
///     static let description = "Capture the screen"
///
///     func perform() async throws -> MediaWithMetadata<ScreenshotMetadata> {
///         let (pngData, metadata) = try await captureScreen()
///         return MediaWithMetadata(
///             .image(data: pngData, mimeType: "image/png"),
///             metadata: metadata,
///         )
///     }
/// }
/// ```
///
/// Wire shape: the metadata is emitted *both* as the stringified JSON in
/// `content[0].text` (for clients that only read unstructured content)
/// *and* as `structuredContent` (for clients that decode the typed form).
/// Binary blocks (images, audio, …) follow the metadata text in `content`.
/// This matches the order already used by media tools today.
public struct MediaWithMetadata<Metadata: StructuredOutput>: ToolOutput, Sendable {
    /// Media blocks (image, audio). Rendered after the metadata text in
    /// the final `CallTool.Result.content` array.
    public let blocks: [Media.Block]

    /// Typed metadata. Drives the schema at registration time, and the
    /// `structuredContent` / `content[0].text` fields at invocation time.
    public let metadata: Metadata

    public init(_ blocks: [Media.Block], metadata: Metadata) {
        self.blocks = blocks
        self.metadata = metadata
    }

    /// Creates a `MediaWithMetadata` value from a single block. Convenience
    /// for the common one-block case.
    public init(_ block: Media.Block, metadata: Metadata) {
        blocks = [block]
        self.metadata = metadata
    }

    public func toCallToolResult() throws -> CallTool.Result {
        let data = try Metadata.encoder.encode(metadata)

        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPError.internalError("Failed to encode MediaWithMetadata<\(Metadata.self)> metadata as UTF-8 string")
        }

        let structured = try JSONDecoder().decode(Value.self, from: data)

        return CallTool.Result(
            content: [.text(json)] + blocks.map { $0.asContentBlock },
            structuredContent: structured,
        )
    }
}

/// Non-associated marker protocol that lets `MCPSchema.outputSchema(for:)` recover
/// the metadata schema from an `any StructuredMetadataCarrier.Type` existential.
/// `MediaWithMetadata<Metadata>` and `AssetWithMetadata<Metadata>` both have an
/// associated type through their generic parameter, so the marker is the only
/// way to cross the existential boundary and access `Metadata.outputJSONSchema`
/// without knowing the concrete metadata type at the call site.
///
/// Scoped to this file by design (declared `private` at file scope, which
/// Swift treats as equivalent to `fileprivate`): the only conformers are
/// `MediaWithMetadata` and `AssetWithMetadata`, and the dispatcher
/// (`MCPSchema.outputSchema(for:)`) lives in this file.
private protocol StructuredMetadataCarrier {
    static var metadataSchema: Value { get }
}

extension MediaWithMetadata: StructuredMetadataCarrier {
    fileprivate static var metadataSchema: Value {
        Metadata.outputJSONSchema
    }
}

extension AssetWithMetadata: StructuredMetadataCarrier {
    fileprivate static var metadataSchema: Value {
        Metadata.outputJSONSchema
    }
}

// `Media.Block` is `Hashable` (and therefore `Equatable`), so callers can
// compare `MediaWithMetadata` values in tests / snapshot assertions whenever
// their `Metadata` also supports the relevant protocol. `MediaWithMetadata`
// stops short of blanket `Codable` conformance: the wire shape is the
// `CallTool.Result` produced by `toCallToolResult()`, not a Codable
// round-trip of the envelope.
extension MediaWithMetadata: Equatable where Metadata: Equatable {}

extension MediaWithMetadata: Hashable where Metadata: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(metadata)
        hasher.combine(blocks)
    }
}

// MARK: - Schema Helper

/// Namespace for output-schema resolution helpers.
public enum MCPSchema {
    /// Returns the JSON Schema for a type if one can be derived, otherwise nil.
    ///
    /// Resolution order:
    /// 1. Types conforming to `StructuredOutput` → `outputJSONSchema`
    ///    (unwrapped — the struct carries its own named object shape).
    /// 2. `UnwrappedObjectOutput` types (today only `Dictionary<String, V>`)
    ///    → `valueSchema` directly, because the value is already a top-level
    ///    object on the wire.
    /// 3. `PrimitiveToolOutput` types (primitives, arrays, optionals) →
    ///    the value schema wrapped in
    ///    `{"type": "object", "properties": {"result": <valueSchema>},
    ///      "required": ["result"], "additionalProperties": false}`.
    /// 4. `MediaWithMetadata<Metadata>` / `AssetWithMetadata<Metadata>`
    ///    instantiations → `Metadata.outputJSONSchema` (via the
    ///    `StructuredMetadataCarrier` existential).
    ///
    /// Returns `nil` for custom `ToolOutput` conformers — the escape hatch
    /// doesn't publish schemas. A tool whose return type needs both the
    /// escape hatch *and* a wire-level schema must register one via a
    /// separate channel.
    ///
    /// `Any.Type` is used at the boundary so the registry can ask about any
    /// `Output` type without knowing at compile time which path applies.
    ///
    /// Concurrency: this function is called from `MCPServer.register(...)`,
    /// which lives on the server actor. The metatype casts produce
    /// `any …Protocol.Type` existentials; `StructuredOutput`,
    /// `UnwrappedObjectOutput`, and `PrimitiveToolOutput` all transitively
    /// refine `Sendable`, and Swift guarantees `any P.Type` is `Sendable`
    /// when `P: Sendable`. The dispatcher itself is stateless, so no
    /// locking or actor isolation is required.
    public static func outputSchema(for outputType: Any.Type) -> Value? {
        if let structured = outputType as? any StructuredOutput.Type {
            // Guard against a type that conforms to *both* `StructuredOutput`
            // and `PrimitiveToolOutput`. The dispatcher picks the unwrapped
            // schema here, but protocol-witness resolution would route
            // `toCallToolResult()` through `PrimitiveToolOutput`'s wrap
            // default — the two channels would disagree on the wire. The
            // assertion fires at `toolDefinition` time (registration),
            // pointing at the real cause instead of a downstream
            // output-schema validation failure.
            assert(
                !(outputType is any PrimitiveToolOutput.Type),
                "Type \(outputType) conforms to both StructuredOutput and PrimitiveToolOutput. Pick one: structs use StructuredOutput (unwrapped), primitives/arrays/optionals use PrimitiveToolOutput (wrapped under 'result').",
            )
            return structured.outputJSONSchema
        }
        if let unwrapped = outputType as? any UnwrappedObjectOutput.Type {
            assert(
                !(outputType is any PrimitiveToolOutput.Type),
                "Type \(outputType) conforms to both UnwrappedObjectOutput and PrimitiveToolOutput. UnwrappedObjectOutput emits as a top-level object; PrimitiveToolOutput wraps under 'result'. Pick one.",
            )
            return unwrapped.valueSchema
        }
        if let primitive = outputType as? any PrimitiveToolOutput.Type {
            return .object([
                "type": .string("object"),
                "properties": .object(["result": primitive.valueSchema]),
                "required": .array([.string("result")]),
                "additionalProperties": .bool(false),
            ])
        }
        if let carrier = outputType as? any StructuredMetadataCarrier.Type {
            return carrier.metadataSchema
        }
        return nil
    }
}

// The @StructuredOutput and @ManualEncoding macros are provided by the
// MCPCore module. `import MCP` re-exports MCPCore, so either import is
// sufficient; pair it with `import JSONSchemaBuilder` to access @Schemable:
//
//     import MCP                // re-exports MCPCore
//     import JSONSchemaBuilder  // for @Schemable
//
//     @Schemable
//     @StructuredOutput
//     struct MyOutput { ... }
