// Copyright © Anthony DePasquale

import Foundation

/// Image or audio content returned from a tool.
///
/// `Media` is the baseline form of the media category: image or audio bytes
/// emitted into the wire's `content[]` channel for direct client rendering
/// and multimodal-model ingestion. Intrinsic blob metadata (EXIF, ID3, codec
/// headers) rides through the bytes unchanged. If a tool needs to surface
/// typed JSON metadata alongside the content (face-detection bboxes, chart
/// axis info, …), use ``MediaWithMetadata`` instead.
///
/// Blocks carry raw `Data`; base64 encoding happens once at conversion to
/// `CallTool.Result`, so authors pass raw bytes rather than pre-encoded
/// strings.
///
/// Example:
/// ```swift
/// func perform() async throws -> Media {
///     let pngData = try await captureScreen()
///     return Media(.image(data: pngData, mimeType: "image/png"))
/// }
/// ```
public struct Media: Sendable, Hashable {
    /// A single image or audio block.
    ///
    /// Narrow by design: the media category covers image and audio only.
    /// Resources (files, links) belong on ``Asset``; plain text belongs on
    /// `String`. This keeps each return type pointed at one job.
    public enum Block: Sendable, Hashable {
        /// Image content. `data` is raw image bytes (PNG, JPEG, …);
        /// `mimeType` describes them (for example `"image/png"`).
        case image(data: Data, mimeType: String, annotations: Annotations? = nil)

        /// Audio content. `data` is raw audio bytes (MP3, WAV, …);
        /// `mimeType` describes them (for example `"audio/mpeg"`).
        case audio(data: Data, mimeType: String, annotations: Annotations? = nil)
    }

    /// The blocks, in the order they should appear on the wire.
    public let blocks: [Block]

    /// Creates a `Media` value from a sequence of blocks.
    public init(_ blocks: [Block]) {
        self.blocks = blocks
    }

    /// Creates a `Media` value from a single block. Convenience for the
    /// common one-block case, so authors write `Media(.image(...))` rather
    /// than `Media([.image(...)])`.
    public init(_ block: Block) {
        blocks = [block]
    }
}

extension Media: ToolOutput {
    public func toCallToolResult() throws -> CallTool.Result {
        CallTool.Result(content: blocks.map { $0.asContentBlock })
    }
}

extension Media.Block {
    /// Maps the block to a wire-level `ContentBlock` case. Base64 encoding
    /// happens here, once, at the edge. Internal so `MediaWithMetadata`
    /// (in a sibling file) can reuse it.
    var asContentBlock: ContentBlock {
        switch self {
            case let .image(data, mimeType, annotations):
                .image(
                    data: data.base64EncodedString(),
                    mimeType: mimeType,
                    annotations: annotations,
                    _meta: nil,
                )
            case let .audio(data, mimeType, annotations):
                .audio(
                    data: data.base64EncodedString(),
                    mimeType: mimeType,
                    annotations: annotations,
                    _meta: nil,
                )
        }
    }
}
