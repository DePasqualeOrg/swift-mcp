/// Vapor MCP Server Example
///
/// This example demonstrates how to integrate an MCP server with the Vapor web framework.
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
/// cd Examples/VaporIntegration
/// swift run
/// ```
///
/// The server will listen on http://localhost:8080/mcp

import Foundation
import MCP
import Vapor

// MARK: - Configuration

/// Server bind address - using localhost enables automatic DNS rebinding protection
let serverHost = "localhost"
let serverPort = 8080

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
    name: "vapor-mcp-example",
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

// MARK: - HTTP Handlers

/// Handle POST /mcp requests
func handlePost(_ req: Vapor.Request) async throws -> Vapor.Response {
    // Get session ID from header (if present)
    let sessionId = req.headers.first(name: HTTPHeader.sessionId)

    // Read request body
    guard let bodyData = req.body.data else {
        throw Abort(.badRequest, reason: "Missing request body")
    }
    let data = Data(buffer: bodyData)

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
            throw Abort(.serviceUnavailable, reason: "Server at capacity")
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
                    req.logger.info("Session initialized: \(sessionId)")
                },
                onSessionClosed: { sessionId in
                    await sessionManager.remove(sessionId)
                    req.logger.info("Session closed: \(sessionId)")
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
        throw Abort(.notFound, reason: "Session expired. Try reconnecting.")
    } else {
        // No session ID and not an initialize request
        throw Abort(.badRequest, reason: "Missing \(HTTPHeader.sessionId) header")
    }

    // Create the MCP HTTP request for the transport
    let mcpRequest = MCP.HTTPRequest(
        method: "POST",
        headers: extractHeaders(from: req),
        body: data
    )

    // Handle the request
    let mcpResponse = await transport.handleRequest(mcpRequest)

    // Build response
    return buildVaporResponse(from: mcpResponse, for: req)
}

/// Handle GET /mcp requests (SSE stream for server-initiated notifications)
func handleGet(_ req: Vapor.Request) async throws -> Vapor.Response {
    guard let sessionId = req.headers.first(name: HTTPHeader.sessionId),
          let session = await sessionManager.session(forId: sessionId)
    else {
        throw Abort(.badRequest, reason: "Invalid or missing session ID")
    }

    let mcpRequest = MCP.HTTPRequest(
        method: "GET",
        headers: extractHeaders(from: req)
    )

    let mcpResponse = await session.transport.handleRequest(mcpRequest)

    return buildVaporResponse(from: mcpResponse, for: req)
}

/// Handle DELETE /mcp requests (session termination)
func handleDelete(_ req: Vapor.Request) async throws -> Vapor.Response {
    guard let sessionId = req.headers.first(name: HTTPHeader.sessionId),
          let session = await sessionManager.session(forId: sessionId)
    else {
        throw Abort(.notFound, reason: "Session not found")
    }

    let mcpRequest = MCP.HTTPRequest(
        method: "DELETE",
        headers: extractHeaders(from: req)
    )

    let mcpResponse = await session.transport.handleRequest(mcpRequest)

    return Vapor.Response(status: .init(statusCode: mcpResponse.statusCode))
}

// MARK: - Helper Functions

/// Extract headers from Vapor request to dictionary
func extractHeaders(from req: Vapor.Request) -> [String: String] {
    var headers: [String: String] = [:]
    for (name, value) in req.headers {
        headers[name] = value
    }
    return headers
}

/// Build a Vapor Response from an MCP HTTPResponse
func buildVaporResponse(from mcpResponse: MCP.HTTPResponse, for req: Vapor.Request) -> Vapor.Response {
    var headers = HTTPHeaders()
    for (key, value) in mcpResponse.headers {
        headers.add(name: key, value: value)
    }

    let status = HTTPResponseStatus(statusCode: mcpResponse.statusCode)

    if let stream = mcpResponse.stream {
        // SSE response - create streaming body
        let response = Vapor.Response(status: status, headers: headers)
        response.body = .init(asyncStream: { writer in
            do {
                for try await data in stream {
                    try await writer.write(.buffer(.init(data: data)))
                }
                try await writer.write(.end)
            } catch {
                req.logger.error("SSE stream error: \(error)")
            }
        })
        return response
    } else if let body = mcpResponse.body {
        // JSON response
        return Vapor.Response(
            status: status,
            headers: headers,
            body: .init(data: body)
        )
    } else {
        // No content (e.g., 202 Accepted for notifications)
        return Vapor.Response(status: status, headers: headers)
    }
}

// MARK: - Main

@main
struct VaporMCPExample {
    static func main() async throws {
        // Register tools using high-level API
        try await setUpTools()

        // Create Vapor application
        let env = try Environment.detect()
        let app = try await Application.make(env)

        // Configure routes
        app.post("mcp", use: handlePost)
        app.get("mcp", use: handleGet)
        app.delete("mcp", use: handleDelete)

        // Health check
        app.get("health") { _ in
            "OK"
        }

        app.logger.info("Starting MCP server on http://\(serverHost):\(serverPort)/mcp")
        app.logger.info("Available tools: echo, add")

        try await app.execute()
        try await app.asyncShutdown()
    }
}
