// Copyright © Anthony DePasquale

import Foundation
import Testing

@testable import MCP

@Suite("MCPServer Tests")
struct MCPServerTests {
    // MARK: - Tool Registration Tests

    @Test("Register closure-based tool and list it")
    func registerClosureTool() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        struct EchoArgs: Codable, Sendable {
            let message: String
        }

        let inputSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "message": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("message")]),
        ])

        let tool = try await server.register(
            name: "echo",
            description: "Echo a message",
            inputSchema: inputSchema
        ) { (args: EchoArgs, _: HandlerContext) in
            args.message
        }

        #expect(tool.name == "echo")

        let definitions = await server.toolRegistry.definitions
        #expect(definitions.count == 1)
        #expect(definitions.first?.name == "echo")
        #expect(definitions.first?.description == "Echo a message")
    }

    @Test("Register tool with no input parameters")
    func registerNoInputTool() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let tool = try await server.register(
            name: "get_time",
            description: "Get current time"
        ) { (_: HandlerContext) in
            "2024-01-01T00:00:00Z"
        }

        #expect(tool.name == "get_time")

        let definitions = await server.toolRegistry.definitions
        #expect(definitions.count == 1)
    }

    @Test("Enable and disable tool")
    func enableDisableTool() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let tool = try await server.register(
            name: "test_tool",
            description: "Test tool"
        ) { (_: HandlerContext) in
            "result"
        }

        #expect(await tool.isEnabled == true)

        await tool.disable()
        #expect(await tool.isEnabled == false)

        // Tool should not appear in definitions when disabled
        let definitions = await server.toolRegistry.definitions
        #expect(definitions.isEmpty)

        await tool.enable()
        #expect(await tool.isEnabled == true)

        // Tool should appear again
        let definitionsAfter = await server.toolRegistry.definitions
        #expect(definitionsAfter.count == 1)
    }

    @Test("Remove tool")
    func removeTool() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let tool = try await server.register(
            name: "temp_tool",
            description: "Temporary tool"
        ) { (_: HandlerContext) in
            "result"
        }

        #expect(await server.toolRegistry.hasTool("temp_tool") == true)

        await tool.remove()

        #expect(await server.toolRegistry.hasTool("temp_tool") == false)
    }

    @Test("Re-register tool after removal")
    func reRegisterToolAfterRemoval() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let tool = try await server.register(
            name: "reusable_tool",
            description: "First registration"
        ) { (_: HandlerContext) in
            "result 1"
        }

        #expect(tool.name == "reusable_tool")
        await tool.remove()
        #expect(await server.toolRegistry.hasTool("reusable_tool") == false)

        // Re-register with same name should succeed
        let tool2 = try await server.register(
            name: "reusable_tool",
            description: "Second registration"
        ) { (_: HandlerContext) in
            "result 2"
        }

        #expect(tool2.name == "reusable_tool")
        #expect(await server.toolRegistry.hasTool("reusable_tool") == true)

        let definitions = await server.toolRegistry.definitions
        #expect(definitions.first?.description == "Second registration")
    }

    // MARK: - Resource Registration Tests

    @Test("Register resource and read it")
    func registerResource() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let resource = try await server.registerResource(
            uri: "config://app",
            name: "app_config",
            description: "Application configuration"
        ) {
            .text("{\"debug\": true}", uri: "config://app")
        }

        #expect(resource.uri == "config://app")

        let resources = await server.resourceRegistry.listResources()
        #expect(resources.count == 1)
        #expect(resources.first?.name == "app_config")

        // Read the resource
        let contents = try await server.resourceRegistry.read(uri: "config://app")
        #expect(contents.text == "{\"debug\": true}")
    }

    @Test("Register resource template with URI matching")
    func registerResourceTemplate() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let template = try await server.registerResourceTemplate(
            uriTemplate: "file:///{path}",
            name: "file",
            description: "Read a file by path"
        ) { uri, variables in
            let path = variables["path"] ?? "unknown"
            return .text("Contents of \(path)", uri: uri)
        }

        #expect(template.uriTemplate == "file:///{path}")

        let templates = await server.resourceRegistry.listTemplates()
        #expect(templates.count == 1)
        #expect(templates.first?.name == "file")

        // Read via template
        let contents = try await server.resourceRegistry.read(uri: "file:///test.txt")
        #expect(contents.text == "Contents of test.txt")
    }

    @Test("Enable and disable resource")
    func enableDisableResource() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let resource = try await server.registerResource(
            uri: "test://resource",
            name: "test_resource"
        ) {
            .text("data", uri: "test://resource")
        }

        #expect(await resource.isEnabled == true)

        await resource.disable()
        #expect(await resource.isEnabled == false)

        // Resource should not appear in list when disabled
        let resources = await server.resourceRegistry.listResources()
        #expect(resources.isEmpty)

        await resource.enable()
        let resourcesAfter = await server.resourceRegistry.listResources()
        #expect(resourcesAfter.count == 1)
    }

    @Test("Read unknown resource throws error")
    func readUnknownResourceThrows() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        // Register one resource
        _ = try await server.registerResource(
            uri: "test://exists",
            name: "existing_resource"
        ) {
            .text("data", uri: "test://exists")
        }

        // Try to read a different, non-existent resource
        // Per MCP spec, unknown resources should return error code -32002
        do {
            _ = try await server.resourceRegistry.read(uri: "test://does-not-exist")
            Issue.record("Expected resourceNotFound error")
        } catch let error as MCPError {
            #expect(error.code == ErrorCode.resourceNotFound)
        }
    }

    @Test("Read disabled resource throws error")
    func readDisabledResourceThrows() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let resource = try await server.registerResource(
            uri: "test://resource",
            name: "test_resource"
        ) {
            .text("secret data", uri: "test://resource")
        }

        // Verify we can read it initially
        let contents = try await server.resourceRegistry.read(uri: "test://resource")
        #expect(contents.text == "secret data")

        // Disable and verify read throws
        await resource.disable()

        await #expect(throws: MCPError.self) {
            _ = try await server.resourceRegistry.read(uri: "test://resource")
        }

        // Re-enable and verify read works again
        await resource.enable()
        let contentsAfter = try await server.resourceRegistry.read(uri: "test://resource")
        #expect(contentsAfter.text == "secret data")
    }

    @Test("Enable and disable resource template")
    func enableDisableResourceTemplate() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let template = try await server.registerResourceTemplate(
            uriTemplate: "users://{userId}/profile",
            name: "user_profile",
            description: "User profile data"
        ) { uri, variables in
            let userId = variables["userId"] ?? "unknown"
            return .text("Profile for user \(userId)", uri: uri)
        }

        #expect(await template.isEnabled == true)

        // Verify template works
        let contents = try await server.resourceRegistry.read(uri: "users://123/profile")
        #expect(contents.text == "Profile for user 123")

        // Disable template
        await template.disable()
        #expect(await template.isEnabled == false)

        // Template should not appear in list when disabled
        let templates = await server.resourceRegistry.listTemplates()
        #expect(templates.isEmpty)

        // Reading via disabled template should fail
        await #expect(throws: MCPError.self) {
            _ = try await server.resourceRegistry.read(uri: "users://456/profile")
        }

        // Re-enable and verify it works again
        await template.enable()
        let templatesAfter = await server.resourceRegistry.listTemplates()
        #expect(templatesAfter.count == 1)

        let contentsAfter = try await server.resourceRegistry.read(uri: "users://789/profile")
        #expect(contentsAfter.text == "Profile for user 789")
    }

    @Test("Remove resource template")
    func removeResourceTemplate() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let template = try await server.registerResourceTemplate(
            uriTemplate: "docs://{docId}",
            name: "document",
            description: "Document reader"
        ) { uri, variables in
            let docId = variables["docId"] ?? "unknown"
            return .text("Document \(docId)", uri: uri)
        }

        // Verify template exists and works
        let templates = await server.resourceRegistry.listTemplates()
        #expect(templates.count == 1)

        let contents = try await server.resourceRegistry.read(uri: "docs://abc")
        #expect(contents.text == "Document abc")

        // Remove template
        await template.remove()

        // Template should no longer exist
        let templatesAfter = await server.resourceRegistry.listTemplates()
        #expect(templatesAfter.isEmpty)

        // Reading via removed template should fail
        await #expect(throws: MCPError.self) {
            _ = try await server.resourceRegistry.read(uri: "docs://xyz")
        }
    }

    @Test("Re-register resource after removal")
    func reRegisterResourceAfterRemoval() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let resource = try await server.registerResource(
            uri: "config://app",
            name: "app_config"
        ) {
            .text("version 1", uri: "config://app")
        }

        // Verify initial registration
        let contents = try await server.resourceRegistry.read(uri: "config://app")
        #expect(contents.text == "version 1")

        // Remove resource
        await resource.remove()

        // Verify it's gone
        await #expect(throws: MCPError.self) {
            _ = try await server.resourceRegistry.read(uri: "config://app")
        }

        // Re-register with same URI
        let resource2 = try await server.registerResource(
            uri: "config://app",
            name: "app_config_v2"
        ) {
            .text("version 2", uri: "config://app")
        }

        #expect(resource2.uri == "config://app")

        // Verify new content
        let contentsAfter = try await server.resourceRegistry.read(uri: "config://app")
        #expect(contentsAfter.text == "version 2")

        // Verify new name in definition
        let resources = await server.resourceRegistry.listResources()
        #expect(resources.first?.name == "app_config_v2")
    }

    // MARK: - Prompt Registration Tests

    private func createMockContext() -> HandlerContext {
        let handlerContext = RequestHandlerContext(
            sessionId: "test-session",
            requestId: .number(1),
            _meta: nil,
            taskId: nil,
            authInfo: nil,
            requestInfo: nil,
            closeResponseStream: nil,
            closeNotificationStream: nil,
            sendNotification: { _ in },
            sendRequest: { _ in throw MCPError.internalError("Not implemented") },
            sendData: { _ in },
            shouldSendLogMessage: { _ in true }
        )
        return HandlerContext(handlerContext: handlerContext)
    }

    @Test("Register prompt with no arguments")
    func registerPromptNoArgs() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let prompt = try await server.registerPrompt(
            name: "greeting",
            description: "A friendly greeting"
        ) {
            [.user(.text("Hello! How can I help you?"))]
        }

        #expect(prompt.name == "greeting")

        let prompts = await server.promptRegistry.listPrompts()
        #expect(prompts.count == 1)
        #expect(prompts.first?.name == "greeting")

        // Get the prompt
        let context = createMockContext()
        let result = try await server.promptRegistry.getPrompt("greeting", arguments: nil, context: context)
        #expect(result.messages.count == 1)
    }

    @Test("Register prompt with arguments")
    func registerPromptWithArgs() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let prompt = try await server.registerPrompt(
            name: "personal_greeting",
            description: "A personalized greeting",
            arguments: [
                Prompt.Argument(name: "name", description: "Person's name", required: true),
            ]
        ) { args, _ in
            let name = args?["name"] ?? "Guest"
            return [.user(.text("Hello, \(name)!"))]
        }

        #expect(prompt.name == "personal_greeting")

        // Get the prompt with arguments
        let context = createMockContext()
        let result = try await server.promptRegistry.getPrompt(
            "personal_greeting",
            arguments: ["name": "Alice"],
            context: context
        )
        #expect(result.messages.count == 1)
    }

    @Test("Enable and disable prompt")
    func enableDisablePrompt() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        let prompt = try await server.registerPrompt(
            name: "test_prompt"
        ) {
            [.user(.text("Test"))]
        }

        #expect(await prompt.isEnabled == true)

        await prompt.disable()
        #expect(await prompt.isEnabled == false)

        // Prompt should not appear in list when disabled
        let prompts = await server.promptRegistry.listPrompts()
        #expect(prompts.isEmpty)

        await prompt.enable()
        let promptsAfter = await server.promptRegistry.listPrompts()
        #expect(promptsAfter.count == 1)
    }

    // MARK: - Server Capabilities Tests

    @Test("Capabilities are set when registering tools")
    func capabilitiesSetOnToolRegistration() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        // Session without tools has no tools capability
        let sessionWithoutTools = await mcpServer.createSession()
        let initialCaps = await sessionWithoutTools.capabilities
        #expect(initialCaps.tools == nil)

        // Register a tool
        _ = try await mcpServer.register(
            name: "test",
            description: "Test"
        ) { (_: HandlerContext) in
            "result"
        }

        // New session should have tools capability
        let sessionWithTools = await mcpServer.createSession()
        let caps = await sessionWithTools.capabilities
        #expect(caps.tools?.listChanged == true)
    }

    @Test("Capabilities are set when registering resources")
    func capabilitiesSetOnResourceRegistration() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        _ = try await mcpServer.registerResource(
            uri: "test://resource",
            name: "test"
        ) {
            .text("data", uri: "test://resource")
        }

        let session = await mcpServer.createSession()
        let caps = await session.capabilities
        #expect(caps.resources?.listChanged == true)
    }

    @Test("Capabilities are set when registering prompts")
    func capabilitiesSetOnPromptRegistration() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")

        _ = try await mcpServer.registerPrompt(name: "test") {
            [.user(.text("Test"))]
        }

        let session = await mcpServer.createSession()
        let caps = await session.capabilities
        #expect(caps.prompts?.listChanged == true)
    }

    // MARK: - Duplicate Registration Tests

    @Test("Duplicate tool registration throws error")
    func duplicateToolRegistrationThrows() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        // Register first tool
        _ = try await server.register(
            name: "duplicate_tool",
            description: "First"
        ) { (_: HandlerContext) in
            "first"
        }

        // Second registration with same name should throw
        await #expect(throws: MCPError.self) {
            _ = try await server.register(
                name: "duplicate_tool",
                description: "Second"
            ) { (_: HandlerContext) in
                "second"
            }
        }
    }

    @Test("Duplicate resource registration throws error")
    func duplicateResourceRegistrationThrows() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        // Register first resource
        _ = try await server.registerResource(
            uri: "test://duplicate",
            name: "first"
        ) {
            .text("first", uri: "test://duplicate")
        }

        // Second registration with same URI should throw
        await #expect(throws: MCPError.self) {
            _ = try await server.registerResource(
                uri: "test://duplicate",
                name: "second"
            ) {
                .text("second", uri: "test://duplicate")
            }
        }
    }

    @Test("Duplicate prompt registration throws error")
    func duplicatePromptRegistrationThrows() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0")

        // Register first prompt
        _ = try await server.registerPrompt(name: "duplicate_prompt") {
            [.user(.text("First"))]
        }

        // Second registration with same name should throw
        await #expect(throws: MCPError.self) {
            _ = try await server.registerPrompt(name: "duplicate_prompt") {
                [.user(.text("Second"))]
            }
        }
    }
}

// MARK: - Resource Template Matching Tests

@Suite("Resource Template Matching Tests")
struct ResourceTemplateMatchingTests {
    @Test("Match simple template")
    func matchSimpleTemplate() {
        let template = ManagedResourceTemplate(
            uriTemplate: "file:///{path}",
            name: "file"
        ) { uri, _ in
            .text("content", uri: uri)
        }

        let vars = template.match("file:///test.txt")
        #expect(vars?["path"] == "test.txt")
    }

    @Test("Match template with multiple variables")
    func matchMultipleVariables() {
        let template = ManagedResourceTemplate(
            uriTemplate: "user://{userId}/posts/{postId}",
            name: "user_post"
        ) { uri, _ in
            .text("content", uri: uri)
        }

        let vars = template.match("user://123/posts/456")
        #expect(vars?["userId"] == "123")
        #expect(vars?["postId"] == "456")
    }

    @Test("Non-matching URI returns nil")
    func nonMatchingUri() {
        let template = ManagedResourceTemplate(
            uriTemplate: "file:///{path}",
            name: "file"
        ) { uri, _ in
            .text("content", uri: uri)
        }

        let vars = template.match("http://example.com/test.txt")
        #expect(vars == nil)
    }

    @Test("Percent-encoded space (%20) is decoded in template variables")
    func percentEncodedSpace() {
        let template = ManagedResourceTemplate(
            uriTemplate: "file:///{path}",
            name: "file"
        ) { uri, _ in
            .text("content", uri: uri)
        }

        let vars = template.match("file:///hello%20world.txt")
        #expect(vars?["path"] == "hello world.txt")
    }

    @Test("Percent-encoded slash (%2F) is decoded in template variables")
    func percentEncodedSlash() {
        // %2F matches within a single path segment because the literal characters
        // '%', '2', 'F' are not '/', so [^/]+ accepts them. After extraction the
        // handler receives the decoded '/'.
        let template = ManagedResourceTemplate(
            uriTemplate: "repo://{owner}/{name}",
            name: "repo"
        ) { uri, _ in
            .text("content", uri: uri)
        }

        let vars = template.match("repo://acme/my%2Frepo")
        #expect(vars?["name"] == "my/repo")
        #expect(vars?["owner"] == "acme")
    }

    @Test("Unicode percent-encoded characters are decoded in template variables")
    func unicodePercentEncoded() {
        let template = ManagedResourceTemplate(
            uriTemplate: "file:///{path}",
            name: "file"
        ) { uri, _ in
            .text("content", uri: uri)
        }

        // café encoded as caf%C3%A9 (UTF-8 percent-encoding)
        let vars = template.match("file:///caf%C3%A9.txt")
        #expect(vars?["path"] == "café.txt")
    }

    @Test("Multiple percent-encoded variables are each decoded independently")
    func multiplePercentEncodedVariables() {
        let template = ManagedResourceTemplate(
            uriTemplate: "doc://{author}/{title}",
            name: "doc"
        ) { uri, _ in
            .text("content", uri: uri)
        }

        let vars = template.match("doc://Jane%20Doe/My%20Book")
        #expect(vars?["author"] == "Jane Doe")
        #expect(vars?["title"] == "My Book")
    }

    @Test("Variables without percent-encoding are unchanged")
    func noPercentEncoding() {
        let template = ManagedResourceTemplate(
            uriTemplate: "file:///{path}",
            name: "file"
        ) { uri, _ in
            .text("content", uri: uri)
        }

        let vars = template.match("file:///plain.txt")
        #expect(vars?["path"] == "plain.txt")
    }
}
