// Copyright © Anthony DePasquale

import Foundation
import Testing

@testable import MCP

/// Tests that the server sanitizes errors from resource and prompt handlers
/// before sending them to clients, preventing leakage of sensitive information.
@Suite("Error Sanitization Tests")
struct ErrorSanitizationTests {
    /// Set up an MCPServer with a connected client for testing error responses.
    private func makeConnectedPair() async throws -> (MCPServer, Client) {
        let mcpServer = MCPServer(name: "TestServer", version: "1.0")
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)

        let client = Client(name: "TestClient", version: "1.0")
        _ = try await client.connect(transport: clientTransport)

        return (mcpServer, client)
    }

    // MARK: - Resource Error Sanitization

    @Test(
        "Resource provider throwing non-MCPError returns sanitized message",
        .timeLimit(.minutes(1))
    )
    func resourceNonMCPErrorSanitized() async throws {
        let (mcpServer, client) = try await makeConnectedPair()

        _ = try await mcpServer.registerResource(
            uri: "test://sensitive",
            name: "sensitive_resource"
        ) {
            throw URLError(.badServerResponse)
        }

        do {
            _ = try await client.readResource(uri: "test://sensitive")
            Issue.record("Should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.internalError)
            #expect(error.message == "Error reading resource test://sensitive")
        }

        await client.disconnect()
    }

    @Test(
        "Resource provider throwing MCPError with sensitive details returns sanitized message",
        .timeLimit(.minutes(1))
    )
    func resourceMCPErrorWithSensitiveDetailsSanitized() async throws {
        let (mcpServer, client) = try await makeConnectedPair()

        _ = try await mcpServer.registerResource(
            uri: "test://db-resource",
            name: "db_resource"
        ) {
            throw MCPError.internalError("Database connection failed: host=prod-db.internal:5432 user=admin password=secret123")
        }

        do {
            _ = try await client.readResource(uri: "test://db-resource")
            Issue.record("Should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.internalError)
            #expect(error.message == "Error reading resource test://db-resource")
            // Verify the sensitive details are NOT in the message
            #expect(!error.message.contains("prod-db"))
            #expect(!error.message.contains("password"))
        }

        await client.disconnect()
    }

    @Test(
        "Resource not found is forwarded unchanged",
        .timeLimit(.minutes(1))
    )
    func resourceNotFoundForwardedUnchanged() async throws {
        let (mcpServer, client) = try await makeConnectedPair()

        // Register a resource so the server has resource capability
        _ = try await mcpServer.registerResource(
            uri: "test://exists",
            name: "existing_resource"
        ) {
            .text("data", uri: "test://exists")
        }

        // Request a resource that doesn't exist
        do {
            _ = try await client.readResource(uri: "test://does-not-exist")
            Issue.record("Should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.resourceNotFound)
        }

        await client.disconnect()
    }

    @Test(
        "Disabled resource returns invalidParams unchanged",
        .timeLimit(.minutes(1))
    )
    func disabledResourceForwardedUnchanged() async throws {
        let (mcpServer, client) = try await makeConnectedPair()

        let resource = try await mcpServer.registerResource(
            uri: "test://disableable",
            name: "disableable_resource"
        ) {
            .text("data", uri: "test://disableable")
        }

        await resource.disable()

        do {
            _ = try await client.readResource(uri: "test://disableable")
            Issue.record("Should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.invalidParams)
            #expect(error.message.contains("disabled"))
        }

        await client.disconnect()
    }

    @Test(
        "Resource template provider error is sanitized",
        .timeLimit(.minutes(1))
    )
    func resourceTemplateErrorSanitized() async throws {
        let (mcpServer, client) = try await makeConnectedPair()

        _ = try await mcpServer.registerResourceTemplate(
            uriTemplate: "db://tables/{table}",
            name: "database_table"
        ) { _, variables in
            let table = variables["table"] ?? "unknown"
            throw MCPError.internalError("Access denied to table '\(table)' for user admin@prod-db.internal")
        }

        do {
            _ = try await client.readResource(uri: "db://tables/users")
            Issue.record("Should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.internalError)
            #expect(error.message == "Error reading resource db://tables/users")
            #expect(!error.message.contains("admin@prod-db"))
        }

        await client.disconnect()
    }

    // MARK: - Prompt Error Sanitization

    @Test(
        "Prompt handler throwing error returns sanitized message",
        .timeLimit(.minutes(1))
    )
    func promptHandlerErrorSanitized() async throws {
        let (mcpServer, client) = try await makeConnectedPair()

        _ = try await mcpServer.registerPrompt(
            name: "sensitive_prompt",
            description: "A prompt that fails"
        ) { _, _ in
            throw MCPError.internalError("API key sk-1234567890abcdef expired for tenant acme-corp")
        }

        do {
            _ = try await client.getPrompt(name: "sensitive_prompt")
            Issue.record("Should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.internalError)
            #expect(error.message == "Error getting prompt sensitive_prompt")
            #expect(!error.message.contains("sk-1234567890"))
            #expect(!error.message.contains("acme-corp"))
        }

        await client.disconnect()
    }

    @Test(
        "Prompt handler throwing non-MCPError returns sanitized message",
        .timeLimit(.minutes(1))
    )
    func promptNonMCPErrorSanitized() async throws {
        let (mcpServer, client) = try await makeConnectedPair()

        _ = try await mcpServer.registerPrompt(
            name: "failing_prompt",
            description: "A prompt that fails"
        ) { _, _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.getPrompt(name: "failing_prompt")
            Issue.record("Should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.internalError)
            #expect(error.message == "Error getting prompt failing_prompt")
        }

        await client.disconnect()
    }

    @Test(
        "Unknown prompt returns invalidParams unchanged",
        .timeLimit(.minutes(1))
    )
    func unknownPromptForwardedUnchanged() async throws {
        let (mcpServer, client) = try await makeConnectedPair()

        // Register a prompt so the server has prompt capability
        _ = try await mcpServer.registerPrompt(
            name: "existing_prompt"
        ) {
            [.user(.text("Hello"))]
        }

        do {
            _ = try await client.getPrompt(name: "nonexistent_prompt")
            Issue.record("Should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.invalidParams)
            #expect(error.message.contains("Unknown prompt"))
        }

        await client.disconnect()
    }

    @Test(
        "Disabled prompt returns invalidParams unchanged",
        .timeLimit(.minutes(1))
    )
    func disabledPromptForwardedUnchanged() async throws {
        let (mcpServer, client) = try await makeConnectedPair()

        let prompt = try await mcpServer.registerPrompt(
            name: "disabled_prompt"
        ) {
            [.user(.text("Hello"))]
        }

        await prompt.disable()

        do {
            _ = try await client.getPrompt(name: "disabled_prompt")
            Issue.record("Should have thrown")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.invalidParams)
            #expect(error.message.contains("disabled"))
        }

        await client.disconnect()
    }
}
