// Copyright © Anthony DePasquale

import Foundation

/// An error thrown from a tool handler that carries rich multi-block content
/// on the wire.
///
/// Any `Error` thrown from a tool handler produces a `CallTool.Result` with
/// `isError: true`. Plain errors surface a single `.text` block derived from
/// `localizedDescription`. Conform to `ToolError` when the error needs to
/// carry multiple blocks (for example, a `.text` explanation plus an `.image`
/// of the failing chart), or when a single block that isn't plain text is
/// appropriate.
///
/// `ToolError` refines `LocalizedError` so that `Error.localizedDescription`
/// bridging continues to work: the default `errorDescription` joins the
/// `.text` blocks of `content`, so callers outside the MCP dispatch path
/// (logs, CLI fallbacks) still get a useful description for free. Conformers
/// may override `errorDescription` to provide a custom string instead.
///
/// Errors are inherently cross-category (text + image, text + log link, …),
/// so `content` uses the `ContentBlock` wire union directly rather than a
/// narrow per-category enum like ``Media/Block`` or ``Asset/Block``. That
/// means image/audio cases carry **base64-encoded strings**, not raw
/// `Data` — call `bytes.base64EncodedString()` at the construction site.
/// Passing raw binary via `String(data:encoding:)` produces garbage on the
/// wire with no diagnostic from the library.
///
/// `ToolError` is for types *thrown* from tool handlers. Dual `ToolOutput` +
/// `ToolError` conformance is not a reliable way to signal per-instance
/// success or failure — the dispatcher routes thrown values through the
/// `ToolError` path and returned values through the `ToolOutput` path, so
/// the same type can produce different wire shapes depending on whether it
/// was thrown or returned. Use distinct types, or throw.
///
/// Example:
/// ```swift
/// struct RenderFailure: ToolError {
///     let message: String
///     let failingChart: Data
///
///     var content: [ContentBlock] {
///         [
///             .text(message),
///             .image(data: failingChart.base64EncodedString(), mimeType: "image/png"),
///         ]
///     }
/// }
/// ```
public protocol ToolError: LocalizedError {
    /// The content blocks surfaced on the `CallTool.Result` when this error
    /// is thrown. Passed through verbatim with `isError: true`.
    ///
    /// Image and audio blocks require base64-encoded `data` strings (the
    /// wire shape); see the type-level doc for the rationale.
    var content: [ContentBlock] { get }
}

public extension ToolError {
    var errorDescription: String? {
        let texts = content.compactMap { block -> String? in
            if case let .text(text, _, _) = block { return text }
            return nil
        }
        if !texts.isEmpty {
            return texts.joined(separator: "\n")
        }
        // No text blocks — `ToolError` explicitly allows rich-only payloads
        // (for example, a single image). Return the conforming type's name
        // so `Error.localizedDescription` bridging still produces something
        // meaningful for logs and CLI fallbacks instead of delegating to
        // Foundation's generic stub. Conformers that want a better string
        // can override `errorDescription` directly.
        return "\(Self.self)"
    }
}
