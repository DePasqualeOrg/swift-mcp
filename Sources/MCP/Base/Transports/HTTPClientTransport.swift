// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Foundation
import Logging

#if !os(Linux)
import EventSource
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Status of the event stream within an HTTP transport.
///
/// This is separate from `MCPClient.ConnectionState` because event stream disruptions
/// don't prevent POST-based tool calls from succeeding. The event stream carries
/// server-initiated push messages; its health is reported independently so the UI
/// can surface connectivity changes without blocking request-level operations.
public enum EventStreamStatus: Sendable, Equatable {
    /// The event stream is connected and receiving events.
    case connected
    /// The event stream has disconnected and the transport is retrying.
    case reconnecting
    /// The transport has exhausted all reconnection attempts for the event stream.
    case failed
}

/// An implementation of the MCP Streamable HTTP transport protocol for clients.
///
/// This transport implements the [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http)
/// specification from the Model Context Protocol.
///
/// It supports:
/// - Sending JSON-RPC messages via HTTP POST requests
/// - Receiving responses via both direct JSON responses and SSE streams
/// - Session management using the `Mcp-Session-Id` header
/// - Automatic reconnection for dropped SSE streams
/// - Platform-specific optimizations for different operating systems
///
/// The transport supports two modes:
/// - Regular HTTP (`streaming=false`): Simple request/response pattern
/// - Streaming HTTP with SSE (`streaming=true`): Enables server-to-client push messages
///
/// ## Linux Platform Limitations
///
/// SSE functionality is unavailable on Linux because `URLSession.AsyncBytes` is not yet
/// implemented in swift-corelibs-foundation (see [swift#57548](https://github.com/swiftlang/swift/issues/57548)).
///
/// **What works:** HTTP POST requests and JSON responses (tool calls, resource reads, prompts).
///
/// **What doesn't work:** Server-initiated push notifications, streaming responses, and
/// stream resumability. On Linux, set `streaming: false` to avoid warnings.
///
/// ## Example Usage
///
/// ```swift
/// import MCP
///
/// // Create a streaming HTTP transport with bearer token authentication
/// let transport = HTTPClientTransport(
///     endpoint: URL(string: "https://api.example.com/mcp")!,
///     requestModifier: { request in
///         var modifiedRequest = request
///         modifiedRequest.addValue("Bearer your-token-here", forHTTPHeaderField: "Authorization")
///         return modifiedRequest
///     }
/// )
///
/// // Initialize the client with streaming transport
/// let client = Client(name: "MyApp", version: "1.0.0")
/// try await client.connect(transport: transport)
///
/// // The transport will automatically handle SSE events
/// // and deliver them through the client's notification handlers
/// ```
public actor HTTPClientTransport: Transport {
    /// The server endpoint URL to connect to
    public let endpoint: URL
    private let session: URLSession

    /// The session ID assigned by the server, used for maintaining state across requests
    public private(set) var sessionID: String?

    /// The negotiated protocol version, set after initialization
    public private(set) var protocolVersion: String?
    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?

    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    /// Maximum time to wait for a session ID before proceeding with SSE connection
    public let sseInitializationTimeout: TimeInterval

    /// Configuration for reconnection behavior
    public nonisolated let reconnectionOptions: HTTPReconnectionOptions

    /// Closure to modify requests before they are sent
    private let requestModifier: (URLRequest) -> URLRequest

    /// OAuth provider for automatic token management
    private let authProvider: (any OAuthClientProvider)?

    /// Per-request auth retry state, passed through the send→retry call chain
    /// so that concurrent sends don't share mutable state.
    private struct AuthRetryState {
        var hasCompletedAuth = false
        var lastUpscopingHeader: String?
    }

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<TransportMessage, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<TransportMessage, Swift.Error>.Continuation

    /// Stream for signaling when session ID is set
    private var sessionIDSignalStream: AsyncStream<Void>?
    private var sessionIDSignalContinuation: AsyncStream<Void>.Continuation?

    // MARK: - Reconnection State

    /// The last event ID received from the server, used for resumability
    private var lastEventId: String?

    /// Server-provided retry delay in seconds (from SSE retry: field)
    private var serverRetryDelay: TimeInterval?

    /// Current reconnection attempt count
    private var reconnectionAttempt: Int = 0

    /// Whether the event stream status change has been fired for the current disconnection episode.
    /// Used to deduplicate so we fire `.reconnecting` only once per episode.
    private var eventStreamDisconnectedFired: Bool = false

    /// Callback invoked when a new resumption token (event ID) is received
    public var onResumptionToken: ((String) -> Void)?

    /// Sets the callback invoked when a new resumption token (event ID) is received.
    ///
    /// - Parameter callback: The callback to invoke with the event ID
    public func setOnResumptionToken(_ callback: ((String) -> Void)?) {
        onResumptionToken = callback
    }

    /// Callback invoked when the session is detected as expired (HTTP 404 with existing session ID).
    ///
    /// This allows higher-level abstractions (e.g., `MCPClient`) to proactively trigger
    /// reconnection when the session expires, rather than waiting for the next tool call to fail.
    public var onSessionExpired: (@Sendable () -> Void)?

    /// Sets the callback invoked when the session expires.
    ///
    /// - Parameter callback: The callback to invoke when session expiration is detected
    public func setOnSessionExpired(_ callback: (@Sendable () -> Void)?) {
        onSessionExpired = callback
    }

    /// Callback invoked when the event stream status changes.
    ///
    /// Fires on transitions only (not on initial connection). The first event a consumer
    /// will see is `.reconnecting` if the stream drops after being established.
    public var onEventStreamStatusChanged: (@Sendable (EventStreamStatus) async -> Void)?

    /// Sets the callback invoked when the event stream status changes.
    public func setOnEventStreamStatusChanged(_ callback: (@Sendable (EventStreamStatus) async -> Void)?) {
        onEventStreamStatusChanged = callback
    }

    #if os(Linux)
    /// Creates a new HTTP transport client with the specified endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The server URL to connect to
    ///   - streaming: Whether to enable SSE streaming mode (default: true).
    ///     Note: SSE is not fully supported on Linux.
    ///   - sseInitializationTimeout: Maximum time to wait for session ID before proceeding with SSE (default: 10 seconds)
    ///   - reconnectionOptions: Configuration for reconnection behavior (default: .default)
    ///   - requestModifier: Optional closure to customize requests before they are sent (default: no modification)
    ///   - authProvider: Optional OAuth provider for automatic token management.
    ///     When provided, the transport will use the provider to obtain Bearer tokens
    ///     and handle 401 responses automatically.
    ///   - logger: Optional logger instance for transport events
    ///
    /// - Note: On Linux, the `configuration:` parameter is not available because
    ///   `URLSessionConfiguration` cannot be extended. The transport uses a default
    ///   configuration with MCP-appropriate timeouts (5 minute request, 1 hour resource).
    public init(
        endpoint: URL,
        streaming: Bool = true,
        sseInitializationTimeout: TimeInterval = 10,
        reconnectionOptions: HTTPReconnectionOptions = .default,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        authProvider: (any OAuthClientProvider)? = nil,
        logger: Logger? = nil
    ) {
        // Create configuration with MCP-appropriate timeouts
        // (Cannot use .mcp extension on Linux since URLSessionConfiguration cannot be extended)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = mcpDefaultSSEReadTimeout
        configuration.timeoutIntervalForResource = 3600

        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            sseInitializationTimeout: sseInitializationTimeout,
            reconnectionOptions: reconnectionOptions,
            requestModifier: requestModifier,
            authProvider: authProvider,
            logger: logger
        )
    }
    #else
    /// Creates a new HTTP transport client with the specified endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The server URL to connect to
    ///   - configuration: URLSession configuration to use for HTTP requests.
    ///     Defaults to `.mcp` which provides appropriate timeouts for SSE connections
    ///     (5 minute request timeout, 1 hour resource timeout).
    ///   - streaming: Whether to enable SSE streaming mode (default: true)
    ///   - sseInitializationTimeout: Maximum time to wait for session ID before proceeding with SSE (default: 10 seconds)
    ///   - reconnectionOptions: Configuration for reconnection behavior (default: .default)
    ///   - requestModifier: Optional closure to customize requests before they are sent (default: no modification)
    ///   - authProvider: Optional OAuth provider for automatic token management.
    ///     When provided, the transport will use the provider to obtain Bearer tokens
    ///     and handle 401 responses automatically.
    ///   - logger: Optional logger instance for transport events
    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .mcp,
        streaming: Bool = true,
        sseInitializationTimeout: TimeInterval = 10,
        reconnectionOptions: HTTPReconnectionOptions = .default,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        authProvider: (any OAuthClientProvider)? = nil,
        logger: Logger? = nil
    ) {
        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            sseInitializationTimeout: sseInitializationTimeout,
            reconnectionOptions: reconnectionOptions,
            requestModifier: requestModifier,
            authProvider: authProvider,
            logger: logger
        )
    }
    #endif

    init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        sseInitializationTimeout: TimeInterval = 10,
        reconnectionOptions: HTTPReconnectionOptions = .default,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        authProvider: (any OAuthClientProvider)? = nil,
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.streaming = streaming
        self.sseInitializationTimeout = sseInitializationTimeout
        self.reconnectionOptions = reconnectionOptions
        self.requestModifier = requestModifier
        self.authProvider = authProvider

        // Create message stream
        let (stream, continuation) = AsyncThrowingStream<TransportMessage, Swift.Error>.makeStream()
        messageStream = stream
        messageContinuation = continuation

        self.logger =
            logger
                ?? Logger(
                    label: "mcp.transport.http.client",
                    factory: { _ in SwiftLogNoOpLogHandler() }
                )
    }

    // Set up the initial session ID signal stream
    private func setUpInitialSessionIDSignal() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        sessionIDSignalStream = stream
        sessionIDSignalContinuation = continuation
    }

    // Trigger the initial session ID signal when a session ID is established
    private func triggerInitialSessionIDSignal() {
        if let continuation = sessionIDSignalContinuation {
            continuation.yield(())
            continuation.finish()
            sessionIDSignalContinuation = nil // Consume the continuation
            logger.trace("Initial session ID signal triggered for SSE task.")
        }
    }

    /// Establishes connection with the transport
    ///
    /// This prepares the transport for communication and sets up SSE streaming
    /// if streaming mode is enabled. The actual HTTP connection happens with the
    /// first message sent.
    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true

        // Setup initial session ID signal
        setUpInitialSessionIDSignal()

        if streaming {
            // Start listening to server events
            streamingTask = Task { await startListeningForServerEvents() }
        }

        logger.debug("HTTP transport connected")
    }

    /// Disconnects from the transport
    ///
    /// This terminates any active connections, cancels the streaming task,
    /// and releases any resources being used by the transport.
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        eventStreamDisconnectedFired = false

        // Cancel streaming task if active
        streamingTask?.cancel()
        streamingTask = nil

        // Cancel any in-progress requests
        session.invalidateAndCancel()

        // Clean up message stream
        messageContinuation.finish()

        // Finish the session ID signal stream if it's still pending
        sessionIDSignalContinuation?.finish()
        sessionIDSignalContinuation = nil
        sessionIDSignalStream = nil

        logger.debug("HTTP client transport disconnected")
    }

    /// Terminates the current session by sending a DELETE request to the server.
    ///
    /// Clients that no longer need a particular session (e.g., because the user is
    /// leaving the client application) SHOULD send an HTTP DELETE to the MCP endpoint
    /// with the `Mcp-Session-Id` header to explicitly terminate the session.
    ///
    /// This allows the server to clean up any resources associated with the session.
    ///
    /// - Note: The server MAY respond with HTTP 405 Method Not Allowed, indicating
    ///   that the server does not allow clients to terminate sessions. This is handled
    ///   gracefully and does not throw an error.
    ///
    /// - Throws: MCPError if the DELETE request fails for reasons other than 405.
    public func terminateSession() async throws {
        guard let sessionID else {
            // No session to terminate
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"

        // Add session ID header
        request.addValue(sessionID, forHTTPHeaderField: HTTPHeader.sessionId)

        // Add protocol version if available
        if let protocolVersion {
            request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)
        }

        // Apply request modifier (for auth headers, etc.)
        request = requestModifier(request)

        logger.debug("Terminating session", metadata: ["sessionID": "\(sessionID)"])

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        switch httpResponse.statusCode {
            case 200, 204:
                // Success - session terminated
                self.sessionID = nil
                logger.debug("Session terminated successfully")

            case 405:
                // Server does not support session termination - this is OK per spec
                logger.debug("Server does not support session termination (405)")

            case 404:
                // Session already expired or doesn't exist
                self.sessionID = nil
                logger.debug("Session not found (already expired)")

            default:
                throw MCPError.internalError(
                    "Failed to terminate session: HTTP \(httpResponse.statusCode)")
        }
    }

    /// Sends data through an HTTP POST request
    ///
    /// This sends a JSON-RPC message to the server via HTTP POST and processes
    /// the response according to the MCP Streamable HTTP specification. It handles:
    ///
    /// - Adding appropriate Accept headers for both JSON and SSE
    /// - Including the session ID in requests if one has been established
    /// - Processing different response types (JSON vs SSE)
    /// - Handling HTTP error codes according to the specification
    ///
    /// ## Implementation Note
    ///
    /// This method signature differs from TypeScript and Python SDKs which receive
    /// typed `JSONRPCMessage` objects instead of raw `Data`. Swift parses the JSON
    /// internally to determine message type (request vs notification) for proper
    /// content-type validation per the MCP spec.
    ///
    /// This design avoids breaking changes to the `Transport` protocol. A future
    /// revision could consider changing the protocol to receive typed messages
    /// for better alignment with other SDKs.
    ///
    /// - Parameters:
    ///   - data: The JSON-RPC message to send
    ///   - options: Transport send options (ignored for HTTP client transport)
    /// - Throws: MCPError for transport failures or server errors
    public func send(_ data: Data, options _: TransportSendOptions) async throws {
        // Determine if message is a request (has both "method" and "id")
        // Per MCP spec, only requests require content-type validation
        let expectsContentType = isRequest(data)
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        var authState = AuthRetryState()
        try await performSend(data: data, expectsContentType: expectsContentType, authState: &authState)
    }

    private func performSend(data: Data, expectsContentType: Bool, authState: inout AuthRetryState) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: HTTPHeader.accept)
        request.addValue("application/json", forHTTPHeaderField: HTTPHeader.contentType)
        request.httpBody = data

        // Add session ID if available
        if let sessionID {
            request.addValue(sessionID, forHTTPHeaderField: HTTPHeader.sessionId)
        }

        // Add protocol version if available (required after initialization)
        if let protocolVersion {
            request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)
        }

        // Apply auth provider (sets Bearer token if available)
        try await applyAuth(to: &request)

        // Apply request modifier (can override auth headers if needed)
        request = requestModifier(request)

        do {
            #if os(Linux)
            let (responseData, response) = try await session.data(for: request)
            try await processResponse(response: response, data: responseData, expectsContentType: expectsContentType)
            #else
            let (responseStream, response) = try await session.bytes(for: request)
            try await processResponse(response: response, stream: responseStream, expectsContentType: expectsContentType)
            #endif
        } catch let authError as AuthenticationRequiredError {
            try await handleUnauthorized(
                response: authError.response,
                data: data,
                expectsContentType: expectsContentType,
                authState: &authState
            )
        } catch let scopeError as InsufficientScopeError {
            try await handleInsufficientScope(
                response: scopeError.response,
                data: data,
                expectsContentType: expectsContentType,
                authState: &authState
            )
        }
    }

    /// Handles a 401 response by delegating to the auth provider and retrying once.
    private func handleUnauthorized(
        response: HTTPURLResponse,
        data: Data,
        expectsContentType: Bool,
        authState: inout AuthRetryState
    ) async throws {
        guard let authProvider else {
            throw MCPError.internalError("Authentication required")
        }

        // Prevent infinite retry loops: only retry auth once per send() call
        if authState.hasCompletedAuth {
            logger.warning("Server returned 401 after successful authentication")
            throw MCPError.internalError("Authentication required (retry failed)")
        }

        // Parse WWW-Authenticate header for auth context
        let wwwAuth = response.value(forHTTPHeaderField: "WWW-Authenticate")
        let challenge = wwwAuth.flatMap { parseBearerChallenge($0) }

        let context = UnauthorizedContext(
            resourceMetadataURL: challenge?.resourceMetadataURL,
            scope: challenge?.scope,
            wwwAuthenticate: wwwAuth
        )

        logger.debug("Handling 401 with auth provider", metadata: [
            "hasResourceMetadata": "\(context.resourceMetadataURL != nil)",
            "hasScope": "\(context.scope != nil)",
        ])

        // Delegate to auth provider to perform authorization
        _ = try await authProvider.handleUnauthorized(context: context)
        authState.hasCompletedAuth = true

        // Retry the request with new tokens
        try await performSend(data: data, expectsContentType: expectsContentType, authState: &authState)
    }

    /// Handles a 403 response by checking for `insufficient_scope` and
    /// re-authorizing with the new scope if applicable.
    private func handleInsufficientScope(
        response: HTTPURLResponse,
        data: Data,
        expectsContentType: Bool,
        authState: inout AuthRetryState
    ) async throws {
        guard let authProvider else {
            throw MCPError.internalError("Access forbidden")
        }

        // Don't retry if we just completed an auth flow (prevents 401→403→retry chains)
        if authState.hasCompletedAuth {
            logger.warning("Server returned 403 after successful authentication")
            throw MCPError.internalError("Access forbidden (insufficient scope after authentication)")
        }

        // Parse WWW-Authenticate to check for insufficient_scope
        let wwwAuth = response.value(forHTTPHeaderField: "WWW-Authenticate")
        let challenge = wwwAuth.flatMap { parseBearerChallenge($0) }

        // Only handle insufficient_scope errors; other 403s are not retryable
        guard challenge?.error == "insufficient_scope" else {
            throw MCPError.internalError("Access forbidden")
        }

        // Loop prevention: if the server returns the same WWW-Authenticate
        // header as the previous 403, stop retrying
        if let wwwAuth, let lastHeader = authState.lastUpscopingHeader, wwwAuth == lastHeader {
            logger.warning("Server returned same insufficient_scope challenge after re-authorization")
            throw MCPError.internalError("Access forbidden (scope step-up failed)")
        }
        authState.lastUpscopingHeader = wwwAuth

        let context = UnauthorizedContext(
            resourceMetadataURL: challenge?.resourceMetadataURL,
            scope: challenge?.scope,
            wwwAuthenticate: wwwAuth
        )

        logger.debug("Handling 403 insufficient_scope with auth provider", metadata: [
            "scope": "\(context.scope ?? "nil")",
        ])

        // Re-authorize with the new scope
        _ = try await authProvider.handleUnauthorized(context: context)
        authState.hasCompletedAuth = true

        // Retry the request with new tokens
        try await performSend(data: data, expectsContentType: expectsContentType, authState: &authState)
    }

    /// Checks if the given data represents a JSON-RPC request.
    ///
    /// Per JSON-RPC 2.0 spec, a request has both "method" and "id" fields.
    /// Notifications have "method" but no "id". Responses have "id" but no "method".
    ///
    /// This is used to determine content-type validation behavior per MCP spec:
    /// - Requests: Server MUST return `application/json` or `text/event-stream`
    /// - Notifications: Server MUST return 202 Accepted with no body
    private func isRequest(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        // A request has both "method" and "id" fields
        return json["method"] != nil && json["id"] != nil
    }

    /// Result of processing a JSON-RPC message for response detection and optional ID remapping.
    private struct ProcessedMessage {
        /// Whether the message is a JSON-RPC response (success or error)
        let isResponse: Bool
        /// The message data, potentially with ID remapped
        let data: Data
    }

    /// Processes a JSON-RPC message, detecting if it's a response and optionally remapping its ID.
    ///
    /// Per JSON-RPC 2.0 spec:
    /// - A successful response has "id" and "result" fields, but no "method"
    /// - An error response has "id" and "error" fields, but no "method"
    ///
    /// This combines response detection with ID remapping for efficiency (single parse).
    /// ID remapping is used during stream resumption to ensure responses match the
    /// original pending request, aligning with Python SDK behavior.
    ///
    /// Note: This implementation handles both success AND error responses, which aligns
    /// with Python SDK but is more complete than TypeScript SDK. TypeScript's streamableHttp.ts
    /// only checks `isJSONRPCResultResponse` (success only), missing error response handling.
    /// TODO: Remove this note after this PR is merged:
    /// https://github.com/modelcontextprotocol/typescript-sdk/pull/1390
    ///
    /// - Parameters:
    ///   - data: The raw JSON-RPC message data
    ///   - originalRequestId: Optional ID to remap response IDs to (for stream resumption)
    /// - Returns: ProcessedMessage with isResponse flag and potentially remapped data
    private func processJSONRPCMessage(_ data: Data, originalRequestId: RequestId?) -> ProcessedMessage {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProcessedMessage(isResponse: false, data: data)
        }

        // Check if it's a response (has id + result/error, no method)
        let hasId = json["id"] != nil
        let hasResult = json["result"] != nil
        let hasError = json["error"] != nil
        let hasMethod = json["method"] != nil
        let isResponse = hasId && (hasResult || hasError) && !hasMethod

        // If it's a response and we have an original request ID, remap the ID
        if isResponse, let originalId = originalRequestId {
            switch originalId {
                case let .string(s): json["id"] = s
                case let .number(n): json["id"] = n
            }

            // Re-encode with remapped ID
            if let remappedData = try? JSONSerialization.data(withJSONObject: json) {
                return ProcessedMessage(isResponse: true, data: remappedData)
            }
        }

        return ProcessedMessage(isResponse: isResponse, data: data)
    }

    #if os(Linux)
    // Process response with data payload (Linux)
    private func processResponse(response: URLResponse, data: Data, expectsContentType: Bool) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        // Process the response based on content type and status code
        let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeader.contentType) ?? ""

        // Extract session ID if present
        if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeader.sessionId) {
            let wasSessionIDNil = (sessionID == nil)
            sessionID = newSessionID
            if wasSessionIDNil {
                // Trigger signal on first session ID
                triggerInitialSessionIDSignal()
            }
            logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }

        try processHTTPResponse(httpResponse, contentType: contentType)
        guard case 200 ..< 300 = httpResponse.statusCode else { return }

        // Process response based on content type
        if contentType.contains("text/event-stream") {
            logger.warning("SSE responses aren't fully supported on Linux")
            messageContinuation.yield(TransportMessage(data: data))
        } else if contentType.contains("application/json") {
            logger.trace("Received JSON response", metadata: ["size": "\(data.count)"])
            messageContinuation.yield(TransportMessage(data: data))
        } else if expectsContentType, !data.isEmpty {
            // Per MCP spec: requests MUST receive application/json or text/event-stream
            // Notifications expect 202 Accepted with no body, so unexpected content-type is ignored
            throw MCPError.internalError("Unexpected content type: \(contentType)")
        }
    }
    #else
    // Process response with byte stream (macOS, iOS, etc.)
    private func processResponse(response: URLResponse, stream: URLSession.AsyncBytes, expectsContentType: Bool)
        async throws
    {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        // Process the response based on content type and status code
        let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeader.contentType) ?? ""

        // Extract session ID if present
        if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeader.sessionId) {
            let wasSessionIDNil = (sessionID == nil)
            sessionID = newSessionID
            if wasSessionIDNil {
                // Trigger signal on first session ID
                triggerInitialSessionIDSignal()
            }
            logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }

        try processHTTPResponse(httpResponse, contentType: contentType)
        guard case 200 ..< 300 = httpResponse.statusCode else { return }

        if contentType.contains("text/event-stream") {
            // For SSE response from POST, isReconnectable is false initially
            // but can become reconnectable after receiving a priming event
            logger.trace("Received SSE response, processing in streaming task")
            try await processSSE(stream, isReconnectable: false)
        } else if contentType.contains("application/json") {
            // For JSON responses, collect and deliver the data
            var buffer = Data()
            for try await byte in stream {
                buffer.append(byte)
            }
            logger.trace("Received JSON response", metadata: ["size": "\(buffer.count)"])
            messageContinuation.yield(TransportMessage(data: buffer))
        } else {
            // Collect data to check if response has content
            var buffer = Data()
            for try await byte in stream {
                buffer.append(byte)
            }
            // Per MCP spec: requests MUST receive application/json or text/event-stream
            // Notifications expect 202 Accepted with no body, so unexpected content-type is ignored
            if expectsContentType, !buffer.isEmpty {
                throw MCPError.internalError("Unexpected content type: \(contentType)")
            }
        }
    }
    #endif

    // MARK: - Auth Helpers

    /// Applies the auth provider's Bearer token to a request, if an auth provider is configured.
    private func applyAuth(to request: inout URLRequest) async throws {
        guard let authProvider else { return }
        if let tokens = try await authProvider.tokens() {
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Thrown internally when the server returns 401 so `performSend` can intercept and retry.
    private struct AuthenticationRequiredError: Error {
        let response: HTTPURLResponse
    }

    /// Thrown internally when the server returns 403 with `insufficient_scope`
    /// so `performSend` can intercept and attempt scope step-up.
    private struct InsufficientScopeError: Error {
        let response: HTTPURLResponse
    }

    // MARK: - HTTP Response Processing

    // Common HTTP response handling for all platforms
    //
    // Note: The MCP spec recommends auto-detecting legacy SSE servers by falling back
    // to GET on 400/404/405 errors. We don't implement this, consistent with the
    // TypeScript and Python SDKs which provide separate transports instead.
    private func processHTTPResponse(_ response: HTTPURLResponse, contentType: String) throws {
        // Handle status codes according to HTTP semantics
        switch response.statusCode {
            case 200 ..< 300:
                // Success range - these are handled by the platform-specific code
                return

            case 400:
                throw MCPError.internalError("Bad request")

            case 401:
                // When an auth provider is configured, throw an internal error that
                // performSend() can catch to trigger the auth flow and retry.
                if authProvider != nil {
                    throw AuthenticationRequiredError(response: response)
                }
                throw MCPError.internalError("Authentication required")

            case 403:
                if authProvider != nil {
                    throw InsufficientScopeError(response: response)
                }
                throw MCPError.internalError("Access forbidden")

            case 404:
                // If we get a 404 with a session ID, it means our session is invalid
                // TODO: Consider Python's approach - send JSON-RPC error through stream
                // with request ID (code -32600) before throwing. This gives pending requests
                // proper error responses. Options: (1) catch in send() and yield error,
                // (2) use RequestContext pattern like Python. Both are spec-compliant.
                if sessionID != nil {
                    logger.warning("Session has expired")
                    sessionID = nil
                    onSessionExpired?()
                    throw MCPError.sessionExpired
                }
                throw MCPError.internalError("Endpoint not found")

            case 405:
                // If we get a 405, it means the server does not support the requested method
                // If streaming was requested, we should cancel the streaming task
                if streaming {
                    streamingTask?.cancel()
                    throw MCPError.internalError("Server does not support streaming")
                }
                throw MCPError.internalError("Method not allowed")

            case 408:
                throw MCPError.internalError("Request timeout")

            case 429:
                throw MCPError.internalError("Too many requests")

            case 500 ..< 600:
                // Server error range
                throw MCPError.internalError("Server error: \(response.statusCode)")

            default:
                throw MCPError.internalError(
                    "Unexpected HTTP response: \(response.statusCode) (\(contentType))")
        }
    }

    /// Receives data in an async sequence
    ///
    /// This returns an AsyncThrowingStream that emits TransportMessage objects representing
    /// each JSON-RPC message received from the server. This includes:
    ///
    /// - Direct responses to client requests
    /// - Server-initiated messages delivered via SSE streams
    ///
    /// - Returns: An AsyncThrowingStream of TransportMessage objects
    public func receive() -> AsyncThrowingStream<TransportMessage, Swift.Error> {
        messageStream
    }

    /// Sets the protocol version to include in request headers.
    ///
    /// This should be called after initialization when the protocol version is negotiated.
    /// HTTP transports must include the `Mcp-Protocol-Version` header in all requests
    /// after initialization.
    ///
    /// - Parameter version: The negotiated protocol version (e.g., "2024-11-05")
    public func setProtocolVersion(_ version: String) async {
        protocolVersion = version
        logger.debug("Protocol version set", metadata: ["version": "\(version)"])
    }

    // MARK: - SSE

    /// Starts listening for server events using SSE
    ///
    /// This establishes a long-lived HTTP connection using Server-Sent Events (SSE)
    /// to enable server-to-client push messaging. It handles:
    ///
    /// - Waiting for session ID if needed
    /// - Opening the SSE connection
    /// - Automatic reconnection on connection drops
    /// - Processing received events
    private func startListeningForServerEvents() async {
        #if os(Linux)
        // SSE is not fully supported on Linux
        if streaming {
            logger.warning(
                "SSE streaming was requested but is not fully supported on Linux. SSE connection will not be attempted."
            )
        }
        #else
        // This is the original code for platforms that support SSE
        guard isConnected else { return }

        // Wait for the initial session ID signal, but only if sessionID isn't already set
        if sessionID == nil, let signalStream = sessionIDSignalStream {
            logger.trace("SSE streaming task waiting for initial sessionID signal...")

            // Race the stream against a timeout using TaskGroup
            var signalReceived = false
            do {
                signalReceived = try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        // Wait for signal from stream
                        for await _ in signalStream {
                            return true
                        }
                        return false // Stream finished without yielding
                    }
                    group.addTask {
                        // Timeout task
                        try await Task.sleep(for: .seconds(self.sseInitializationTimeout))
                        return false
                    }

                    // Take the first result and cancel the other task
                    if let firstResult = try await group.next() {
                        group.cancelAll()
                        return firstResult
                    }
                    return false
                }
            } catch {
                logger.error("Error while waiting for session ID signal: \(error)")
            }

            if signalReceived {
                logger.trace("SSE streaming task proceeding after initial sessionID signal.")
            } else {
                logger.warning(
                    "Timeout waiting for initial sessionID signal. SSE stream will proceed (sessionID might be nil)."
                )
            }
        } else if sessionID != nil {
            logger.trace(
                "Initial sessionID already available. Proceeding with SSE streaming task immediately."
            )
        } else {
            logger.trace(
                "Proceeding with SSE connection attempt; sessionID is nil. This might be expected for stateless servers or if initialize hasn't provided one yet."
            )
        }

        // Retry loop for connection drops with exponential backoff
        while isConnected, !Task.isCancelled {
            do {
                try await connectToEventStream()
                // Reset attempt counter on successful connection
                reconnectionAttempt = 0
                // Signal reconnection if we were previously disconnected
                if eventStreamDisconnectedFired {
                    eventStreamDisconnectedFired = false
                    await onEventStreamStatusChanged?(.connected)
                }
            } catch {
                if !Task.isCancelled {
                    logger.error("SSE connection error: \(error)")

                    // Fire reconnecting only once per episode
                    if !eventStreamDisconnectedFired {
                        eventStreamDisconnectedFired = true
                        await onEventStreamStatusChanged?(.reconnecting)
                    }

                    // Check if we've exceeded max retries
                    if reconnectionAttempt >= reconnectionOptions.maxRetries {
                        logger.error(
                            "Maximum reconnection attempts exceeded",
                            metadata: ["maxRetries": "\(reconnectionOptions.maxRetries)"]
                        )
                        await onEventStreamStatusChanged?(.failed)
                        break
                    }

                    // Calculate delay with exponential backoff
                    let delay = getNextReconnectionDelay()
                    reconnectionAttempt += 1

                    logger.debug(
                        "Scheduling reconnection",
                        metadata: [
                            "attempt": "\(reconnectionAttempt)",
                            "delay": "\(delay)s",
                        ]
                    )

                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        #endif
    }

    /// Calculates the next reconnection delay using exponential backoff
    ///
    /// Uses server-provided retry value if available, otherwise falls back
    /// to exponential backoff based on current attempt count.
    ///
    /// - Returns: Time to wait in seconds before next reconnection attempt
    private func getNextReconnectionDelay() -> TimeInterval {
        // Use server-provided retry value if available
        if let serverDelay = serverRetryDelay {
            return serverDelay
        }

        // Fall back to exponential backoff
        let initialDelay = reconnectionOptions.initialReconnectionDelay
        let growFactor = reconnectionOptions.reconnectionDelayGrowFactor
        let maxDelay = reconnectionOptions.maxReconnectionDelay

        // Calculate delay with exponential growth, capped at maximum
        let delay = initialDelay * pow(growFactor, Double(reconnectionAttempt))
        return min(delay, maxDelay)
    }

    #if !os(Linux)
    /// Establishes an SSE connection to the server
    ///
    /// This initiates a GET request to the server endpoint with appropriate
    /// headers to establish an SSE stream according to the MCP specification.
    ///
    /// - Parameters:
    ///   - resumptionToken: Optional event ID to resume from (sent as Last-Event-ID header)
    ///   - originalRequestId: Optional request ID to remap response IDs to (for stream resumption)
    /// - Throws: MCPError for connection failures or server errors
    private func connectToEventStream(
        resumptionToken: String? = nil,
        originalRequestId: RequestId? = nil
    ) async throws {
        guard isConnected else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.addValue("text/event-stream", forHTTPHeaderField: HTTPHeader.accept)
        request.addValue("no-cache", forHTTPHeaderField: HTTPHeader.cacheControl)

        // Add session ID if available
        if let sessionID {
            request.addValue(sessionID, forHTTPHeaderField: HTTPHeader.sessionId)
        }

        // Add protocol version if available
        if let protocolVersion {
            request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeader.protocolVersion)
        }

        // Add Last-Event-ID for resumability (use provided token or stored lastEventId)
        let eventIdToSend = resumptionToken ?? lastEventId
        if let eventId = eventIdToSend {
            request.addValue(eventId, forHTTPHeaderField: HTTPHeader.lastEventId)
            logger.debug("Resuming SSE stream", metadata: ["lastEventId": "\(eventId)"])
        }

        // Apply auth provider (sets Bearer token if available)
        try await applyAuth(to: &request)

        // Apply request modifier (can override auth headers if needed)
        request = requestModifier(request)

        logger.debug("Starting SSE connection")

        // Create URLSession task for SSE
        let (stream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        // Check response status
        guard httpResponse.statusCode == 200 else {
            // If the server returns 405 Method Not Allowed,
            // it indicates that the server doesn't support SSE streaming.
            // We should cancel the task instead of retrying the connection.
            if httpResponse.statusCode == 405 {
                streamingTask?.cancel()
            }
            // Detect session expiration on the GET path (matching POST behavior)
            if httpResponse.statusCode == 404, sessionID != nil {
                logger.warning("Event stream: session has expired")
                sessionID = nil
                onSessionExpired?()
            }
            throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
        }

        // Extract session ID if present
        if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeader.sessionId) {
            let wasSessionIDNil = (sessionID == nil)
            sessionID = newSessionID
            if wasSessionIDNil {
                // Trigger signal on first session ID, though this is unlikely to happen here
                // as GET usually follows a POST that would have already set the session ID
                triggerInitialSessionIDSignal()
            }
            logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }

        try await processSSE(stream, isReconnectable: true, originalRequestId: originalRequestId)
    }

    /// Processes an SSE byte stream, extracting events and delivering them
    ///
    /// This method tracks event IDs for resumability and handles the retry directive
    /// from the server to adjust reconnection timing.
    ///
    /// - Parameters:
    ///   - stream: The URLSession.AsyncBytes stream to process
    ///   - isReconnectable: Whether this stream should automatically reconnect on disconnect
    ///   - originalRequestId: Optional request ID to remap response IDs to (for stream resumption)
    /// - Throws: Error for stream processing failures
    private func processSSE(
        _ stream: URLSession.AsyncBytes,
        isReconnectable: Bool,
        originalRequestId: RequestId? = nil
    ) async throws {
        // Track whether we've received a priming event (event with ID)
        // Per spec, server SHOULD send a priming event with ID before closing
        var hasPrimingEvent = false

        // Track whether we've received a response - if so, no need to reconnect
        // Reconnection is for when server disconnects BEFORE sending response
        var receivedResponse = false

        do {
            for try await event in stream.events {
                // Check if task has been cancelled
                if Task.isCancelled { break }

                logger.trace(
                    "SSE event received",
                    metadata: [
                        "type": "\(event.event ?? "message")",
                        "id": "\(event.id ?? "none")",
                        "retry": "\(event.retry.map(String.init) ?? "none")",
                    ]
                )

                // Update last event ID if provided
                if let eventId = event.id {
                    lastEventId = eventId
                    // Mark that we've received a priming event - stream is now resumable
                    hasPrimingEvent = true
                    // Notify callback
                    onResumptionToken?(eventId)
                }

                // Handle server-provided retry directive (in milliseconds, convert to seconds)
                if let retryMs = event.retry {
                    serverRetryDelay = TimeInterval(retryMs) / 1000.0
                    logger.debug(
                        "Server retry directive received",
                        metadata: ["retryMs": "\(retryMs)"]
                    )
                }

                // Skip events with no data (priming events, keep-alives)
                if event.data.isEmpty {
                    continue
                }

                // Convert the event data to Data and yield it to the message stream
                if let data = event.data.data(using: .utf8) {
                    // Process the message: detect if it's a response and optionally remap ID
                    // Per MCP spec, reconnection should only stop after receiving
                    // the response to the original request
                    let processed = processJSONRPCMessage(data, originalRequestId: originalRequestId)
                    if processed.isResponse {
                        receivedResponse = true
                    }
                    messageContinuation.yield(TransportMessage(data: processed.data))
                }
            }

            // Stream ended gracefully - check if we need to reconnect
            // Reconnect if: already reconnectable (GET stream) OR received a priming event
            // BUT don't reconnect if we already received a response - the request is complete
            let canResume = isReconnectable || hasPrimingEvent
            let needsReconnect = canResume && !receivedResponse

            if needsReconnect, isConnected, !Task.isCancelled {
                logger.debug(
                    "SSE stream ended gracefully, will reconnect",
                    metadata: ["lastEventId": "\(lastEventId ?? "none")"]
                )

                // For GET streams (isReconnectable=true), the outer loop in
                // startListeningForServerEvents handles reconnection.
                // For POST SSE responses that received a priming event, we need to
                // schedule reconnection via GET (per MCP spec: "Resumption is always via HTTP GET").
                if !isReconnectable, hasPrimingEvent {
                    schedulePostSSEReconnection()
                }
            }
        } catch {
            logger.error("Error processing SSE events: \(error)")

            // For GET streams, the outer loop will handle reconnection with exponential backoff.
            // For POST SSE responses with a priming event, schedule reconnection via GET.
            if !isReconnectable, hasPrimingEvent, !receivedResponse, isConnected,
               !Task.isCancelled
            {
                schedulePostSSEReconnection()
            } else {
                throw error
            }
        }
    }

    /// Schedules reconnection for a POST SSE response that was interrupted.
    ///
    /// Per MCP spec, resumption is always via HTTP GET with Last-Event-ID header.
    /// This method spawns a task that handles reconnection with exponential backoff.
    private func schedulePostSSEReconnection() {
        guard let eventId = lastEventId else {
            logger.warning("Cannot schedule POST SSE reconnection without lastEventId")
            return
        }

        // Reset reconnection attempt counter for this new reconnection sequence
        reconnectionAttempt = 0

        Task { [weak self] in
            guard let self else { return }

            let maxRetries = reconnectionOptions.maxRetries

            while await isConnected, !Task.isCancelled {
                let attempt = await reconnectionAttempt

                if attempt >= maxRetries {
                    logger.error(
                        "POST SSE reconnection: max attempts exceeded",
                        metadata: ["maxRetries": "\(maxRetries)"]
                    )
                    return
                }

                // Calculate delay with exponential backoff
                let delay = await getNextReconnectionDelay()
                await incrementReconnectionAttempt()

                logger.debug(
                    "POST SSE reconnection: scheduling attempt",
                    metadata: [
                        "attempt": "\(attempt + 1)",
                        "delay": "\(delay)s",
                        "lastEventId": "\(eventId)",
                    ]
                )

                try? await Task.sleep(for: .seconds(delay))

                // Check again after sleep
                guard await isConnected, !Task.isCancelled else { return }

                do {
                    try await connectToEventStream(resumptionToken: eventId)
                    // Success - connectToEventStream handles SSE processing
                    // Reset attempt counter on success
                    await resetReconnectionAttempt()
                    return
                } catch {
                    logger.error(
                        "POST SSE reconnection failed: \(error)",
                        metadata: ["attempt": "\(attempt + 1)"]
                    )
                    // Continue to next iteration for retry
                }
            }
        }
    }

    /// Increments the reconnection attempt counter.
    private func incrementReconnectionAttempt() {
        reconnectionAttempt += 1
    }

    /// Resets the reconnection attempt counter.
    private func resetReconnectionAttempt() {
        reconnectionAttempt = 0
    }
    #endif

    // MARK: - Public Resumption API

    /// Resumes an SSE stream from a previous event ID.
    ///
    /// Opens a GET SSE connection with the Last-Event-ID header to replay missed events.
    /// This is useful for clients that need to reconnect after a disconnection and want
    /// to resume from where they left off.
    ///
    /// When `originalRequestId` is provided, any JSON-RPC response received on the
    /// resumed stream will have its ID remapped to match the original request. This
    /// ensures the response is correctly matched to the pending request in the client,
    /// even if the server sends a different ID during replay. This behavior aligns
    /// with the TypeScript and Python MCP SDK implementations.
    ///
    /// - Parameters:
    ///   - lastEventId: The event ID to resume from (sent as Last-Event-ID header)
    ///   - originalRequestId: Optional request ID to remap response IDs to
    /// - Throws: MCPError if the connection fails
    public func resumeStream(from lastEventId: String, forRequestId originalRequestId: RequestId? = nil) async throws {
        #if os(Linux)
        logger.warning("resumeStream is not supported on Linux (SSE not available)")
        #else
        try await connectToEventStream(resumptionToken: lastEventId, originalRequestId: originalRequestId)
        #endif
    }

    /// The last event ID received from the server.
    ///
    /// This can be used to persist the event ID and resume the stream later
    /// using `resumeStream(from:)`.
    public var lastReceivedEventId: String? {
        lastEventId
    }
}
