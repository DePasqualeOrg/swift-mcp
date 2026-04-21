// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCP
@testable import MCPCore
import MCPTool
import Testing

// MARK: - Fixtures

/// Metadata accompanying ``AssetWithMetadata`` fixtures. Includes a URI
/// field so code-mode consumers can recover the asset URI from
/// `structuredContent` without parsing `content[]`.
@Schemable
@StructuredOutput
struct AssetTestPDFMetadata: Equatable, Decodable {
    let uri: String
    let pageCount: Int
}

/// Distinct metadata type used to assert that `MCPSchema.outputSchema(for:)`
/// preserves the generic parameter across `AssetWithMetadata` instances.
@Schemable
@StructuredOutput
struct AssetTestReportMetadata: Equatable, Decodable {
    let title: String
}

// MARK: - Tests

struct AssetIntegrationTests {
    // MARK: - Baseline Asset

    /// Baseline `Asset` with an `.binary` block maps to
    /// `ContentBlock.resource(.binary(...))` with optional `mimeType`
    /// preserved and base64 encoding applied at the edge. No structured
    /// channel, no published schema.
    @Test
    func `Asset binary round trips through client and server`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        let pdfBytes = Data([0x25, 0x50, 0x44, 0x46]) // "%PDF"

        try await mcpServer.register(
            name: "grab_pdf",
            description: "Returns a PDF asset block",
        ) { (_: HandlerContext) async throws -> Asset in
            Asset(
                .binary(
                    pdfBytes,
                    uri: "file:///tmp/test.pdf",
                    mimeType: "application/pdf",
                ),
            )
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let tools = try await client.listTools()
        let toolDef = try #require(tools.tools.first { $0.name == "grab_pdf" })
        #expect(toolDef.outputSchema == nil)

        let result = try await client.callTool(name: "grab_pdf")
        #expect(result.isError != true)
        #expect(result.structuredContent == nil)
        #expect(result.content.count == 1)

        guard case let .resource(resource, _, _) = result.content[0] else {
            Issue.record("expected resource content, got \(result.content[0])")
            return
        }
        #expect(resource.uri == "file:///tmp/test.pdf")
        #expect(resource.mimeType == "application/pdf")
        #expect(resource.blob == pdfBytes.base64EncodedString())
        #expect(resource.text == nil)
    }

    /// Baseline `Asset` with `.text` maps to
    /// `ContentBlock.resource(.text(...))` with `mimeType` optional.
    @Test
    func `Asset text round trips through client and server`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        try await mcpServer.register(
            name: "grab_markdown",
            description: "Returns an embedded text asset",
        ) { (_: HandlerContext) async throws -> Asset in
            Asset(
                .text(
                    "# Report\nContents",
                    uri: "file:///tmp/test.md",
                    mimeType: "text/markdown",
                ),
            )
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "grab_markdown")
        #expect(result.isError != true)
        #expect(result.content.count == 1)

        guard case let .resource(resource, _, _) = result.content[0] else {
            Issue.record("expected resource content, got \(result.content[0])")
            return
        }
        #expect(resource.uri == "file:///tmp/test.md")
        #expect(resource.mimeType == "text/markdown")
        #expect(resource.text == "# Report\nContents")
        #expect(resource.blob == nil)
    }

    /// `.link` maps to `ContentBlock.resourceLink(...)` preserving the full
    /// `ResourceLink` field set (`title`, `size`, `icons`, `description`,
    /// `mimeType`, `annotations`) minus `_meta`.
    @Test
    func `Asset link preserves all optional fields through the wire`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        let icons = [Icon(src: "https://example.com/icon.png")]
        let annotations = Annotations(audience: [.user], priority: 0.8)

        try await mcpServer.register(
            name: "grab_link",
            description: "Returns a resource-link asset",
        ) { (_: HandlerContext) async throws -> Asset in
            Asset(
                .link(
                    "https://example.com/report.pdf",
                    name: "report_pdf",
                    title: "Quarterly Report",
                    description: "Q4 financial summary",
                    mimeType: "application/pdf",
                    size: 12345,
                    icons: icons,
                    annotations: annotations,
                ),
            )
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "grab_link")
        #expect(result.content.count == 1)

        guard case let .resourceLink(link) = result.content[0] else {
            Issue.record("expected resource link, got \(result.content[0])")
            return
        }
        #expect(link.uri == "https://example.com/report.pdf")
        #expect(link.name == "report_pdf")
        #expect(link.title == "Quarterly Report")
        #expect(link.description == "Q4 financial summary")
        #expect(link.mimeType == "application/pdf")
        #expect(link.size == 12345)
        #expect(link.icons == icons)
        #expect(link.annotations == annotations)
    }

    /// Baseline `Asset` publishes no schema on the registered tool: three
    /// block types, one assertion each, to pin down the "Asset is content
    /// channel only" invariant.
    @Test
    func `MCPSchema outputSchema for Asset is nil`() {
        #expect(MCPSchema.outputSchema(for: Asset.self) == nil)
    }

    // MARK: - AssetWithMetadata

    /// `AssetWithMetadata<T>` populates `structuredContent`, prepends a
    /// metadata `.text` block, and publishes `outputSchema` via the
    /// `StructuredMetadataCarrier` dispatch added for this commit. This
    /// test exercises the full round trip; a regression in the marker
    /// dispatch would silently ship a tool with no schema, which the
    /// `toolDef.outputSchema == nil` check would catch.
    @Test
    func `AssetWithMetadata round trip populates structured channel and schema`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        let pdfBytes = Data([0x25, 0x50, 0x44, 0x46])
        let metadata = AssetTestPDFMetadata(uri: "file:///tmp/report-42.pdf", pageCount: 7)

        try await mcpServer.register(
            name: "generate_pdf",
            description: "Returns a PDF with typed metadata",
        ) { (_: HandlerContext) async throws -> AssetWithMetadata<AssetTestPDFMetadata> in
            AssetWithMetadata(
                .binary(
                    pdfBytes,
                    uri: metadata.uri,
                    mimeType: "application/pdf",
                ),

                metadata: metadata,
            )
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let tools = try await client.listTools()
        let toolDef = try #require(tools.tools.first { $0.name == "generate_pdf" })

        // outputSchema must be non-nil to prove the marker dispatch reached
        // AssetWithMetadata. Without this, the tool would still work but
        // its schema wouldn't reach code-mode consumers.
        let schema = try #require(toolDef.outputSchema)
        let properties = try #require(schema.objectValue?["properties"]?.objectValue)
        #expect(properties["uri"] != nil)
        #expect(properties["pageCount"] != nil)

        let result = try await client.callTool(name: "generate_pdf")
        #expect(result.isError != true)
        #expect(result.content.count == 2)

        // content[0] is the prepended metadata text block; decoding it
        // must recover the metadata value round-trip.
        guard case let .text(json, _, _) = result.content[0] else {
            Issue.record("expected text block at index 0, got \(result.content[0])")
            return
        }
        let decoded = try JSONDecoder().decode(AssetTestPDFMetadata.self, from: Data(json.utf8))
        #expect(decoded == metadata)

        // content[1] is the asset block itself.
        guard case let .resource(resource, _, _) = result.content[1] else {
            Issue.record("expected resource content at index 1, got \(result.content[1])")
            return
        }
        #expect(resource.uri == metadata.uri)
        #expect(resource.blob == pdfBytes.base64EncodedString())

        // structuredContent carries the same metadata.
        let structured = try #require(result.structuredContent)
        #expect(structured.objectValue?["uri"] == .string(metadata.uri))
        #expect(structured.objectValue?["pageCount"] == .int(metadata.pageCount))
    }

    /// `MCPSchema.outputSchema(for:)` resolves distinct schemas for two
    /// different `AssetWithMetadata` instantiations, proving the marker
    /// dispatch preserves the generic parameter.
    @Test
    func `AssetWithMetadata preserves generic parameter for outputSchema dispatch`() {
        let pdfSchema = MCPSchema.outputSchema(for: AssetWithMetadata<AssetTestPDFMetadata>.self)
        let reportSchema = MCPSchema.outputSchema(for: AssetWithMetadata<AssetTestReportMetadata>.self)

        let pdfProps = pdfSchema?.objectValue?["properties"]?.objectValue
        let reportProps = reportSchema?.objectValue?["properties"]?.objectValue
        #expect(pdfProps?["uri"] != nil)
        #expect(pdfProps?["title"] == nil)
        #expect(reportProps?["title"] != nil)
        #expect(reportProps?["uri"] == nil)
    }
}
