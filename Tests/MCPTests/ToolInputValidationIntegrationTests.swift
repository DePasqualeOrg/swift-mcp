// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
import Testing

/// Integration tests for server-side tool input validation.
///
/// These tests verify that the high-level MCPServer properly validates
/// tool inputs against their schemas before executing the tool handler.
/// Specific constraint validation (enum, length, range, etc.) is covered
/// by unit tests in JSONSchemaValidationTests.
struct ToolInputValidationIntegrationTests {
    @Test
    func `Valid tool call with correct arguments succeeds`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        try await mcpServer.register(
            name: "add",
            description: "Add two numbers",
            inputSchema: [
                "type": "object",
                "properties": [
                    "a": ["type": "number"],
                    "b": ["type": "number"],
                ],
                "required": ["a", "b"],
            ],
        ) { (args: AddArgs, _: HandlerContext) in
            String(args.a + args.b)
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let result = try await client.callTool(
            name: "add",
            arguments: ["a": .int(5), "b": .int(3)],
        )

        #expect(result.isError != true)
        #expect(result.content == [.text("8")])
    }

    @Test
    func `Missing required argument returns validation error`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        try await mcpServer.register(
            name: "add",
            description: "Add two numbers",
            inputSchema: [
                "type": "object",
                "properties": [
                    "a": ["type": "number"],
                    "b": ["type": "number"],
                ],
                "required": ["a", "b"],
            ],
        ) { (args: AddArgs, _: HandlerContext) in
            String(args.a + args.b)
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Per MCP spec, input validation errors are tool execution errors (isError: true),
        // not protocol errors. This allows LLMs to receive actionable feedback.
        let result = try await client.callTool(
            name: "add",
            arguments: ["a": .int(5)],
        )

        #expect(result.isError == true)
        if case let .text(text, _, _) = result.content.first {
            #expect(text.lowercased().contains("validation"))
        } else {
            Issue.record("Expected text content in error result")
        }
    }

    @Test
    func `Wrong argument type returns validation error`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        try await mcpServer.register(
            name: "add",
            description: "Add two numbers",
            inputSchema: [
                "type": "object",
                "properties": [
                    "a": ["type": "number"],
                    "b": ["type": "number"],
                ],
                "required": ["a", "b"],
            ],
        ) { (args: AddArgs, _: HandlerContext) in
            String(args.a + args.b)
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Per MCP spec, input validation errors are tool execution errors (isError: true),
        // not protocol errors. This allows LLMs to receive actionable feedback.
        let result = try await client.callTool(
            name: "add",
            arguments: ["a": .string("not a number"), "b": .int(3)],
        )

        #expect(result.isError == true)
        if case let .text(text, _, _) = result.content.first {
            #expect(text.lowercased().contains("validation"))
        } else {
            Issue.record("Expected text content in error result")
        }
    }

    @Test
    func `Tool handler is not called when validation fails`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        let handlerCalled = AtomicFlag()

        try await mcpServer.register(
            name: "guarded_tool",
            description: "Tool that tracks if handler was called",
            inputSchema: [
                "type": "object",
                "properties": [
                    "value": ["type": "number"],
                ],
                "required": ["value"],
            ],
        ) { (_: ValueArgs, _: HandlerContext) in
            handlerCalled.set()
            return "executed"
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Per MCP spec, input validation errors return isError: true (not thrown).
        // The key assertion here is that the handler is NOT called.
        let result = try await client.callTool(
            name: "guarded_tool",
            arguments: ["value": .string("not a number")],
        )

        #expect(result.isError == true)
        #expect(handlerCalled.isSet() == false)
    }
}

// MARK: - Helper Types

private struct AddArgs: Codable {
    let a: Int
    let b: Int
}

private struct ValueArgs: Codable {
    let value: Int
}

private final class AtomicFlag: @unchecked Sendable {
    private var _value: Bool = false
    private let lock = NSLock()

    func set() {
        lock.lock()
        defer { lock.unlock() }
        _value = true
    }

    func isSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}
