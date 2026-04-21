// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCPCore
import MCPTool
import Testing

// MARK: - Fixtures

/// Representative media metadata exercising required numeric fields, an
/// optional `file_path` (for the saved-to-disk path), and `CodingKeys`
/// renaming for wire compatibility.
@Schemable
@StructuredOutput
struct MediaTestScreenshotMetadata: Equatable, Decodable {
    let width: Int
    let height: Int
    let displayID: Int
    let filePath: String?

    enum CodingKeys: String, CodingKey {
        case width, height
        case displayID = "display_id"
        case filePath = "file_path"
    }
}

// Distinct metadata types used to exercise generic-parameter dispatch in
// `MCPSchema.outputSchema(for:)`. Must be file-scoped so the `@StructuredOutput`
// extension macro can attach.
@Schemable
@StructuredOutput
struct MediaTestAlphaMetadata { let a: Int }

@Schemable
@StructuredOutput
struct MediaTestBetaMetadata { let b: String }

// MARK: - Helpers

/// Decodes metadata from the stringified JSON in `content[0].text`.
/// Used by both-path tests to confirm the text mirrors the structured form.
private func decodeMetadata<T: Decodable>(
    _ type: T.Type,
    from content: [ContentBlock],
) throws -> T {
    guard let first = content.first, case let .text(text, _, _) = first else {
        throw MCPError.internalError("content[0] is not text")
    }
    return try JSONDecoder().decode(type, from: Data(text.utf8))
}

/// Returns the raw text bytes of `content[0]` for byte-equivalence checks.
private func content0Bytes(_ content: [ContentBlock]) throws -> Data {
    guard let first = content.first, case let .text(text, _, _) = first else {
        throw MCPError.internalError("content[0] is not text")
    }
    return Data(text.utf8)
}

// MARK: - Tests

struct MediaWithMetadataIntegrationTests {
    // MARK: Schema recovery

    @Test
    func `MCPSchema.outputSchema(for:) unwraps MediaWithMetadata<Metadata>`() throws {
        let schema = MCPSchema.outputSchema(for: MediaWithMetadata<MediaTestScreenshotMetadata>.self)
        let obj = try #require(schema?.objectValue)

        // The schema of the media result *is* the schema of its metadata —
        // binary blocks live in the Content array, not in structuredContent.
        #expect(obj["type"]?.stringValue == "object")
        let properties = try #require(obj["properties"]?.objectValue)
        #expect(properties["width"] != nil)
        #expect(properties["height"] != nil)
        #expect(properties["display_id"] != nil)
        #expect(properties["file_path"] != nil)

        // L1 post-processing guarantee: every property is required, even
        // `file_path` (which is optional on the Swift side and nullable on
        // the wire).
        let required = try #require(obj["required"]?.arrayValue)
        let names = Set(required.compactMap(\.stringValue))
        #expect(names == ["width", "height", "display_id", "file_path"])

        // `file_path` is typed as a nullable union so the wire always
        // carries the key.
        let filePathType = properties["file_path"]?.objectValue?["type"]?.arrayValue?
            .compactMap(\.stringValue)
        #expect(filePathType == ["string", "null"])
    }

    // MARK: Inline-binary path

    @Test
    func `Inline binary path wraps metadata + image content`() throws {
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG header
        let metadata = MediaTestScreenshotMetadata(
            width: 1920,
            height: 1080,
            displayID: 1,
            filePath: nil,
        )
        let value = MediaWithMetadata<MediaTestScreenshotMetadata>(
            .image(data: imageBytes, mimeType: "image/png"),
            metadata: metadata,
        )

        let result = try value.toCallToolResult()

        // content[0] is the stringified metadata; image follows.
        #expect(result.content.count == 2)
        let decoded = try decodeMetadata(MediaTestScreenshotMetadata.self, from: result.content)
        #expect(decoded == metadata)

        // structuredContent echoes the same metadata.
        let structured = try #require(result.structuredContent)
        #expect(structured.objectValue?["width"] == .int(1920))
        #expect(structured.objectValue?["display_id"] == .int(1))
        #expect(structured.objectValue?["file_path"] == .null)

        // Second content element is the image block.
        switch result.content[1] {
            case let .image(data, mimeType, _, _):
                #expect(data == imageBytes.base64EncodedString())
                #expect(mimeType == "image/png")
            default:
                Issue.record("expected image content, got \(result.content[1])")
        }
    }

    // MARK: Saved-to-disk path

    @Test
    func `Saved-to-disk path reports file_path in metadata`() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("mediaresult-\(UUID().uuidString).png")
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try imageBytes.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let metadata = MediaTestScreenshotMetadata(
            width: 1920,
            height: 1080,
            displayID: 1,
            filePath: tempFile.path,
        )
        let value = MediaWithMetadata<MediaTestScreenshotMetadata>(
            .image(data: imageBytes, mimeType: "image/png"),
            metadata: metadata,
        )

        let result = try value.toCallToolResult()

        // Metadata round-trips through content[0] with the non-null file_path.
        let decoded = try decodeMetadata(MediaTestScreenshotMetadata.self, from: result.content)
        #expect(decoded == metadata)
        #expect(decoded.filePath == tempFile.path)

        // structuredContent also carries the path (same source).
        let structured = try #require(result.structuredContent)
        #expect(structured.objectValue?["file_path"] == .string(tempFile.path))

        // The file on disk holds the bytes that would otherwise have been
        // inline — test that the bytes-to-path mapping is honored by the
        // caller, not by MediaWithMetadata itself.
        let diskBytes = try Data(contentsOf: tempFile)
        #expect(diskBytes == imageBytes)
    }

    // MARK: Byte-equivalence invariant

    @Test
    func `content[0].text bytes equal Metadata.encoder.encode(structured)`() throws {
        // The wire contract: text and structuredContent must represent the
        // same payload under the chosen encoder. Without this invariant,
        // clients that only read one field would see a different shape from
        // clients that read the other — subtle and hard to debug.
        let metadata = MediaTestScreenshotMetadata(
            width: 2560,
            height: 1440,
            displayID: 2,
            filePath: nil,
        )
        let value = MediaWithMetadata<MediaTestScreenshotMetadata>(
            [],
            metadata: metadata,
        )
        let result = try value.toCallToolResult()

        let textBytes = try content0Bytes(result.content)
        let encodedDirectly = try MediaTestScreenshotMetadata.encoder.encode(metadata)
        #expect(textBytes == encodedDirectly)
    }

    // MARK: Sendable / generic sanity

    @Test
    func `MediaWithMetadata preserves generic parameter for outputSchema dispatch`() {
        // Two different metadata types produce different schemas. This is the
        // whole point of the generic wrapper — `any StructuredMetadataCarrier.Type`
        // would collapse both, but the generic `.Type` references keep them
        // distinct.
        let aSchema = MCPSchema.outputSchema(for: MediaWithMetadata<MediaTestAlphaMetadata>.self)
        let bSchema = MCPSchema.outputSchema(for: MediaWithMetadata<MediaTestBetaMetadata>.self)

        let aProps = aSchema?.objectValue?["properties"]?.objectValue
        let bProps = bSchema?.objectValue?["properties"]?.objectValue
        #expect(aProps?["a"] != nil)
        #expect(aProps?["b"] == nil)
        #expect(bProps?["b"] != nil)
        #expect(bProps?["a"] == nil)
    }

    // MARK: Schema / wire parity

    /// Validates the emitted `structuredContent` against the emitted schema
    /// using the same validator the server uses at `CallTool` time. This is
    /// the seam that matters: schema derivation and wire encoding each work
    /// on their own, but a bug in either would only surface where the server
    /// confronts them with one another. Both the `filePath: nil` and
    /// `filePath: "..."` branches are validated to cover the required +
    /// nullable-union wire contract.
    @Test
    func `Server validator accepts MediaWithMetadata structuredContent against derived schema`() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema = try #require(
            MCPSchema.outputSchema(for: MediaWithMetadata<MediaTestScreenshotMetadata>.self),
        )

        for filePath in [nil, "/tmp/screenshot.png"] as [String?] {
            let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])
            let value = MediaWithMetadata<MediaTestScreenshotMetadata>(
                .image(data: imageBytes, mimeType: "image/png"),
                metadata: MediaTestScreenshotMetadata(
                    width: 1920,
                    height: 1080,
                    displayID: 1,
                    filePath: filePath,
                ),
            )

            let result = try value.toCallToolResult()
            let structured = try #require(result.structuredContent)

            // The server would throw `MCPError.invalidParams` here if the
            // wire shape didn't match the schema — e.g. missing key, absent
            // instead of nullable, or wrong type.
            try validator.validate(structured, against: schema)
        }
    }
}
