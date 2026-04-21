// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCP
@testable import MCPCore
import MCPTool
import Testing

// MARK: - Fixtures

/// Metadata type used to pin down that rich `ToolError` results survive the
/// server-side output-schema validation guard at `MCPServer.swift:362-369`
/// even when the tool has a declared `outputSchema`.
@Schemable
@StructuredOutput
struct ToolErrorStructuredOutput {
    let ok: Bool
}

/// Multi-block `ToolError` conformer. Carries a `.text` description plus an
/// `.image` block to exercise the verbatim-passthrough guarantee.
private struct RichToolError: ToolError {
    let message: String
    let imageData: Data

    var content: [ContentBlock] {
        [
            .text(message, annotations: nil, _meta: nil),
            .image(
                data: imageData.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil,
            ),
        ]
    }
}

/// Plain `LocalizedError` that is **not** a `ToolError`. The server should
/// surface `errorDescription` as a single `.text` block with no rich content.
private struct PlainLocalizedError: LocalizedError {
    let errorDescription: String?
}

/// `LocalizedError` that only populates `failureReason`, not
/// `errorDescription`. Foundation still composes a useful
/// `localizedDescription` by concatenating the generic domain stub with the
/// reason text — `errorMessage(_:)` must read `localizedDescription` rather
/// than short-circuiting on `errorDescription` so the reason reaches the
/// agent on the wire.
private struct FailureReasonOnlyError: LocalizedError {
    let reason: String
    var failureReason: String? {
        reason
    }
}

/// Plain `Error` whose `localizedDescription` hits Foundation's default
/// "The operation couldn't be completed" sentinel. The server's
/// `errorMessage(_:)` fallback must kick in and produce a meaningful string.
private struct FoundationSentinelError: Error {
    let tag: String
}

private struct ToolErrorValueArgs: Codable {
    let value: Double
}

/// A `ToolError` conformer that supplies its own `errorDescription`. The
/// override should take precedence over the protocol-extension default that
/// joins `.text` blocks — a contract Swift guarantees mechanically via
/// standard protocol-witness resolution.
private struct CustomDescriptionToolError: ToolError {
    let content: [ContentBlock]
    let errorDescription: String?
}

/// A `ToolError` whose content carries no `.text` blocks. Exercises the
/// default-extension fallback path that returns the conforming type's name
/// so `Error.localizedDescription` bridging still yields something
/// actionable for logs and non-MCP consumers.
private struct ImageOnlyToolError: ToolError {
    let imageData: Data

    var content: [ContentBlock] {
        [.image(
            data: imageData.base64EncodedString(),
            mimeType: "image/png",
            annotations: nil,
            _meta: nil,
        )]
    }
}

// MARK: - Tests

struct ToolErrorIntegrationTests {
    /// Rich `ToolError` through a full `Client` ↔ `Server` round trip.
    ///
    /// The tool's declared output type is a `@Schemable @StructuredOutput`
    /// struct so it publishes an `outputSchema`. This exercises three
    /// invariants at once:
    ///   1. The `toolError(_ error: Error)` dispatcher surfaces the
    ///      conformer's `content` verbatim with `isError: true` and no
    ///      `structuredContent`.
    ///   2. The server-side guard at `MCPServer.swift:362-369` correctly
    ///      bypasses output-schema validation because `isError == true`.
    ///   3. The client-side guard at `Client+ProtocolMethods.swift:195-203`
    ///      applies the same `!(result.isError ?? false)` bypass. This only
    ///      runs when the schema cache is populated, so the test calls
    ///      `listTools()` before `callTool(...)`.
    @Test
    func `Rich ToolError survives client and server validation guards`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        try await mcpServer.register(
            name: "fail_with_rich_content",
            description: "Always throws a rich ToolError",
        ) { (_: HandlerContext) async throws -> ToolErrorStructuredOutput in
            throw RichToolError(message: "render failed", imageData: pngHeader)
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Populate the client-side output-schema cache so the client guard
        // at Client+ProtocolMethods.swift:195-203 actually runs.
        _ = try await client.listTools()

        let result = try await client.callTool(name: "fail_with_rich_content")

        #expect(result.isError == true)
        #expect(result.structuredContent == nil)

        // content is passed through verbatim by the dispatcher.
        #expect(result.content.count == 2)
        if case let .text(text, _, _) = result.content[0] {
            #expect(text == "render failed")
        } else {
            Issue.record("expected text block at index 0, got \(result.content[0])")
        }
        if case let .image(data, mimeType, _, _) = result.content[1] {
            #expect(data == pngHeader.base64EncodedString())
            #expect(mimeType == "image/png")
        } else {
            Issue.record("expected image block at index 1, got \(result.content[1])")
        }

        // Default `errorDescription` extension joins the `.text` blocks. Pinned
        // here so a future refactor that moves the default into a macro or
        // synthesizes it elsewhere can't silently regress the contract.
        let rich = RichToolError(message: "render failed", imageData: pngHeader)
        #expect((rich as Error).localizedDescription == "render failed")
    }

    /// A plain `LocalizedError` (not a `ToolError`) surfaces its
    /// `errorDescription` as a single `.text` block.
    @Test
    func `Plain LocalizedError yields a single text block`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        try await mcpServer.register(
            name: "fail_plain",
            description: "Throws a plain LocalizedError",
        ) { (_: HandlerContext) async throws -> String in
            throw PlainLocalizedError(errorDescription: "something went wrong")
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "fail_plain")

        #expect(result.isError == true)
        #expect(result.content.count == 1)
        if case let .text(text, _, _) = result.content.first {
            #expect(text == "something went wrong")
        } else {
            Issue.record("expected text block, got \(String(describing: result.content.first))")
        }
    }

    /// A `LocalizedError` that only populates `failureReason` still gets a
    /// useful `localizedDescription` from Foundation (the generic stub
    /// concatenated with the reason). `errorMessage(_:)` must surface that
    /// full string, not short-circuit on `errorDescription == nil` and fall
    /// back to `String(describing:)`, which would drop the reason text.
    @Test
    func `LocalizedError with only failureReason surfaces the reason on the wire`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        try await mcpServer.register(
            name: "fail_reason_only",
            description: "Throws a LocalizedError that only populates failureReason",
        ) { (_: HandlerContext) async throws -> String in
            throw FailureReasonOnlyError(reason: "disk quota exceeded")
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "fail_reason_only")

        #expect(result.isError == true)
        guard case let .text(text, _, _) = result.content.first else {
            Issue.record("expected text block, got \(String(describing: result.content.first))")
            return
        }
        // The reason text must appear in the wire message. Asserting the
        // full string would pin Foundation's locale-dependent stub prefix,
        // which this helper is meant to be independent of.
        #expect(text.contains("disk quota exceeded"))
        // Regression guard: the helper must not drop to `String(describing:)`
        // for LocalizedError conformers, which would emit `FailureReasonOnlyError(…)`
        // and lose the composed reason.
        #expect(!text.contains("FailureReasonOnlyError("))
    }

    /// A plain `Error` (not a `LocalizedError`) must produce a meaningful
    /// wire message regardless of the host's locale. The `errorMessage(_:)`
    /// helper at `MCPServer.swift` checks `LocalizedError` conformance
    /// explicitly rather than string-matching Foundation's locale-dependent
    /// stub (`"The operation couldn't be completed"` on en-US, translated
    /// variants elsewhere), so it falls back to `String(describing:)` for
    /// any plain `Error` — giving the agent the type name plus any stored
    /// property values to work with.
    @Test
    func `Foundation sentinel error falls back to String(describing:)`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        try await mcpServer.register(
            name: "fail_sentinel",
            description: "Throws a plain Error with Foundation sentinel localizedDescription",
        ) { (_: HandlerContext) async throws -> String in
            throw FoundationSentinelError(tag: "marker-42")
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "fail_sentinel")

        #expect(result.isError == true)
        guard case let .text(text, _, _) = result.content.first else {
            Issue.record("expected text block, got \(String(describing: result.content.first))")
            return
        }
        // `String(describing:)` of the struct includes the type name and the
        // `tag` field value — either substring proves the fallback fired.
        #expect(text.contains("FoundationSentinelError"))
        #expect(text.contains("marker-42"))
        // Regression sentinel: the Foundation stub must not be surfaced.
        #expect(!text.contains("operation couldn't be completed"))
        #expect(!text.contains("operation couldn\u{2019}t be completed"))
    }

    /// The input-validation catch site still prepends `"Input validation error: "`
    /// so the wrapping layer's context is preserved. This prefix is load-bearing
    /// — regressing to `toolError(error)` on this path would strip it.
    @Test
    func `Input validation errors retain Input validation error prefix`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        try await mcpServer.register(
            name: "needs_value",
            description: "Tool with a required argument",
            inputSchema: [
                "type": "object",
                "properties": [
                    "value": ["type": "number"],
                ],
                "required": ["value"],
            ],
        ) { (_: ToolErrorValueArgs, _: HandlerContext) in
            "ok"
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let result = try await client.callTool(name: "needs_value", arguments: [:])

        #expect(result.isError == true)
        guard case let .text(text, _, _) = result.content.first else {
            Issue.record("expected text block, got \(String(describing: result.content.first))")
            return
        }
        #expect(text.hasPrefix("Input validation error:"))
    }

    /// A `ToolError` conformer providing its own `errorDescription` takes
    /// precedence over the protocol-extension default that joins `.text`
    /// blocks. Pins the contract at `ToolError.swift`'s extension-vs-witness
    /// resolution so it can't regress if someone ever synthesizes a default
    /// inside the macro layer.
    @Test
    func `Conformer supplied errorDescription takes precedence over joined text blocks`() {
        let error = CustomDescriptionToolError(
            content: [
                .text("block one", annotations: nil, _meta: nil),
                .text("block two", annotations: nil, _meta: nil),
            ],
            errorDescription: "conformer wins",
        )

        #expect((error as Error).localizedDescription == "conformer wins")
        #expect(error.errorDescription == "conformer wins")
    }

    /// A `ToolError` whose `content` carries only non-text blocks must still
    /// produce a non-`nil` `errorDescription`. The default extension falls
    /// back to the conforming type's name so `Error.localizedDescription`
    /// bridging doesn't collapse to Foundation's generic "operation couldn't
    /// be completed" stub for logs and non-MCP consumers.
    @Test
    func `ToolError without text blocks falls back to type name`() {
        let error = ImageOnlyToolError(imageData: Data([0x89, 0x50, 0x4E, 0x47]))

        #expect(error.errorDescription == "ImageOnlyToolError")
        #expect((error as Error).localizedDescription == "ImageOnlyToolError")
    }
}
