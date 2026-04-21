// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Foundation

/// A content block carried by a tool result or a prompt message.
///
/// Matches the MCP spec (2025-11-25) `ContentBlock` union:
/// - `TextContent`, `ImageContent`, `AudioContent`, `ResourceLink`, `EmbeddedResource`.
///
/// The same union is used by `CallTool.Result.content` and
/// `Prompt.Message.content`. Sampling messages use a separate
/// `Sampling.Message.ContentBlock` whose case set additionally includes
/// `toolUse` and `toolResult`.
public enum ContentBlock: Hashable, Codable, Sendable {
    /// Text content
    case text(String, annotations: Annotations?, _meta: [String: Value]?)
    /// Image content
    case image(data: String, mimeType: String, annotations: Annotations?, _meta: [String: Value]?)
    /// Audio content
    case audio(data: String, mimeType: String, annotations: Annotations?, _meta: [String: Value]?)
    /// Embedded resource content (includes actual content)
    case resource(resource: Resource.Content, annotations: Annotations?, _meta: [String: Value]?)
    /// Resource link (reference to a resource that can be read)
    case resourceLink(ResourceLink)

    // MARK: - Convenience initializers

    /// Creates text content
    public static func text(_ text: String) -> ContentBlock {
        .text(text, annotations: nil, _meta: nil)
    }

    /// Creates image content
    public static func image(data: String, mimeType: String) -> ContentBlock {
        .image(data: data, mimeType: mimeType, annotations: nil, _meta: nil)
    }

    /// Creates audio content
    public static func audio(data: String, mimeType: String) -> ContentBlock {
        .audio(data: data, mimeType: mimeType, annotations: nil, _meta: nil)
    }

    /// Creates embedded resource content with text
    public static func resource(uri: String, mimeType: String? = nil, text: String) -> ContentBlock {
        .resource(resource: .text(text, uri: uri, mimeType: mimeType), annotations: nil, _meta: nil)
    }

    /// Creates embedded resource content with binary data
    public static func resource(uri: String, mimeType: String? = nil, blob: Data) -> ContentBlock {
        .resource(resource: .binary(blob, uri: uri, mimeType: mimeType), annotations: nil, _meta: nil)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, resource, annotations, _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                let annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
                let meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
                self = .text(text, annotations: annotations, _meta: meta)
            case "image":
                let data = try container.decode(String.self, forKey: .data)
                let mimeType = try container.decode(String.self, forKey: .mimeType)
                let annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
                let meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
                self = .image(data: data, mimeType: mimeType, annotations: annotations, _meta: meta)
            case "audio":
                let data = try container.decode(String.self, forKey: .data)
                let mimeType = try container.decode(String.self, forKey: .mimeType)
                let annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
                let meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
                self = .audio(data: data, mimeType: mimeType, annotations: annotations, _meta: meta)
            case "resource":
                let resourceContent = try container.decode(Resource.Content.self, forKey: .resource)
                let annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
                let meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
                self = .resource(resource: resourceContent, annotations: annotations, _meta: meta)
            case "resource_link":
                let link = try ResourceLink(from: decoder)
                self = .resourceLink(link)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container, debugDescription: "Unknown content block type: \(type)",
                )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
            case let .text(text, annotations, meta):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(meta, forKey: ._meta)
            case let .image(data, mimeType, annotations, meta):
                try container.encode("image", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(mimeType, forKey: .mimeType)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(meta, forKey: ._meta)
            case let .audio(data, mimeType, annotations, meta):
                try container.encode("audio", forKey: .type)
                try container.encode(data, forKey: .data)
                try container.encode(mimeType, forKey: .mimeType)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(meta, forKey: ._meta)
            case let .resource(resourceContent, annotations, meta):
                try container.encode("resource", forKey: .type)
                try container.encode(resourceContent, forKey: .resource)
                try container.encodeIfPresent(annotations, forKey: .annotations)
                try container.encodeIfPresent(meta, forKey: ._meta)
            case let .resourceLink(link):
                try link.encode(to: encoder)
        }
    }
}

// MARK: - ExpressibleByStringLiteral

extension ContentBlock: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(value, annotations: nil, _meta: nil)
    }
}

// MARK: - ExpressibleByStringInterpolation

extension ContentBlock: ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) {
        self = .text(String(stringInterpolation: stringInterpolation), annotations: nil, _meta: nil)
    }
}
