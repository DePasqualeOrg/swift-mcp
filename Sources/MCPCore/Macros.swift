// Copyright © Anthony DePasquale

// Public macro declarations that pair with runtime types in MCPCore.
//
// These live in MCPCore (rather than MCPTool) so consumers can adopt the
// structured-output contract without pulling in the MCP server runtime —
// only the types and protocols they need.

// MARK: - StructuredOutput Macro

/// Macro that synthesizes `StructuredOutput` conformance for a struct, paired
/// with JSONSchemaBuilder's `@Schemable`.
///
/// Each attribute owns one concern:
/// - `@Schemable` (from JSONSchemaBuilder) — generates the JSON Schema
///   (`CodingKeys`-aware, recursive, enum- and description-friendly).
/// - `@StructuredOutput` (this macro) — synthesizes a stable `encode(to:)`
///   that calls `container.encode` for every stored property (optionals
///   emit as `null` rather than being absent), adds `StructuredOutput`
///   conformance, and bridges `outputJSONSchema` to the Schemable component
///   through `SchemableAdapter`.
///
/// Usage:
///
/// ```swift
/// @Schemable
/// @StructuredOutput
/// struct MyResult: Sendable {
///     let events: [String]
///     let note: String?
/// }
/// ```
///
/// Diagnostics:
/// - Missing `@Schemable` on the same type → targeted compile error.
/// - User-written `encode(to:)` without `@ManualEncoding` → compile error.
///   Remove the custom encoder to accept synthesis, or add `@ManualEncoding`
///   to opt out and take responsibility for stable-shape correctness.
@attached(member, names: named(encode), named(CodingKeys))
@attached(extension, conformances: StructuredOutput, WrappableValue, names: named(outputJSONSchema), named(_structuredOutputSchema))
public macro StructuredOutput() = #externalMacro(module: "MCPMacros", type: "StructuredOutputMacro")

// MARK: - ManualEncoding Marker

/// Marker attribute that opts out of `@StructuredOutput`'s `encode(to:)`
/// synthesis. No code is generated — the attribute's presence alone is the
/// signal that the author is intentionally hand-rolling the encoder (e.g.
/// to emit an additive computed field alongside the declared properties)
/// and takes responsibility for stable-shape correctness.
///
/// The hand-rolled encoder is still validated against the schema
/// `@Schemable` generates from the Swift struct at `CallTool` time. Safe
/// hand-rolled divergences are narrow: reformatting a property within its
/// declared type, or emitting extra keys beyond those in the schema.
/// Changing a declared property's wire type (for example, Unix seconds for
/// a `Date` field) fails runtime output-schema validation — change the
/// Swift type instead (`Int` for Unix seconds).
@attached(peer)
public macro ManualEncoding() = #externalMacro(module: "MCPMacros", type: "ManualEncodingMacro")
