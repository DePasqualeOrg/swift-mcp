// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Logging

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

// MARK: - Server Handler Registry

/// Registry of handlers for responding to client requests and notifications.
///
/// This struct consolidates all handler-related state in one place, making it
/// easier to manage and reason about. Unlike `ClientHandlerRegistry`, this struct
/// does not include capability inference since Server capabilities are managed
/// differently (either set explicitly or auto-detected by MCPServer).
struct ServerHandlerRegistry: Sendable {
    /// Request handlers keyed by method name.
    var methodHandlers: [String: RequestHandlerBox] = [:]

    /// Notification handlers keyed by notification name.
    /// Multiple handlers can be registered for the same notification type.
    var notificationHandlers: [String: [NotificationHandlerBox]] = [:]

    /// Fallback handler for requests with no registered handler.
    ///
    /// If set, this handler is called for any incoming request that doesn't have
    /// a specific handler registered. Useful for debugging, logging unknown methods,
    /// or forward-compatibility with new MCP features.
    var fallbackRequestHandler: RequestHandlerBox?

    /// Fallback handler for notifications with no registered handler.
    ///
    /// If set, this handler is called for any incoming notification that doesn't have
    /// a specific handler registered. Useful for debugging or logging unknown notifications.
    var fallbackNotificationHandler: NotificationHandlerBox?

    /// In-flight request handler Tasks, tracked by request ID.
    /// Used for protocol-level cancellation when CancelledNotification is received.
    var inFlightHandlerTasks: [RequestId: Task<Void, Never>] = [:]
}

/// Model Context Protocol server.
///
/// ## Architecture: One Server per Client
///
/// The Swift SDK uses a **one-Server-per-client** architecture, where each client
/// connection gets its own `Server` instance. This mirrors the TypeScript SDK's
/// design and differs from Python's shared-Server model.
///
/// ### Comparison with Other SDKs
///
/// **Python SDK (shared Server):**
/// ```
/// ┌──────────────────────────────────────┐
/// │           Server (ONE)               │
/// │  - Handler registry (shared)         │
/// │  - No connection state               │
/// └──────────────────────────────────────┘
///          │ server.run() creates ↓
/// ┌─────────────┐  ┌─────────────┐
/// │ Session A   │  │ Session B   │
/// │ (Transport) │  │ (Transport) │
/// └─────────────┘  └─────────────┘
/// ```
///
/// **Swift & TypeScript SDKs (per-client Server):**
/// ```
/// ┌─────────────┐  ┌─────────────┐
/// │  Server A   │  │  Server B   │
/// │ (Handlers)  │  │ (Handlers)  │
/// │ (Transport) │  │ (Transport) │
/// └─────────────┘  └─────────────┘
/// ```
///
/// ### Scalability Considerations
///
/// The per-client model is appropriate for MCP's typical use cases:
/// - AI assistants connecting to tool servers (single-digit connections)
/// - IDE plugins and developer tools (tens of connections)
/// - Multi-user applications (hundreds of connections)
///
/// Memory overhead per Server instance is minimal (a few KB for handler references
/// and state). For realistic MCP deployments, this scales well.
///
/// For high-connection scenarios (10,000+), consider:
/// - Horizontal scaling with connection-time load balancing
/// - MCP's stateless mode for true per-request distribution
/// - The Python SDK's shared-Server pattern (requires architectural changes)
///
/// ### Design Rationale
///
/// The per-client model was chosen because it:
/// 1. Matches TypeScript SDK's official examples and patterns
/// 2. Provides complete isolation between client connections
/// 3. Simplifies reasoning about connection state
/// 4. Avoids complex session management code
///
/// For HTTP transports, each session creates its own `(Server, HTTPServerTransport)`
/// pair, stored by session ID for request routing.
///
/// ## API Design: Context vs Server Methods
///
/// The `RequestHandlerContext` provides request-scoped capabilities:
/// - `requestId`, `_meta` - Request identification and metadata
/// - `sendNotification()` - Send notifications during handling
/// - `elicit()`, `elicitUrl()` - Request user input (matches Python's `ctx.elicit()`)
/// - `isCancelled` - Check for request cancellation
///
/// Sampling is done via `server.createMessage()` (matches TypeScript), not through
/// the context. This design follows each reference SDK's conventions where appropriate.
public actor Server: ProtocolLayer {
    /// The server configuration
    public struct Configuration: Hashable, Codable, Sendable {
        /// The default configuration (strict mode enabled).
        ///
        /// This matches Python SDK behavior where the server rejects non-ping requests
        /// before initialization at the session level. TypeScript SDK only enforces this
        /// at the HTTP transport level, not at the server/session level.
        ///
        /// We chose to align with Python because:
        /// - Consistent behavior across all transports (stdio, HTTP, in-memory)
        /// - More defensive - prevents misbehaving clients from accessing functionality before init
        /// - Better aligns with MCP spec intent (clients "SHOULD NOT" send requests before init)
        /// - Ping is still allowed for health checks
        public static let `default` = Configuration(strict: true)

        /// The lenient configuration (strict mode disabled).
        ///
        /// Use this for compatibility with non-compliant clients that send requests
        /// before initialization. This matches TypeScript SDK's server-level behavior.
        public static let lenient = Configuration(strict: false)

        /// When strict mode is enabled (default), the server:
        /// - Requires clients to send an initialize request before any other requests
        /// - Allows ping requests before initialization (for health checks)
        /// - Rejects all other requests from uninitialized clients with a protocol error
        ///
        /// The MCP specification says clients "SHOULD NOT" send requests other than
        /// pings before initialization. Strict mode enforces this at the server level.
        ///
        /// Set to `false` for lenient behavior that allows requests before initialization.
        /// This may be useful for non-compliant clients but can lead to undefined behavior.
        public var strict: Bool

        /// Protocol versions supported by this server, ordered by preference.
        ///
        /// The first element is the preferred version, used as the fallback when the
        /// client's requested version is not supported. Defaults to `Version.supported`.
        ///
        /// - Precondition: Must not be empty.
        public var supportedProtocolVersions: [String]

        public init(
            strict: Bool = true,
            supportedProtocolVersions: [String] = Version.supported
        ) {
            precondition(!supportedProtocolVersions.isEmpty, "supportedProtocolVersions must not be empty")
            self.strict = strict
            self.supportedProtocolVersions = supportedProtocolVersions
        }
    }

    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The server name
        public let name: String
        /// The server version
        public let version: String
        /// A human-readable title for the server, intended for UI display.
        /// If not provided, the `name` should be used for display.
        public let title: String?
        /// An optional human-readable description of what this implementation does.
        public let description: String?
        /// Optional icons representing this implementation.
        public let icons: [Icon]?
        /// An optional URL of the website for this implementation.
        public let websiteUrl: String?

        public init(
            name: String,
            version: String,
            title: String? = nil,
            description: String? = nil,
            icons: [Icon]? = nil,
            websiteUrl: String? = nil
        ) {
            self.name = name
            self.version = version
            self.title = title
            self.description = description
            self.icons = icons
            self.websiteUrl = websiteUrl
        }
    }

    /// Server capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// Resources capabilities
        public struct Resources: Hashable, Codable, Sendable {
            /// Whether the resource can be subscribed to
            public var subscribe: Bool?
            /// Whether the list of resources has changed
            public var listChanged: Bool?

            public init(
                subscribe: Bool? = nil,
                listChanged: Bool? = nil
            ) {
                self.subscribe = subscribe
                self.listChanged = listChanged
            }
        }

        /// Tools capabilities
        public struct Tools: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when tools change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Prompts capabilities
        public struct Prompts: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when prompts change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Logging capabilities
        public struct Logging: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Completions capabilities
        public struct Completions: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Logging capabilities
        public var logging: Logging?
        /// Prompts capabilities
        public var prompts: Prompts?
        /// Resources capabilities
        public var resources: Resources?
        /// Tools capabilities
        public var tools: Tools?
        /// Completions capabilities
        public var completions: Completions?
        /// Tasks capabilities (experimental)
        public var tasks: Tasks?
        /// Experimental, non-standard capabilities that the server supports.
        public var experimental: [String: [String: Value]]?

        public init(
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            tools: Tools? = nil,
            completions: Completions? = nil,
            tasks: Tasks? = nil,
            experimental: [String: [String: Value]]? = nil
        ) {
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.tools = tools
            self.completions = completions
            self.tasks = tasks
            self.experimental = experimental
        }
    }

    /// Server information
    let serverInfo: Server.Info
    /// The server connection, sourced from protocol state.
    var connection: (any Transport)? { protocolState.transport }
    /// Callback invoked when the server's message loop exits (transport disconnected or stopped).
    private var onDisconnect: (@Sendable () async -> Void)?

    /// Sets a callback to be invoked when the server's message loop exits.
    public func setOnDisconnect(_ handler: (@Sendable () async -> Void)?) {
        onDisconnect = handler
    }

    /// The server logger
    var logger: Logger? { protocolLogger }

    /// The server name
    public nonisolated var name: String { serverInfo.name }
    /// The server version
    public nonisolated var version: String { serverInfo.version }
    /// Instructions describing how to use the server and its features
    ///
    /// This can be used by clients to improve the LLM's understanding of
    /// available tools, resources, etc.
    /// It can be thought of like a "hint" to the model.
    /// For example, this information MAY be added to the system prompt.
    public nonisolated let instructions: String?
    /// The server capabilities
    public var capabilities: Capabilities
    /// The server configuration
    public let configuration: Configuration

    /// Experimental APIs for tasks and other features.
    ///
    /// Access experimental features via this property:
    /// ```swift
    /// // Enable task support with in-memory storage
    /// await server.experimental.tasks.enable()
    ///
    /// // Or with custom configuration
    /// let taskSupport = TaskSupport.inMemory()
    /// await server.experimental.tasks.enable(taskSupport)
    /// ```
    ///
    /// - Note: These APIs are experimental and may change without notice.
    public var experimental: ExperimentalServerFeatures {
        ExperimentalServerFeatures(server: self)
    }

    /// Registry of handlers for requests and notifications.
    var registeredHandlers = ServerHandlerRegistry()

    /// Protocol state for JSON-RPC message handling.
    package var protocolState = ProtocolState()

    /// Whether the server is initialized
    var isInitialized = false
    /// The client information received during initialization.
    ///
    /// Contains the client's name and version.
    /// Returns `nil` if the server has not been initialized yet.
    public private(set) var clientInfo: Client.Info?
    /// The client capabilities received during initialization.
    ///
    /// Use this to check what capabilities the client supports.
    /// Returns `nil` if the server has not been initialized yet.
    public private(set) var clientCapabilities: Client.Capabilities?
    /// The protocol version negotiated during initialization.
    ///
    /// Returns `nil` if the server has not been initialized yet.
    public private(set) var protocolVersion: String?
    /// The list of subscriptions
    var subscriptions: [String: Set<RequestId>] = [:]
    /// Protocol logger (required by ProtocolLayer).
    /// Stored during start() since connection.logger is async.
    package var protocolLogger: Logger?
    /// Per-session minimum log levels set by clients.
    ///
    /// For HTTP transports with multiple concurrent clients, each session can
    /// independently set its own log level. The key is the session ID (`nil` for
    /// transports without session support like stdio).
    ///
    /// Log messages below a session's level will be filtered out for that session.
    var loggingLevels: [String?: LoggingLevel] = [:]

    /// JSON Schema validator for validating elicitation responses.
    let validator: any JSONSchemaValidator

    let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    let decoder = JSONDecoder()

    public init(
        name: String,
        version: String,
        title: String? = nil,
        description: String? = nil,
        icons: [Icon]? = nil,
        websiteUrl: String? = nil,
        instructions: String? = nil,
        capabilities: Server.Capabilities = .init(),
        configuration: Configuration = .default,
        validator: (any JSONSchemaValidator)? = nil
    ) {
        serverInfo = Server.Info(
            name: name,
            version: version,
            title: title,
            description: description,
            icons: icons,
            websiteUrl: websiteUrl
        )
        self.capabilities = capabilities
        self.configuration = configuration
        self.instructions = instructions
        self.validator = validator ?? DefaultJSONSchemaValidator()
    }

    /// Start the server
    /// - Parameters:
    ///   - transport: The transport to use for the server
    ///   - initializeHook: An optional hook that runs when the client sends an initialize request
    public func start(
        transport: any Transport,
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)? = nil
    ) async throws {
        registerDefaultHandlers(initializeHook: initializeHook)
        await transport.setSupportedProtocolVersions(configuration.supportedProtocolVersions)
        try await transport.connect()

        // Cache logger for protocol conformance (avoids async access)
        protocolLogger = await transport.logger

        protocolLogger?.debug(
            "Server started", metadata: ["name": "\(name)", "version": "\(version)"]
        )

        // Configure close callback for disconnect handling.
        protocolState.onClose = { [weak self] in
            guard let self else { return }
            await protocolLogger?.debug("Server finished", metadata: [:])
            await onDisconnect?()
        }

        // Start the message loop (transport is already connected)
        startProtocolOnConnectedTransport(transport)
    }

    /// Stop the server
    public func stop() async {
        // Cancel all in-flight request handlers
        for (requestId, handlerTask) in registeredHandlers.inFlightHandlerTasks {
            handlerTask.cancel()
            protocolLogger?.debug(
                "Cancelled in-flight request during shutdown",
                metadata: ["id": "\(requestId)"]
            )
        }
        registeredHandlers.inFlightHandlerTasks.removeAll()

        // Disconnect via protocol conformance (cancels message loop, fails pending, disconnects transport)
        await stopProtocol()

        protocolLogger = nil
    }

    public func waitUntilCompleted() async {
        await waitForProtocolMessageLoop()
    }

    // MARK: - Registration

    /// Register a method handler with access to request context.
    ///
    /// The context provides capabilities like sending notifications during request
    /// processing, with correct routing to the requesting client.
    ///
    /// - Parameters:
    ///   - type: The method type to handle
    ///   - handler: The handler function receiving parameters and context
    public func withRequestHandler<M: Method>(
        _: M.Type,
        handler: @escaping @Sendable (M.Parameters, RequestHandlerContext) async throws -> M.Result
    ) {
        registeredHandlers.methodHandlers[M.name] = TypedRequestHandler {
            (request: Request<M>, context: RequestHandlerContext) -> Response<M> in
            let result = try await handler(request.params, context)
            return Response(id: request.id, result: result)
        }
    }

    /// Register a method handler without context.
    ///
    /// - Parameters:
    ///   - type: The method type to handle
    ///   - handler: The handler function receiving only parameters
    @available(
        *, deprecated,
        message:
        "Use withRequestHandler(_:handler:) with RequestHandlerContext for correct notification routing"
    )
    public func withRequestHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) {
        withRequestHandler(type) { params, _ in
            try await handler(params)
        }
    }

    // MARK: - Deprecated Method Handler Registration

    /// Register a request handler for a method (deprecated, use withRequestHandler instead)
    @available(*, deprecated, renamed: "withRequestHandler")
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters, RequestHandlerContext) async throws -> M.Result
    ) {
        withRequestHandler(type, handler: handler)
    }

    /// Register a request handler for a method (deprecated, use withRequestHandler instead)
    @available(*, deprecated, renamed: "withRequestHandler")
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) {
        withRequestHandler(type, handler: handler)
    }

    /// Register a notification handler.
    public func onNotification<N: Notification>(
        _: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) {
        registeredHandlers.notificationHandlers[N.name, default: []].append(TypedNotificationHandler(handler))
    }

    // MARK: - Fallback Handlers

    /// Set a fallback handler for requests with no specific handler registered.
    ///
    /// This handler is called for any incoming client request that doesn't have
    /// a specific handler registered. Useful for:
    /// - Debugging: log all unhandled requests
    /// - Forward-compatibility: handle new MCP methods without code changes
    /// - Testing: capture requests for verification
    ///
    /// - Parameter handler: The fallback handler. Receives the raw request and context,
    ///   and should return a response. If the handler throws, the error is converted
    ///   to an error response.
    ///
    /// ## Example
    ///
    /// ```swift
    /// await server.setFallbackRequestHandler { request, context in
    ///     print("Unhandled request: \(request.method)")
    ///     throw MCPError.methodNotFound("Unknown method: \(request.method)")
    /// }
    /// ```
    public func setFallbackRequestHandler(
        _ handler: @escaping @Sendable (Request<AnyMethod>, RequestHandlerContext) async throws -> Response<AnyMethod>
    ) {
        registeredHandlers.fallbackRequestHandler = AnyRequestHandler(handler)
    }

    /// Set a fallback handler for notifications with no specific handler registered.
    ///
    /// This handler is called for any incoming client notification that doesn't have
    /// a specific handler registered. Useful for:
    /// - Debugging: log all unhandled notifications
    /// - Forward-compatibility: observe new MCP notifications without code changes
    ///
    /// - Parameter handler: The fallback handler. Receives the raw notification.
    ///
    /// ## Example
    ///
    /// ```swift
    /// await server.setFallbackNotificationHandler { notification in
    ///     print("Unhandled notification: \(notification.method)")
    /// }
    /// ```
    public func setFallbackNotificationHandler(
        _ handler: @escaping @Sendable (Message<AnyNotification>) async throws -> Void
    ) {
        registeredHandlers.fallbackNotificationHandler = AnyNotificationHandler(handler)
    }

    /// Register a response router to intercept responses before normal handling.
    ///
    /// Response routers are checked in order before falling back to the default
    /// pending request handling. This is used by TaskResultHandler to route
    /// responses for queued task requests back to their resolvers.
    ///
    /// - Important: This is an experimental API that may change without notice.
    ///
    /// - Parameter router: The response router to add
    public func addResponseRouter(_ router: any ResponseRouter) {
        addProtocolResponseRouter(router)
    }

    func registerDefaultHandlers(
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)?
    ) {
        // Initialize
        withRequestHandler(Initialize.self) { [weak self] params, _ in
            guard let self else {
                throw MCPError.internalError("Server was deallocated")
            }

            guard await !isInitialized else {
                throw MCPError.invalidRequest("Server is already initialized")
            }

            // Call initialization hook if registered
            if let hook = initializeHook {
                try await hook(params.clientInfo, params.capabilities)
            }

            // Perform version negotiation
            let clientRequestedVersion = params.protocolVersion
            let supportedVersions = configuration.supportedProtocolVersions
            let negotiatedProtocolVersion = supportedVersions.contains(clientRequestedVersion)
                ? clientRequestedVersion
                : supportedVersions[0]

            // Set initial state with the negotiated protocol version
            await setInitialState(
                clientInfo: params.clientInfo,
                clientCapabilities: params.capabilities,
                protocolVersion: negotiatedProtocolVersion
            )

            return await Initialize.Result(
                protocolVersion: negotiatedProtocolVersion,
                capabilities: capabilities,
                serverInfo: serverInfo,
                instructions: instructions
            )
        }

        // Ping
        withRequestHandler(Ping.self) { _, _ in Empty() }

        // CancelledNotification: Handle cancellation of in-flight requests
        onNotification(CancelledNotification.self) { [weak self] message in
            guard let self else { return }
            guard let requestId = message.params.requestId else {
                // Per protocol 2025-11-25+, requestId is optional.
                // If not provided, we cannot cancel a specific request.
                return
            }
            await cancelInFlightRequest(requestId, reason: message.params.reason)
        }

        // Logging: Set minimum log level (only if logging capability is enabled)
        if capabilities.logging != nil {
            withRequestHandler(SetLoggingLevel.self) { [weak self] params, context in
                guard let self else {
                    throw MCPError.internalError("Server was deallocated")
                }
                await setLoggingLevel(params.level, forSession: context.sessionId)
                return Empty()
            }
        }
    }

    /// Set the minimum log level for messages sent to a specific session.
    ///
    /// After this is set, only log messages at this level or higher (more severe)
    /// will be sent to clients in this session via `sendLogMessage`.
    ///
    /// - Parameters:
    ///   - level: The minimum log level to send.
    ///   - sessionId: The session identifier, or `nil` for transports without sessions.
    func setLoggingLevel(_ level: LoggingLevel, forSession sessionId: String?) {
        loggingLevels[sessionId] = level
    }

    /// Check if a log message at the given level should be sent to a specific session.
    ///
    /// Returns `false` if:
    /// - The logging capability is not declared, OR
    /// - The message level is below the minimum level set by the client for this session
    ///
    /// - Parameters:
    ///   - level: The level of the log message to check.
    ///   - sessionId: The session identifier, or `nil` for transports without sessions.
    /// - Returns: `true` if the message should be sent, `false` if it should be filtered out.
    func shouldSendLogMessage(at level: LoggingLevel, forSession sessionId: String?) -> Bool {
        // Check if logging capability is declared (matching TypeScript SDK behavior)
        guard capabilities.logging != nil else { return false }

        guard let sessionLevel = loggingLevels[sessionId] else {
            // If no level is set for this session, send all messages (per MCP spec:
            // "If no logging/setLevel request has been sent from the client, the server
            // MAY decide which messages to send automatically")
            return true
        }
        return level.isAtLeast(sessionLevel)
    }

    func setInitialState(
        clientInfo: Client.Info,
        clientCapabilities: Client.Capabilities,
        protocolVersion: String
    ) async {
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.protocolVersion = protocolVersion
        isInitialized = true
    }

    // MARK: - ProtocolLayer

    /// Handle an incoming request from the client.
    /// Spawns handler in a separate Task to avoid blocking the message loop.
    package func handleIncomingRequest(_ request: AnyRequest, data _: Data, context messageContext: MessageMetadata?) async {
        let requestId = request.id
        let handlerTask = Task { [weak self, messageContext] in
            guard let self else { return }
            defer {
                Task { await self.removeInFlightRequest(requestId) }
            }
            do {
                _ = try await handleRequest(
                    request, sendResponse: true, messageContext: messageContext
                )
            } catch {
                await protocolLogger?.error(
                    "Error sending response",
                    metadata: [
                        "error": "\(error)", "requestId": "\(request.id)",
                    ]
                )
            }
        }
        trackInFlightRequest(requestId, task: handlerTask)
    }

    /// Handle an incoming notification from the client.
    package func handleIncomingNotification(_ notification: AnyMessage, data _: Data) async {
        do {
            try await handleMessage(notification)
        } catch {
            protocolLogger?.error(
                "Error handling notification",
                metadata: ["method": "\(notification.method)", "error": "\(error)"]
            )
        }
    }

    /// Called when the connection closes unexpectedly.
    /// The `onDisconnect` callback is not called here — it fires through `protocolState.onClose`
    /// when the protocol layer transitions to `.disconnected`, ensuring it only fires once.
    package func handleConnectionClosed() async {
        // Cancel all in-flight request handlers
        for (requestId, handlerTask) in registeredHandlers.inFlightHandlerTasks {
            handlerTask.cancel()
            protocolLogger?.debug(
                "Cancelled in-flight request on disconnect",
                metadata: ["id": "\(requestId)"]
            )
        }
        registeredHandlers.inFlightHandlerTasks.removeAll()
    }

    /// Handle unknown/malformed messages by sending error responses.
    package func handleUnknownMessage(_ data: Data, context _: MessageMetadata?) async {
        // Try to extract a request ID from raw JSON for the error response
        var requestID: RequestId = .random
        if let json = try? JSONDecoder().decode([String: Value].self, from: data),
           let idValue = json["id"]
        {
            if let strValue = idValue.stringValue {
                requestID = .string(strValue)
            } else if let intValue = idValue.intValue {
                requestID = .number(intValue)
            }
        }
        protocolLogger?.error(
            "Error processing message",
            metadata: ["error": "Invalid message format"]
        )
        let response = AnyMethod.response(
            id: requestID,
            error: MCPError.parseError("Invalid message format")
        )
        try? await send(response)
    }

    /// Preprocess a message before standard handling.
    /// Detects batch requests (JSON arrays) and handles them separately.
    package func preprocessMessage(_ data: Data, context messageContext: MessageMetadata?) async -> MessagePreprocessResult {
        if let batch = try? decoder.decode(Server.Batch.self, from: data) {
            // Spawn batch handler in a separate task to support nested server→client
            // requests within batch item handlers.
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await handleBatch(batch, messageContext: messageContext)
                } catch {
                    await protocolLogger?.error(
                        "Error handling batch",
                        metadata: ["error": "\(error)"]
                    )
                }
            }
            return .handled
        }
        return .continue(data)
    }
}

extension Server.Batch: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var items: [Item] = []
        for item in try container.decode([Value].self) {
            let data = try encoder.encode(item)
            try items.append(decoder.decode(Item.self, from: data))
        }

        self.items = items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(items)
    }
}

extension Server.Batch.Item: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Check if it's a request (has id) or notification (no id)
        if container.contains(.id) {
            self = try .request(Request<AnyMethod>(from: decoder))
        } else {
            self = try .notification(Message<AnyNotification>(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
            case let .request(request):
                try request.encode(to: encoder)
            case let .notification(notification):
                try notification.encode(to: encoder)
        }
    }
}
