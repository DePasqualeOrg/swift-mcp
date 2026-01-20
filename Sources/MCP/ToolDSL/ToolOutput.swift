import Foundation

/// A type that can be returned from an MCP tool's `perform(context:)` method.
///
/// Built-in conformances include:
/// - `String` - For simple text responses (most common)
/// - `ImageOutput` - For image data
/// - `AudioOutput` - For audio data
/// - `MultiContent` - For multiple content items
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

// MARK: - String Conformance

extension String: ToolOutput {
    public func toCallToolResult() throws -> CallTool.Result {
        CallTool.Result(content: [.text(self)])
    }
}

// MARK: - Image Output

/// Output type for tools that return images.
///
/// Example:
/// ```swift
/// func perform() async throws -> ImageOutput {
///     let imageData = try await captureScreen()
///     return ImageOutput(pngData: imageData)
/// }
/// ```
public struct ImageOutput: ToolOutput, Sendable {
    /// The raw image data.
    public let data: Data

    /// The MIME type of the image (e.g., "image/png", "image/jpeg").
    public let mimeType: String

    /// Creates an image output with the specified data and MIME type.
    /// - Parameters:
    ///   - data: The raw image data.
    ///   - mimeType: The MIME type of the image.
    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    /// Creates an image output from PNG data.
    /// - Parameter pngData: The PNG image data.
    public init(pngData: Data) {
        self.init(data: pngData, mimeType: "image/png")
    }

    /// Creates an image output from JPEG data.
    /// - Parameter jpegData: The JPEG image data.
    public init(jpegData: Data) {
        self.init(data: jpegData, mimeType: "image/jpeg")
    }

    public func toCallToolResult() throws -> CallTool.Result {
        CallTool.Result(content: [.image(data: data.base64EncodedString(), mimeType: mimeType, annotations: nil, _meta: nil)])
    }
}

// MARK: - Audio Output

/// Output type for tools that return audio.
///
/// Example:
/// ```swift
/// func perform() async throws -> AudioOutput {
///     let audioData = try await synthesizeSpeech(text: text)
///     return AudioOutput(data: audioData, mimeType: "audio/mpeg")
/// }
/// ```
public struct AudioOutput: ToolOutput, Sendable {
    /// The raw audio data.
    public let data: Data

    /// The MIME type of the audio (e.g., "audio/mpeg", "audio/wav").
    public let mimeType: String

    /// Creates an audio output with the specified data and MIME type.
    /// - Parameters:
    ///   - data: The raw audio data.
    ///   - mimeType: The MIME type of the audio.
    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    public func toCallToolResult() throws -> CallTool.Result {
        CallTool.Result(content: [.audio(data: data.base64EncodedString(), mimeType: mimeType, annotations: nil, _meta: nil)])
    }
}

// MARK: - Multi-Content Output

/// Output type for tools that return multiple content items.
///
/// Example:
/// ```swift
/// func perform() async throws -> MultiContent {
///     MultiContent([
///         .text("Analysis complete"),
///         .image(data: chartData.base64EncodedString(), mimeType: "image/png", metadata: nil)
///     ])
/// }
/// ```
public struct MultiContent: ToolOutput, Sendable {
    /// The content items to return.
    public let items: [Tool.Content]

    /// Creates a multi-content output with the specified items.
    /// - Parameter items: The content items.
    public init(_ items: [Tool.Content]) {
        self.items = items
    }

    public func toCallToolResult() throws -> CallTool.Result {
        CallTool.Result(content: items)
    }
}

// MARK: - Structured Output

/// A tool output type that provides a JSON Schema for validation.
///
/// Conforming types can be validated against their schema by the server.
/// Use the `@OutputSchema` macro to automatically generate the schema
/// from an `Encodable` struct.
///
/// Example:
/// ```swift
/// @OutputSchema
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
public protocol StructuredOutput: ToolOutput, Encodable {
    /// The JSON Schema for this output type.
    static var schema: Value { get }
}

public extension StructuredOutput {
    /// Default implementation that encodes to JSON and includes structuredContent.
    func toCallToolResult() throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)

        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPError.internalError("Failed to encode output as UTF-8 string")
        }

        let structured = try JSONDecoder().decode(Value.self, from: data)

        return CallTool.Result(
            content: [.text(json)],
            structuredContent: structured
        )
    }
}

// MARK: - Schema Helper

/// Returns the JSON Schema for a type if it conforms to `StructuredOutput`, otherwise nil.
///
/// This function accepts `Any.Type` to perform a runtime conformance check.
/// The type erasure is intentional: it allows checking whether an output type
/// has a schema without knowing at compile time whether it conforms to
/// `StructuredOutput`.
public func outputSchema(for outputType: Any.Type) -> Value? {
    (outputType as? any StructuredOutput.Type)?.schema
}

// MARK: - OutputSchema Macro

/// Macro that generates `StructuredOutput` conformance for an `Encodable` struct.
///
/// The macro inspects the struct's properties and generates a JSON Schema
/// that describes the output structure.
///
/// Example:
/// ```swift
/// @OutputSchema
/// struct SearchResult: Sendable {
///     let items: [String]
///     let totalCount: Int
///     let hasMore: Bool
/// }
/// ```
///
/// This generates:
/// ```swift
/// extension SearchResult: StructuredOutput {
///     public static var schema: Value {
///         .object([
///             "type": .string("object"),
///             "properties": .object([
///                 "items": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
///                 "totalCount": .object(["type": .string("integer")]),
///                 "hasMore": .object(["type": .string("boolean")])
///             ]),
///             "required": .array([.string("items"), .string("totalCount"), .string("hasMore")])
///         ])
///     }
/// }
/// ```
@attached(extension, conformances: StructuredOutput)
@attached(member, names: named(schema))
public macro OutputSchema() = #externalMacro(module: "MCPMacros", type: "OutputSchemaMacro")
