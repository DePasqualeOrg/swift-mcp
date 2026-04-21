// Copyright © Anthony DePasquale

import Foundation

/// A generated file or resource-link reference returned from a tool.
///
/// `Asset` covers any non-image/audio content with a URI: generated PDFs,
/// ZIPs, videos, CSVs, URL references to pre-existing files or remote
/// assets, and so on. It's the baseline form of the resource category; for
/// tools that also need to surface typed JSON metadata alongside the content
/// (PDF + page count, ZIP + file list), use ``AssetWithMetadata`` instead.
///
/// Three block cases cover the MCP wire shapes for resource content:
/// `.binary` and `.text` map to `ContentBlock.resource(...)` (client
/// downloads or previews inline), while `.link` maps to
/// `ContentBlock.resourceLink(...)` (client fetches lazily on demand).
/// Image and audio content belongs on ``Media``; plain text without a URI
/// belongs on `String`. This keeps each return type pointed at one job.
///
/// Example:
/// ```swift
/// func perform() async throws -> Asset {
///     let pdfData = try await renderReport()
///     return Asset(.binary(
///         pdfData,
///         uri: "file:///tmp/report.pdf",
///         mimeType: "application/pdf",
///     ))
/// }
/// ```
public struct Asset: Sendable, Hashable {
    /// A single asset block – an embedded resource (binary or text) or a
    /// resource link.
    public enum Block: Sendable, Hashable {
        /// Embedded binary resource (PDF, ZIP, video, …). The first
        /// associated value is raw bytes; base64 encoding happens once at
        /// conversion to `CallTool.Result`. `uri` is required so clients
        /// can track or reference the resource; `mimeType` is optional to
        /// mirror the wire model (`Resource.Contents.mimeType`).
        ///
        /// Raw filesystem paths (`/tmp/report.pdf`) are not URIs – prefix
        /// with `file://` to form a valid wire value.
        case binary(
            _ data: Data,
            uri: String,
            mimeType: String? = nil,
            annotations: Annotations? = nil,
        )

        /// Embedded text resource (generated markdown, CSV, code, …).
        /// Distinct from the `String` return type: `.text` is for a
        /// *resource with a URI* that the client tracks, while plain text
        /// without a URI uses `String`.
        case text(
            _ text: String,
            uri: String,
            mimeType: String? = nil,
            annotations: Annotations? = nil,
        )

        /// URL reference to a resource that can be read later. Used when
        /// the tool produces a file or asset the client should fetch
        /// lazily, not embed inline. Optional fields mirror `ResourceLink`
        /// on the wire so download-style results (size, title, icons) stay
        /// in the built-in type instead of dropping to `ToolOutput`
        /// conformance.
        case link(
            _ uri: String,
            name: String,
            title: String? = nil,
            description: String? = nil,
            mimeType: String? = nil,
            size: Int? = nil,
            icons: [Icon]? = nil,
            annotations: Annotations? = nil,
        )
    }

    /// The blocks, in the order they should appear on the wire.
    public let blocks: [Block]

    /// Creates an `Asset` value from a sequence of blocks.
    public init(_ blocks: [Block]) {
        self.blocks = blocks
    }

    /// Creates an `Asset` value from a single block. Convenience for the
    /// common one-block case, so authors write `Asset(.binary(...))`
    /// rather than `Asset([.binary(...)])`.
    public init(_ block: Block) {
        blocks = [block]
    }
}

extension Asset: ToolOutput {
    public func toCallToolResult() throws -> CallTool.Result {
        CallTool.Result(content: blocks.map { $0.asContentBlock })
    }
}

extension Asset.Block {
    /// Maps the block to a wire-level `ContentBlock` case. Base64 encoding
    /// happens here, once, at the edge. Internal so `AssetWithMetadata`
    /// can reuse it.
    var asContentBlock: ContentBlock {
        switch self {
            case let .binary(data, uri, mimeType, annotations):
                .resource(
                    .binary(data, uri: uri, mimeType: mimeType),
                    annotations: annotations,
                    _meta: nil,
                )
            case let .text(text, uri, mimeType, annotations):
                .resource(
                    .text(text, uri: uri, mimeType: mimeType),
                    annotations: annotations,
                    _meta: nil,
                )
            case let .link(uri, name, title, description, mimeType, size, icons, annotations):
                .resourceLink(
                    ResourceLink(
                        name: name,
                        title: title,
                        uri: uri,
                        description: description,
                        mimeType: mimeType,
                        size: size,
                        annotations: annotations,
                        icons: icons,
                    ),
                )
        }
    }
}

// MARK: - AssetWithMetadata

/// An ``Asset`` plus typed JSON metadata, surfaced through the
/// `structuredContent` / `outputSchema` wire channel.
///
/// Use when the tool produces a file (or asset link) *and* wants an
/// agentic caller to compose against typed fields – e.g. a `generatePDF`
/// tool returning an embedded PDF block plus a `PDFInfo` metadata struct
/// with `pageCount`, `uri`, and a table of contents. The metadata's schema
/// is recovered at registration time via `StructuredMetadataCarrier`.
///
/// Include the asset's URI as a field on the `Metadata` type so agents
/// composing tool results in code mode can reference it directly from
/// `structuredContent` rather than parsing `content[]`.
///
/// Example:
/// ```swift
/// @Schemable
/// @StructuredOutput
/// struct PDFInfo: Sendable {
///     let uri: String
///     let pageCount: Int
/// }
///
/// func perform() async throws -> AssetWithMetadata<PDFInfo> {
///     let (pdfData, info) = try await renderReport()
///     return AssetWithMetadata(
///         .binary(pdfData, uri: info.uri, mimeType: "application/pdf"),
///         metadata: info,
///     )
/// }
/// ```
public struct AssetWithMetadata<Metadata: StructuredOutput>: ToolOutput, Sendable {
    /// Asset blocks. Rendered after the metadata text in the final
    /// `CallTool.Result.content` array.
    public let blocks: [Asset.Block]

    /// Typed metadata. Drives the schema at registration time and the
    /// `structuredContent` / `content[0].text` fields at invocation time.
    public let metadata: Metadata

    public init(_ blocks: [Asset.Block], metadata: Metadata) {
        self.blocks = blocks
        self.metadata = metadata
    }

    /// Creates an `AssetWithMetadata` value from a single block. Convenience
    /// for the common one-block case.
    public init(_ block: Asset.Block, metadata: Metadata) {
        blocks = [block]
        self.metadata = metadata
    }

    public func toCallToolResult() throws -> CallTool.Result {
        let data = try Metadata.encoder.encode(metadata)

        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPError.internalError("Failed to encode AssetWithMetadata<\(Metadata.self)> metadata as UTF-8 string")
        }

        let structured = try JSONDecoder().decode(Value.self, from: data)

        return CallTool.Result(
            content: [.text(json)] + blocks.map { $0.asContentBlock },
            structuredContent: structured,
        )
    }
}

extension AssetWithMetadata: Equatable where Metadata: Equatable {}

extension AssetWithMetadata: Hashable where Metadata: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(metadata)
        hasher.combine(blocks)
    }
}
