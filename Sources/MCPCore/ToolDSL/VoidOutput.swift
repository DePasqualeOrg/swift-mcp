// Copyright © Anthony DePasquale

import Foundation

/// Internal sentinel output type used by the `@Tool` macro and the
/// closure-based `register(...)` overloads to normalize `Void`-returning
/// handlers into the existing `StructuredOutput` / `ToolOutput` machinery.
///
/// Swift's `Void` is `()` — an empty tuple — and tuples can't adopt
/// protocol conformance. The library substitutes this sentinel for `Void`
/// at the two call sites that create `_perform` bridges. Authors never
/// reference `VoidOutput` directly.
///
/// Wire shape:
/// - `structuredContent = {"result": null}`
/// - `content = [.text("null")]`
///
/// Rationale: every value-returning tool emits `structuredContent` so
/// code-mode agents don't have to branch on its presence. Void tools are a
/// value — "ran, no value" — and join the pattern rather than being the
/// one silent exception.
public struct VoidOutput: StructuredOutput, Sendable, Encodable {
    public init() {}

    /// Schema for a Void-returning tool. Shape matches the wrap convention
    /// used by primitives/arrays/optionals — a top-level object with a single
    /// `"result"` property — but the inner type is `"null"` (valid per JSON
    /// Schema draft 2020-12).
    public static let outputJSONSchema: Value = .object([
        "type": .string("object"),
        "properties": .object(["result": .object(["type": .string("null")])]),
        "required": .array([.string("result")]),
        "additionalProperties": .bool(false),
    ])

    /// Encodes as `{"result": null}` so the default
    /// `StructuredOutput.toCallToolResult()` path — which encodes `self` and
    /// decodes the bytes into `Value` — produces a `structuredContent` that
    /// matches `outputJSONSchema`. The explicit `toCallToolResult()` override
    /// below short-circuits the round-trip for the display-text channel, but
    /// the encoder still has to stay honest in case it's called directly
    /// (e.g., a custom `Self.encoder` override).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .result)
    }

    private enum CodingKeys: String, CodingKey {
        case result
    }

    public func toCallToolResult() throws -> CallTool.Result {
        voidResultEmitter()
    }
}

/// Shared result emitter for Void-returning tools. Shape matches
/// `Optional<T>` returning `nil` — same structured channel populated,
/// same display text — so agents can treat "no value" uniformly regardless
/// of whether the tool returns `T?` or `Void`.
func voidResultEmitter() -> CallTool.Result {
    CallTool.Result(
        content: [.text("null")],
        structuredContent: .object(["result": .null]),
    )
}
