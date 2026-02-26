// Copyright © Anthony DePasquale

/// Hummingbird MCP Server Example
///
/// This example demonstrates how to integrate an MCP server with the Hummingbird web framework.
/// It uses the high-level `MCPServer` API for tool registration and creates per-session
/// Server instances using `createSession()`.
///
/// ## Architecture
///
/// - ONE `MCPServer` instance holds shared tool/resource/prompt definitions
/// - Each client session gets its own `Server` instance via `createSession()`
/// - Each session has its own `HTTPServerTransport`
/// - The `SessionManager` actor manages session lifecycle
///
/// ## Endpoints
///
/// - `POST /mcp` - Handle JSON-RPC requests (initialize, tools/list, tools/call, etc.)
/// - `GET /mcp` - Server-Sent Events stream for server-initiated notifications
/// - `DELETE /mcp` - Terminate a session
///
/// ## Running
///
/// ```bash
/// cd Examples/HummingbirdIntegration
/// swift run
/// ```
///
/// The server will listen on http://localhost:3000/mcp

import Foundation
import HTTPTypes
import Hummingbird
import Logging
import MCP

// MARK: - Configuration

/// Server bind address - using localhost enables automatic DNS rebinding protection
let serverHost = "localhost"
let serverPort = 3000

// MARK: - Tool Definitions

/// Echoes back the input message.
@Tool
struct Echo {
    static let name = "echo"
    static let description = "Echoes back the input message"

    @Parameter(description: "The message to echo")
    var message: String

    func perform(context _: HandlerContext) async throws -> String {
        message
    }
}

/// Adds two numbers.
@Tool
struct Add {
    static let name = "add"
    static let description = "Adds two numbers"

    @Parameter(description: "First number")
    var a: Double

    @Parameter(description: "Second number")
    var b: Double

    func perform(context _: HandlerContext) async throws -> String {
        "Result: \(a + b)"
    }
}

// MARK: - Server Setup

/// Create the MCP server using the high-level API (ONE instance for all clients).
/// Tools/resources/prompts are registered once and shared across all sessions.
let mcpServer = MCPServer(
    name: "hummingbird-mcp-example",
    version: "1.0.0"
)

/// Register tools using the high-level API
func setUpTools() async throws {
    try await mcpServer.register {
        Echo.self
        Add.self
    }
}

// MARK: - Session Management

/// Custom session manager for this example.
/// Each session has its own Server instance (created via mcpServer.createSession())
/// and its own HTTPServerTransport.
actor ExampleSessionManager {
    struct Session {
        let server: MCP.Server
        let transport: HTTPServerTransport
    }

    private var sessions: [String: Session] = [:]
    private let maxSessions: Int

    init(maxSessions: Int) {
        self.maxSessions = maxSessions
    }

    func session(forId id: String) -> Session? {
        sessions[id]
    }

    func canAddSession() -> Bool {
        sessions.count < maxSessions
    }

    func store(_ session: Session, forId id: String) {
        sessions[id] = session
    }

    func remove(_ id: String) {
        sessions.removeValue(forKey: id)
    }
}

/// Session manager for tracking active sessions
let sessionManager = ExampleSessionManager(maxSessions: 100)

/// Logger for the example
let logger = Logger(label: "mcp.example.hummingbird")

// MARK: - Request Context

struct MCPRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: Source) {
        coreContext = .init(source: source)
    }
}

// MARK: - HTTP Handlers

/// Handle POST /mcp requests
func handlePost(request: Request, context _: MCPRequestContext) async throws -> Response {
    // Get session ID from header (if present)
    let sessionId = request.headers[HTTPField.Name(HTTPHeader.sessionId)!]

    // Read request body
    let body = try await request.body.collect(upTo: .max)
    let data = Data(buffer: body)

    // Check if this is an initialize request
    let isInitializeRequest = String(data: data, encoding: .utf8)?.contains("\"method\":\"initialize\"") ?? false

    // Get or create session
    let transport: HTTPServerTransport

    if let sid = sessionId, let session = await sessionManager.session(forId: sid) {
        // Reuse existing transport for this session
        transport = session.transport
    } else if isInitializeRequest {
        // Check capacity
        guard await sessionManager.canAddSession() else {
            var headers = HTTPFields()
            headers[.retryAfter] = "60"
            return mcpErrorResponse(
                status: .serviceUnavailable,
                message: "Server at capacity",
                code: ErrorCode.internalError,
                extraHeaders: headers
            )
        }

        // Generate session ID upfront
        let newSessionId = UUID().uuidString

        // Create new transport with session callbacks
        // Using forBindAddress auto-configures DNS rebinding protection for localhost
        let newTransport = HTTPServerTransport(
            options: .forBindAddress(
                host: serverHost,
                port: serverPort,
                sessionIdGenerator: { newSessionId },
                onSessionInitialized: { sessionId in
                    logger.info("Session initialized: \(sessionId)")
                },
                onSessionClosed: { sessionId in
                    await sessionManager.remove(sessionId)
                    logger.info("Session closed: \(sessionId)")
                }
            )
        )

        // Create a new Server instance wired to the shared registries
        let server = await mcpServer.createSession()

        // Store the session
        await sessionManager.store(
            ExampleSessionManager.Session(server: server, transport: newTransport),
            forId: newSessionId
        )
        transport = newTransport

        // Start the server with the transport
        try await server.start(transport: transport)
    } else if sessionId != nil {
        // Client sent a session ID that no longer exists
        return mcpErrorResponse(
            status: .notFound,
            message: "Session expired. Try reconnecting.",
            code: ErrorCode.invalidRequest
        )
    } else {
        // No session ID and not an initialize request
        return mcpErrorResponse(
            status: .badRequest,
            message: "Missing \(HTTPHeader.sessionId) header",
            code: ErrorCode.invalidRequest
        )
    }

    // Create the MCP HTTP request for the transport
    let mcpRequest = MCP.HTTPRequest(
        method: "POST",
        headers: extractHeaders(from: request),
        body: data
    )

    // Handle the request
    let mcpResponse = await transport.handleRequest(mcpRequest)

    // Build response
    return buildResponse(from: mcpResponse)
}

/// Handle GET /mcp requests (SSE stream for server-initiated notifications)
func handleGet(request: Request, context _: MCPRequestContext) async throws -> Response {
    guard let sessionId = request.headers[HTTPField.Name(HTTPHeader.sessionId)!] else {
        return mcpErrorResponse(
            status: .badRequest,
            message: "Missing \(HTTPHeader.sessionId) header",
            code: ErrorCode.invalidRequest
        )
    }
    guard let session = await sessionManager.session(forId: sessionId) else {
        return mcpErrorResponse(
            status: .notFound,
            message: "Session not found",
            code: ErrorCode.invalidRequest
        )
    }

    let mcpRequest = MCP.HTTPRequest(
        method: "GET",
        headers: extractHeaders(from: request)
    )

    let mcpResponse = await session.transport.handleRequest(mcpRequest)

    return buildResponse(from: mcpResponse)
}

/// Handle DELETE /mcp requests (session termination)
func handleDelete(request: Request, context _: MCPRequestContext) async throws -> Response {
    guard let sessionId = request.headers[HTTPField.Name(HTTPHeader.sessionId)!] else {
        return mcpErrorResponse(
            status: .badRequest,
            message: "Missing \(HTTPHeader.sessionId) header",
            code: ErrorCode.invalidRequest
        )
    }
    guard let session = await sessionManager.session(forId: sessionId) else {
        return mcpErrorResponse(
            status: .notFound,
            message: "Session not found",
            code: ErrorCode.invalidRequest
        )
    }

    let mcpRequest = MCP.HTTPRequest(
        method: "DELETE",
        headers: extractHeaders(from: request)
    )

    let mcpResponse = await session.transport.handleRequest(mcpRequest)

    return Response(status: .init(code: mcpResponse.statusCode))
}

// MARK: - Helper Functions

/// Extract headers from Hummingbird request to dictionary
func extractHeaders(from request: Request) -> [String: String] {
    var headers: [String: String] = [:]
    for field in request.headers {
        headers[field.name.rawName] = field.value
    }

    // HTTPTypes stores Host header separately in the authority property
    // (HTTP/2 uses :authority pseudo-header instead of Host)
    // This is required for DNS rebinding protection to work
    if let authority = request.head.authority {
        headers["Host"] = authority
    }

    return headers
}

/// Build a Hummingbird Response from an MCP HTTPResponse
func buildResponse(from mcpResponse: MCP.HTTPResponse) -> Response {
    var responseHeaders = HTTPFields()
    for (key, value) in mcpResponse.headers {
        if let name = HTTPField.Name(key) {
            responseHeaders[name] = value
        }
    }

    let status = HTTPResponse.Status(code: mcpResponse.statusCode)
    let contentTypeName = HTTPField.Name(HTTPHeader.contentType)!

    if let stream = mcpResponse.stream {
        if responseHeaders[contentTypeName] == nil {
            responseHeaders[contentTypeName] = "text/event-stream"
        }
        // SSE response - stream the events
        let responseBody = ResponseBody(asyncSequence: SSEResponseSequence(stream: stream))
        return Response(
            status: status,
            headers: responseHeaders,
            body: responseBody
        )
    } else if let body = mcpResponse.body {
        if responseHeaders[contentTypeName] == nil {
            responseHeaders[contentTypeName] = "application/json"
        }
        // JSON response
        return Response(
            status: status,
            headers: responseHeaders,
            body: .init(byteBuffer: .init(data: body))
        )
    } else {
        // No content (e.g., 202 Accepted for notifications)
        return Response(
            status: status,
            headers: responseHeaders
        )
    }
}

func mcpErrorResponse(
    status: HTTPResponse.Status,
    message: String,
    code: Int = ErrorCode.internalError,
    extraHeaders: HTTPFields = HTTPFields()
) -> Response {
    var headers = extraHeaders
    let contentTypeName = HTTPField.Name(HTTPHeader.contentType)!
    headers[contentTypeName] = "application/json"

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "error": [
            "code": code,
            "message": message,
        ],
        "id": NSNull(),
    ]

    let bodyData =
        (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal Error\"},\"id\":null}".utf8)

    return Response(
        status: status,
        headers: headers,
        body: .init(byteBuffer: .init(data: bodyData))
    )
}

/// Async sequence wrapper for SSE stream
struct SSEResponseSequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    let stream: AsyncThrowingStream<Data, Error>

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

        mutating func next() async throws -> ByteBuffer? {
            guard let data = try await iterator.next() else {
                return nil
            }
            return ByteBuffer(data: data)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }
}

// MARK: - Main

@main
struct HummingbirdMCPExample {
    static func main() async throws {
        // Register tools using high-level API
        try await setUpTools()

        // Create router
        let router = Router(context: MCPRequestContext.self)

        // MCP endpoints
        router.post("/mcp", use: handlePost)
        router.get("/mcp", use: handleGet)
        router.delete("/mcp", use: handleDelete)

        // Health check
        router.get("/health") { _, _ in
            Response(status: .ok, body: .init(byteBuffer: .init(string: "OK")))
        }

        // Create and run application
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(serverHost, port: serverPort))
        )

        logger.info("Starting MCP server on http://\(serverHost):\(serverPort)/mcp")
        logger.info("Available tools: echo, add")

        try await app.run()
    }
}
