// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
@testable import MCPCore
import MCPTool
import Testing

/// Integration tests for the baseline ``Media`` return type.
///
/// These tests pin the "baseline Media is the content channel only" invariant
/// – `content[]` carries the image/audio blocks; no `structuredContent` is
/// emitted and no `outputSchema` is published for the tool. A regression that
/// accidentally routed `Media` through the structured-metadata path would
/// fail here.
struct MediaIntegrationTests {
    /// Single-block `.image` round trip. Asserts base64 encoding, MIME type,
    /// `annotations` passthrough, and that no structured channel is populated.
    @Test
    func `Media with a single image block round trips through client and server`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let annotations = Annotations(audience: [.user, .assistant], priority: 0.5)

        try await mcpServer.register(
            name: "grab_image",
            description: "Returns a single image block",
        ) { (_: HandlerContext) async throws -> Media in
            Media(.image(data: pngBytes, mimeType: "image/png", annotations: annotations))
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Listing tools populates the client-side schema cache; used below
        // to assert `outputSchema == nil` for baseline Media.
        let tools = try await client.listTools()
        let toolDef = try #require(tools.tools.first { $0.name == "grab_image" })
        #expect(toolDef.outputSchema == nil)

        let result = try await client.callTool(name: "grab_image")

        #expect(result.isError != true)
        #expect(result.structuredContent == nil)
        #expect(result.content.count == 1)
        guard case let .image(data, mimeType, resultAnnotations, _) = result.content[0] else {
            Issue.record("expected image block, got \(result.content[0])")
            return
        }
        #expect(data == pngBytes.base64EncodedString())
        #expect(mimeType == "image/png")
        #expect(resultAnnotations == annotations)
    }

    /// Mixed `[.image, .audio]` block array preserves order, MIME types,
    /// and base64 encodings.
    @Test
    func `Media with mixed image and audio blocks preserves order`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let mp3Bytes = Data([0xFF, 0xFB, 0x90, 0x44])

        try await mcpServer.register(
            name: "image_and_audio",
            description: "Returns an image followed by audio",
        ) { (_: HandlerContext) async throws -> Media in
            Media([
                .image(data: pngBytes, mimeType: "image/png"),
                .audio(data: mp3Bytes, mimeType: "audio/mpeg"),
            ])
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let tools = try await client.listTools()
        let toolDef = try #require(tools.tools.first { $0.name == "image_and_audio" })
        #expect(toolDef.outputSchema == nil)

        let result = try await client.callTool(name: "image_and_audio")

        #expect(result.isError != true)
        #expect(result.structuredContent == nil)
        #expect(result.content.count == 2)

        guard case let .image(data0, mimeType0, _, _) = result.content[0] else {
            Issue.record("content[0] is not image: \(result.content[0])")
            return
        }
        #expect(data0 == pngBytes.base64EncodedString())
        #expect(mimeType0 == "image/png")

        guard case let .audio(data1, mimeType1, _, _) = result.content[1] else {
            Issue.record("content[1] is not audio: \(result.content[1])")
            return
        }
        #expect(data1 == mp3Bytes.base64EncodedString())
        #expect(mimeType1 == "audio/mpeg")
    }

    /// Direct conformance check: `Media.toCallToolResult()` emits blocks
    /// one-for-one with no structured channel. Catches regressions above
    /// the round-trip layer (e.g., if the server started synthesizing a
    /// metadata text block for baseline Media).
    @Test
    func `Media toCallToolResult emits content only`() throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let media = Media(.image(data: pngBytes, mimeType: "image/png"))

        let result = try media.toCallToolResult()
        #expect(result.content.count == 1)
        #expect(result.structuredContent == nil)
        #expect(result.isError == nil)
    }

    /// `MCPSchema.outputSchema(for: Media.self)` returns `nil` – baseline
    /// `Media` never publishes a schema.
    @Test
    func `MCPSchema outputSchema for Media is nil`() {
        #expect(MCPSchema.outputSchema(for: Media.self) == nil)
    }
}
