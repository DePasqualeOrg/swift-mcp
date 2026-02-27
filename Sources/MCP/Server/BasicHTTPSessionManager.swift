// Copyright © Anthony DePasquale

import Foundation
import Logging

/// A basic in-memory session manager for HTTP-based MCP servers.
///
/// `BasicHTTPSessionManager` provides minimal session lifecycle management suitable
/// for demos, testing, and simple single-instance deployments. It stores sessions
/// in memory and routes requests based on the `Mcp-Session-Id` header.
///
/// ## Limitations
///
/// This manager is intentionally minimal and does NOT provide:
/// - **Session timeouts or idle cleanup**: Sessions remain in memory until explicitly
///   closed via DELETE request or `closeAll()`. If clients disconnect without sending
///   DELETE (e.g., crash, network failure), sessions leak until `maxSessions` is reached.
///   For production, implement periodic cleanup of stale sessions.
/// - **Persistence**: Sessions are lost on restart.
/// - **Distributed session storage**: No Redis, database, or shared storage support.
/// - **Authentication**: No auth middleware integration.
///
/// For production deployments requiring these features, implement custom session
/// management. See the `VaporIntegration` and `HummingbirdIntegration` examples
/// for patterns you can adapt.
///
/// ## Security
///
/// DNS rebinding protection is enabled by default when `host` is `localhost` (the default),
/// `127.0.0.1`, or `::1`. This validates Host and Origin headers to prevent malicious
/// websites from accessing your local server.
///
/// ## Usage
///
/// ```swift
/// let mcpServer = MCPServer(name: "my-server", version: "1.0.0")
/// try await mcpServer.register {
///     Echo.self
///     Add.self
/// }
///
/// // Port is required; host defaults to "localhost" for DNS rebinding protection
/// let sessionManager = BasicHTTPSessionManager(server: mcpServer, port: 8080)
///
/// // Wire to your HTTP framework
/// app.post("mcp") { req in await sessionManager.handleRequest(...) }
/// app.get("mcp") { req in await sessionManager.handleRequest(...) }
/// app.delete("mcp") { req in await sessionManager.handleRequest(...) }
/// ```
public actor BasicHTTPSessionManager {
    /// Logger for session manager events.
    public nonisolated let logger: Logger

    /// The MCPServer providing tool/resource/prompt definitions.
    private let mcpServer: MCPServer

    /// The host the HTTP server is bound to (for DNS rebinding protection).
    private let host: String

    /// The port the HTTP server is bound to (for DNS rebinding protection).
    private let port: Int

    /// Maximum number of concurrent sessions.
    private let maxSessions: Int

    /// Custom session ID generator.
    private let sessionIdGenerator: @Sendable () -> String

    /// Whether to use JSON response mode instead of SSE.
    private let enableJsonResponse: Bool

    /// Active sessions keyed by session ID.
    private var sessions: [String: Session] = [:]

    /// A session with its server and transport.
    private struct Session {
        let server: Server
        let transport: HTTPServerTransport
    }

    /// Creates a new session manager.
    ///
    /// - Parameters:
    ///   - server: The MCPServer containing registered tools, resources, and prompts.
    ///   - host: The host the HTTP server is bound to (default: "localhost").
    ///   - port: The port the HTTP server is bound to.
    ///   - maxSessions: Maximum number of concurrent sessions (default: 100).
    ///   - sessionIdGenerator: Function to generate session IDs (default: UUID strings).
    ///   - enableJsonResponse: Whether to use JSON response mode instead of SSE (default: false).
    ///   - logger: Optional logger for session events (default: creates one with label "mcp.session-manager").
    public init(
        server: MCPServer,
        host: String = "localhost",
        port: Int,
        maxSessions: Int = 100,
        sessionIdGenerator: (@Sendable () -> String)? = nil,
        enableJsonResponse: Bool = false,
        logger: Logger? = nil
    ) {
        self.logger = logger ?? Logger(label: "mcp.session-manager")
        mcpServer = server
        self.host = host
        self.port = port
        self.maxSessions = maxSessions
        self.sessionIdGenerator = sessionIdGenerator ?? { UUID().uuidString }
        self.enableJsonResponse = enableJsonResponse
    }

    /// Handles an incoming HTTP request.
    ///
    /// Routes the request to the appropriate session based on the `Mcp-Session-Id` header.
    /// For initialization requests (without a session ID), creates a new session.
    ///
    /// - Parameter request: The HTTP request to handle.
    /// - Returns: The HTTP response.
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionId = request.header(HTTPHeader.sessionId)

        // Route to existing session
        if let sid = sessionId, let session = sessions[sid] {
            return await session.transport.handleRequest(request)
        }

        // Check if this is an initialization request
        guard isInitializeRequest(request) else {
            // No session and not initializing - return error
            if sessionId == nil {
                return jsonErrorResponse(
                    statusCode: 400,
                    code: ErrorCode.invalidRequest,
                    message: "Bad Request: Mcp-Session-Id header required"
                )
            }
            return jsonErrorResponse(
                statusCode: 404,
                code: ErrorCode.invalidRequest,
                message: "Session not found"
            )
        }

        // Check session limit
        if sessions.count >= maxSessions {
            return jsonErrorResponse(
                statusCode: 503,
                code: ErrorCode.internalError,
                message: "Service Unavailable: Maximum sessions reached",
                extraHeaders: ["retry-after": "60"]
            )
        }

        // Create new session
        let newSessionId = sessionIdGenerator()

        let server = await mcpServer.createSession()
        let transport = HTTPServerTransport(
            options: .forBindAddress(
                host: host,
                port: port,
                sessionIdGenerator: { newSessionId },
                onSessionInitialized: { _ in
                    // Session already stored, nothing to do
                },
                onSessionClosed: { [weak self] sid in
                    await self?.removeSession(sid)
                },
                enableJsonResponse: enableJsonResponse
            )
        )

        // Store session before starting to avoid race conditions
        sessions[newSessionId] = Session(server: server, transport: transport)

        do {
            try await server.start(transport: transport)
        } catch {
            sessions.removeValue(forKey: newSessionId)
            await transport.close()
            logger.error("Failed to start session", metadata: [
                "sessionId": "\(newSessionId)",
                "error": "\(error)",
            ])
            return jsonErrorResponse(
                statusCode: 500,
                code: ErrorCode.internalError,
                message: "Internal Error: Failed to start session"
            )
        }

        return await transport.handleRequest(request)
    }

    /// Closes all active sessions.
    public func closeAll() async {
        for (_, session) in sessions {
            await session.transport.close()
            await session.server.stop()
        }
        sessions.removeAll()
    }

    /// The number of active sessions.
    public var sessionCount: Int {
        sessions.count
    }

    /// The IDs of all active sessions.
    ///
    /// Useful for debugging and monitoring. Combine with ``removeSession(_:)``
    /// to implement custom cleanup of stale sessions.
    public var sessionIds: [String] {
        Array(sessions.keys)
    }

    /// Removes a session by ID, closing its transport and stopping its server.
    ///
    /// Use this to manually clean up stale sessions that weren't properly closed
    /// by clients. For example, implement a periodic cleanup task:
    ///
    /// ```swift
    /// // Track last activity time separately
    /// var lastActivity: [String: Date] = [:]
    ///
    /// // Periodic cleanup
    /// for sessionId in await sessionManager.sessionIds {
    ///     if let lastSeen = lastActivity[sessionId],
    ///        Date().timeIntervalSince(lastSeen) > 3600 {
    ///         await sessionManager.removeSession(sessionId)
    ///         lastActivity.removeValue(forKey: sessionId)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter sessionId: The session ID to remove.
    /// - Returns: `true` if the session was found and removed, `false` if not found.
    @discardableResult
    public func removeSession(_ sessionId: String) async -> Bool {
        guard let session = sessions.removeValue(forKey: sessionId) else {
            return false
        }
        await session.transport.close()
        await session.server.stop()
        logger.info("Session removed", metadata: ["sessionId": "\(sessionId)"])
        return true
    }

    /// Builds a JSON-RPC error response with `application/json` content type.
    private func jsonErrorResponse(
        statusCode: Int,
        code: Int,
        message: String,
        extraHeaders: [String: String] = [:]
    ) -> HTTPResponse {
        let body = (try? JSONRPCErrorResponse(code: code, message: message).encoded()) ?? Data()

        var headers = extraHeaders
        headers[HTTPHeader.contentType] = "application/json"

        return HTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    /// Checks if a request is an initialization request.
    private func isInitializeRequest(_ request: HTTPRequest) -> Bool {
        guard request.method.uppercased() == "POST",
              let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String
        else {
            return false
        }
        return method == "initialize"
    }
}
