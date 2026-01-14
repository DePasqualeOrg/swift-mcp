/// MCP Conformance Test Server
///
/// An MCP server implementing all the test fixtures required by the conformance test suite.
/// This server provides tools, resources, and prompts with specific names and behaviors
/// that the conformance tests expect.
///
/// ## Usage
///
/// ```bash
/// # Start the server
/// swift run ConformanceServer --port 8080
///
/// # In another terminal, run conformance tests
/// npx @modelcontextprotocol/conformance server --url http://localhost:8080/mcp
/// ```

import ArgumentParser
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import MCP

// MARK: - CLI

@main
struct ConformanceServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "MCP Conformance Test Server",
        discussion: "Runs an MCP server with test fixtures for the conformance test suite."
    )

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 8080

    @Option(name: .shortAndLong, help: "Host to bind to")
    var host: String = "localhost"

    func run() async throws {
        let logger = Logger(label: "mcp.conformance.server")

        // Create the MCP server with all capabilities enabled for conformance testing
        let mcpServer = MCPServer(
            name: "swift-conformance-server",
            version: "1.0.0",
            capabilities: Server.Capabilities(
                logging: .init(),
                resources: .init(subscribe: true),
                completions: .init()
            )
        )

        // Register test fixtures
        try await registerTestTools(mcpServer)
        try await registerTestResources(mcpServer)
        try await registerTestPrompts(mcpServer)

        // Create session manager
        let sessionManager = ConformanceSessionManager(mcpServer: mcpServer, host: host, port: port, logger: logger)

        // Create Hummingbird router
        let router = Router(context: ConformanceRequestContext.self)

        // MCP endpoints
        router.post("/mcp") { request, context in
            try await sessionManager.handlePost(request: request)
        }
        router.get("/mcp") { request, context in
            try await sessionManager.handleGet(request: request)
        }
        router.delete("/mcp") { request, context in
            try await sessionManager.handleDelete(request: request)
        }

        // Health check
        router.get("/health") { _, _ in
            Response(status: .ok, body: .init(byteBuffer: .init(string: "OK")))
        }

        // Create and run application
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )

        logger.info("Starting MCP conformance server on http://\(host):\(port)/mcp")
        try await app.run()
    }
}

// MARK: - Request Context

struct ConformanceRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: Source) {
        self.coreContext = .init(source: source)
    }
}

// MARK: - Session Manager

actor ConformanceSessionManager {
    struct Session {
        let server: MCP.Server
        let transport: HTTPServerTransport
    }

    private var sessions: [String: Session] = [:]
    private let mcpServer: MCPServer
    private let host: String
    private let port: Int
    private let logger: Logger

    init(mcpServer: MCPServer, host: String, port: Int, logger: Logger) {
        self.mcpServer = mcpServer
        self.host = host
        self.port = port
        self.logger = logger
    }

    private struct MethodCheck: Decodable {
        let method: String?
    }

    func handlePost(request: Request) async throws -> Response {
        let sessionId = request.headers[HTTPField.Name(HTTPHeader.sessionId)!]
        let body = try await request.body.collect(upTo: .max)
        let data = Data(buffer: body)

        let isInitializeRequest = (try? JSONDecoder().decode(MethodCheck.self, from: data))?.method == "initialize"

        let transport: HTTPServerTransport

        if let sid = sessionId, let session = sessions[sid] {
            transport = session.transport
        } else if isInitializeRequest {
            let newSessionId = UUID().uuidString

            let newTransport = HTTPServerTransport(
                options: .forBindAddress(
                    host: host,
                    port: port,
                    sessionIdGenerator: { newSessionId },
                    onSessionInitialized: { [weak self] sessionId in
                        self?.logger.info("Session initialized: \(sessionId)")
                    },
                    onSessionClosed: { [weak self] sessionId in
                        await self?.removeSession(sessionId)
                        self?.logger.info("Session closed: \(sessionId)")
                    }
                )
            )

            let server = await mcpServer.createSession()

            // Register additional handlers for conformance testing
            await registerConformanceHandlers(server)

            sessions[newSessionId] = Session(server: server, transport: newTransport)
            transport = newTransport

            try await server.start(transport: transport)
        } else if sessionId != nil {
            return Response(
                status: .notFound,
                body: .init(byteBuffer: .init(string: "Session expired"))
            )
        } else {
            return Response(
                status: .badRequest,
                body: .init(byteBuffer: .init(string: "Missing session ID"))
            )
        }

        let mcpRequest = MCP.HTTPRequest(
            method: "POST",
            headers: extractHeaders(from: request),
            body: data
        )

        let mcpResponse = await transport.handleRequest(mcpRequest)
        return buildResponse(from: mcpResponse)
    }

    func handleGet(request: Request) async throws -> Response {
        guard let sessionId = request.headers[HTTPField.Name(HTTPHeader.sessionId)!],
              let session = sessions[sessionId]
        else {
            return Response(
                status: .badRequest,
                body: .init(byteBuffer: .init(string: "Invalid or missing session ID"))
            )
        }

        let mcpRequest = MCP.HTTPRequest(
            method: "GET",
            headers: extractHeaders(from: request)
        )

        let mcpResponse = await session.transport.handleRequest(mcpRequest)
        return buildResponse(from: mcpResponse)
    }

    func handleDelete(request: Request) async throws -> Response {
        guard let sessionId = request.headers[HTTPField.Name(HTTPHeader.sessionId)!],
              let session = sessions[sessionId]
        else {
            return Response(
                status: .notFound,
                body: .init(byteBuffer: .init(string: "Session not found"))
            )
        }

        let mcpRequest = MCP.HTTPRequest(
            method: "DELETE",
            headers: extractHeaders(from: request)
        )

        let mcpResponse = await session.transport.handleRequest(mcpRequest)
        return Response(status: .init(code: mcpResponse.statusCode))
    }

    private func removeSession(_ id: String) {
        sessions.removeValue(forKey: id)
    }

    private func extractHeaders(from request: Request) -> [String: String] {
        var headers: [String: String] = [:]
        for field in request.headers {
            headers[field.name.rawName] = field.value
        }
        if let authority = request.head.authority {
            headers["Host"] = authority
        }
        return headers
    }

    private func buildResponse(from mcpResponse: MCP.HTTPResponse) -> Response {
        var responseHeaders = HTTPFields()
        for (key, value) in mcpResponse.headers {
            if let name = HTTPField.Name(key) {
                responseHeaders[name] = value
            }
        }

        let status = HTTPResponse.Status(code: mcpResponse.statusCode)

        if let stream = mcpResponse.stream {
            let responseBody = ResponseBody(asyncSequence: SSEResponseSequence(stream: stream))
            return Response(status: status, headers: responseHeaders, body: responseBody)
        } else if let body = mcpResponse.body {
            return Response(status: status, headers: responseHeaders, body: .init(byteBuffer: .init(data: body)))
        } else {
            return Response(status: status, headers: responseHeaders)
        }
    }
}

struct SSEResponseSequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    let stream: AsyncThrowingStream<Data, Error>

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

        mutating func next() async throws -> ByteBuffer? {
            guard let data = try await iterator.next() else { return nil }
            return ByteBuffer(data: data)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }
}

// MARK: - Test Data Constants

private enum TestData {
    /// 1x1 red pixel PNG, base64 encoded
    static let redPixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

    /// Minimal WAV file (silent, 1 sample), base64 encoded
    static let silentWAVBase64 = "UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA="

    static var redPixelPNGData: Data {
        guard let data = Data(base64Encoded: redPixelPNGBase64) else {
            preconditionFailure("Invalid base64 for red pixel PNG test data")
        }
        return data
    }

    static var silentWAVData: Data {
        guard let data = Data(base64Encoded: silentWAVBase64) else {
            preconditionFailure("Invalid base64 for silent WAV test data")
        }
        return data
    }
}

// MARK: - Test Tool Definitions

/// Returns simple text content
@Tool
struct TestSimpleText {
    static let name = "test_simple_text"
    static let description = "Returns simple text content for conformance testing"

    func perform() async throws -> String {
        "This is a simple text response for testing."
    }
}

/// Returns image content (1x1 red pixel PNG)
@Tool
struct TestImageContent {
    static let name = "test_image_content"
    static let description = "Returns image content for conformance testing"

    func perform() async throws -> ImageOutput {
        ImageOutput(pngData: TestData.redPixelPNGData)
    }
}

/// Returns audio content
@Tool
struct TestAudioContent {
    static let name = "test_audio_content"
    static let description = "Returns audio content for conformance testing"

    func perform() async throws -> AudioOutput {
        AudioOutput(data: TestData.silentWAVData, mimeType: "audio/wav")
    }
}

/// Returns embedded resource content
@Tool
struct TestEmbeddedResource {
    static let name = "test_embedded_resource"
    static let description = "Returns embedded resource content for conformance testing"

    func perform() async throws -> MultiContent {
        let resourceContent = Resource.Contents.text("Embedded resource text content", uri: "test://static-text", mimeType: "text/plain")
        return MultiContent([.resource(resource: resourceContent, annotations: nil, _meta: nil)])
    }
}

/// Returns mixed content types (text, image, and resource)
@Tool
struct TestMultipleContentTypes {
    static let name = "test_multiple_content_types"
    static let description = "Returns mixed content types for conformance testing"

    func perform() async throws -> MultiContent {
        let resourceContent = Resource.Contents.text("{\"test\":\"data\",\"value\":123}", uri: "test://mixed-content-resource", mimeType: "application/json")
        return MultiContent([
            .text("Multiple content types test:"),
            .image(data: TestData.redPixelPNGBase64, mimeType: "image/png"),
            .resource(resource: resourceContent, annotations: nil, _meta: nil)
        ])
    }
}

/// Returns an error
@Tool
struct TestErrorHandling {
    static let name = "test_error_handling"
    static let description = "Returns an error for conformance testing"

    func perform() async throws -> String {
        throw MCPError.invalidRequest("Test error message")
    }
}

/// Tool that sends log messages during execution
@Tool
struct TestToolWithLogging {
    static let name = "test_tool_with_logging"
    static let description = "Sends log messages during execution"

    func perform(context: HandlerContext) async throws -> String {
        // Send actual log messages using the SDK's logging API
        try await context.info("Starting tool execution", logger: "test_tool_with_logging")
        try await context.debug("Debug message from tool", logger: "test_tool_with_logging")
        try await context.warning("Warning message from tool", logger: "test_tool_with_logging")
        return "Tool executed with logging"
    }
}

/// Tool with progress reporting
@Tool
struct TestToolWithProgress {
    static let name = "test_tool_with_progress"
    static let description = "Reports progress during execution"

    func perform(context: HandlerContext) async throws -> String {
        // Send actual progress updates using the SDK's progress API
        try await context.reportProgress(0, total: 100, message: "Starting...")
        try await context.reportProgress(33, total: 100, message: "Processing...")
        try await context.reportProgress(66, total: 100, message: "Almost done...")
        try await context.reportProgress(100, total: 100, message: "Complete")
        return "Tool executed with progress"
    }
}

/// Tool that requests LLM sampling from client
@Tool
struct TestSampling {
    static let name = "test_sampling"
    static let description = "Requests LLM sampling from client"

    func perform(context: HandlerContext) async throws -> String {
        // Request a sampling completion from the client using the SDK's sampling API
        let result = try await context.createMessage(
            messages: [
                Sampling.Message(role: .user, content: .text("What is 2+2? Reply with just the number."))
            ],
            maxTokens: 100
        )

        // Return the result from the LLM
        switch result.content {
        case .text(let text, _, _):
            return "LLM response: \(text)"
        case .image:
            return "LLM responded with an image"
        case .audio:
            return "LLM responded with audio"
        case .toolUse, .toolResult:
            return "LLM responded with tool content"
        }
    }
}

func registerTestTools(_ mcpServer: MCPServer) async throws {
    try await mcpServer.register {
        TestSimpleText.self
        TestImageContent.self
        TestAudioContent.self
        TestEmbeddedResource.self
        TestMultipleContentTypes.self
        TestErrorHandling.self
        TestToolWithLogging.self
        TestToolWithProgress.self
        TestSampling.self
    }
}

// MARK: - Test Resources

func registerTestResources(_ mcpServer: MCPServer) async throws {
    // Static text resource
    try await mcpServer.registerResource(
        uri: "test://static-text",
        name: "Static Text Resource",
        description: "A static text resource for conformance testing",
        mimeType: "text/plain"
    ) {
        .text("This is static text content for testing.", uri: "test://static-text", mimeType: "text/plain")
    }

    // Static binary resource (base64 encoded)
    try await mcpServer.registerResource(
        uri: "test://static-binary",
        name: "Static Binary Resource",
        description: "A static binary resource for conformance testing"
    ) {
        .binary(TestData.redPixelPNGData, uri: "test://static-binary", mimeType: "image/png")
    }

    // Resource template (expected pattern: test://template/{id}/data)
    try await mcpServer.registerResourceTemplate(
        uriTemplate: "test://template/{id}/data",
        name: "Template Resource",
        description: "A dynamic resource template for conformance testing",
        mimeType: "application/json"
    ) { uri, variables in
        // Extract ID from URI or variables
        let id = variables["id"] ?? "unknown"
        let json = "{\"id\":\"\(id)\",\"templateTest\":true,\"data\":\"Data for ID: \(id)\"}"
        return .text(json, uri: uri, mimeType: "application/json")
    }
}

// MARK: - Test Prompts

func registerTestPrompts(_ mcpServer: MCPServer) async throws {
    // Simple prompt without arguments
    try await mcpServer.registerPrompt(
        name: "test_simple_prompt",
        description: "A simple prompt without arguments"
    ) {
        [.user(.text("This is a simple test prompt message."))]
    }

    // Prompt with arguments (arg1 and arg2 as expected by conformance tests)
    try await mcpServer.registerPrompt(
        name: "test_prompt_with_arguments",
        description: "A prompt with arguments",
        arguments: [
            Prompt.Argument(name: "arg1", description: "First test argument", required: true),
            Prompt.Argument(name: "arg2", description: "Second test argument", required: true)
        ]
    ) { arguments, _ in
        let arg1 = arguments?["arg1"] ?? ""
        let arg2 = arguments?["arg2"] ?? ""
        return [.user(.text("Prompt with arg1=\(arg1) and arg2=\(arg2)"))]
    }

    // Prompt with embedded resource
    try await mcpServer.registerPrompt(
        name: "test_prompt_with_embedded_resource",
        description: "A prompt with embedded resource"
    ) {
        [.user(.resource(uri: "test://static-text", mimeType: "text/plain", text: "Embedded text from resource"))]
    }

    // Prompt with image
    try await mcpServer.registerPrompt(
        name: "test_prompt_with_image",
        description: "A prompt with image content"
    ) {
        [.user(.image(data: TestData.redPixelPNGBase64, mimeType: "image/png"))]
    }
}

// MARK: - Conformance Handlers

/// Registers additional handlers required for conformance testing that aren't
/// automatically set up by MCPServer.
func registerConformanceHandlers(_ server: MCP.Server) async {
    // Completion handler - returns empty completions for conformance testing
    await server.withRequestHandler(Complete.self) { _, _ in
        Complete.Result(completion: CompletionSuggestions(values: [], total: 0, hasMore: false))
    }

    // Resource subscription handler
    await server.withRequestHandler(ResourceSubscribe.self) { _, _ in
        ResourceSubscribe.Result()
    }

    // Resource unsubscription handler
    await server.withRequestHandler(ResourceUnsubscribe.self) { _, _ in
        ResourceUnsubscribe.Result()
    }
}
