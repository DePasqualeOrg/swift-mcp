// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Logging

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Configuration for form-mode elicitation support.
public enum FormModeConfig: Sendable, Hashable {
    /// Enable form-mode elicitation.
    ///
    /// - Parameter applyDefaults: When `true`, the client applies default values from the
    ///   JSON Schema to any missing fields in the user's response before returning it to the
    ///   server. When `false` (default), missing fields are returned as-is, and the server
    ///   is responsible for applying defaults. Set to `true` if your UI framework automatically
    ///   populates form fields with schema defaults.
    case enabled(applyDefaults: Bool = false)
}

/// Configuration for URL-mode elicitation support.
public enum URLModeConfig: Sendable, Hashable {
    /// Enable URL-mode elicitation (for OAuth flows, etc.).
    case enabled
}

// MARK: - Client Handler Registry

/// Registry of handlers and their configuration for responding to server requests/notifications.
///
/// This struct consolidates all handler-related state in one place, making the
/// coupling between handlers and capabilities explicit. It's named "Registry" rather
/// than "Handlers" because it contains both handlers AND configuration that affects
/// capability inference.
///
/// The `inferredCapabilities` computed property derives capabilities from the registered
/// handlers, following the Python SDK's `ExperimentalTaskHandlers.build_capability()` pattern.
struct ClientHandlerRegistry: Sendable {
    // MARK: - Handlers

    /// Notification handlers keyed by method name.
    var notificationHandlers: [String: [NotificationHandlerBox]] = [:]

    /// Request handlers for server→client requests, keyed by method name.
    var requestHandlers: [String: ClientRequestHandlerBox] = [:]

    /// Task-augmented sampling handler (called when request has `task` field).
    var taskAugmentedSamplingHandler: ExperimentalClientTaskHandlers.TaskAugmentedSamplingHandler?

    /// Task-augmented elicitation handler (called when request has `task` field).
    var taskAugmentedElicitationHandler: ExperimentalClientTaskHandlers.TaskAugmentedElicitationHandler?

    // MARK: - Handler Configuration (affects inferred capabilities)

    /// Configuration for sampling handler, used to build capabilities at connect time.
    struct SamplingConfig: Sendable {
        var supportsContext: Bool
        var supportsTools: Bool
    }

    /// Configuration for elicitation handler, used to build capabilities at connect time.
    struct ElicitationConfig: Sendable {
        var formMode: FormModeConfig?
        var urlMode: URLModeConfig?
    }

    /// Configuration for roots handler, used to build capabilities at connect time.
    struct RootsConfig: Sendable {
        var listChanged: Bool
    }

    /// Sampling handler configuration (set when handler is registered).
    var samplingConfig: SamplingConfig?

    /// Elicitation handler configuration (set when handler is registered).
    var elicitationConfig: ElicitationConfig?

    /// Roots handler configuration (set when handler is registered).
    var rootsConfig: RootsConfig?

    /// Tasks capability configuration (set via withTasksCapability).
    var tasksConfig: Client.Capabilities.Tasks?

    // MARK: - Fallback Handlers

    /// Fallback handler for requests with no registered handler.
    ///
    /// If set, this handler is called for any incoming request that doesn't have
    /// a specific handler registered. Useful for debugging, logging unknown methods,
    /// or forward-compatibility with new MCP features.
    ///
    /// The handler receives the raw request and should return a response.
    /// If it throws, the error is converted to an error response.
    var fallbackRequestHandler: ClientRequestHandlerBox?

    /// Fallback handler for notifications with no registered handler.
    ///
    /// If set, this handler is called for any incoming notification that doesn't have
    /// a specific handler registered. Useful for debugging or logging unknown notifications.
    var fallbackNotificationHandler: NotificationHandlerBox?

    // MARK: - State

    /// Whether handler registration is locked (after connection).
    /// Set to `true` on the first call to `connect()` and intentionally never reset,
    /// so handlers registered before connection persist across reconnections without
    /// allowing duplicate registration.
    var isLocked = false

    // MARK: - Inferred Capabilities

    /// Infer capabilities from registered handlers and their configuration.
    ///
    /// This is used during `connect()` to build the client's advertised capabilities.
    /// The computed property follows the Python SDK's `ExperimentalTaskHandlers.build_capability()`
    /// pattern where capability presence is inferred from which handlers are registered.
    func inferCapabilities() -> Client.Capabilities {
        var caps = Client.Capabilities()

        // Sampling capability
        if let config = samplingConfig {
            caps.sampling = .init(
                context: config.supportsContext ? .init() : nil,
                tools: config.supportsTools ? .init() : nil
            )
        }

        // Elicitation capability
        if let config = elicitationConfig {
            caps.elicitation = .init(
                form: config.formMode.map { mode in
                    switch mode {
                        case let .enabled(applyDefaults):
                            .init(applyDefaults: applyDefaults ? true : nil)
                    }
                },
                url: config.urlMode.map { _ in .init() }
            )
        }

        // Roots capability
        if let config = rootsConfig {
            caps.roots = .init(listChanged: config.listChanged ? true : nil)
        }

        // Tasks capability: use explicit config if provided, otherwise infer from handlers.
        // This matches Python SDK's pattern where task-augmented handler presence
        // determines capability advertisement.
        if let config = tasksConfig {
            caps.tasks = config
        } else if taskAugmentedSamplingHandler != nil || taskAugmentedElicitationHandler != nil {
            // Infer tasks.requests capability from registered task-augmented handlers
            var requestsCap = Client.Capabilities.Tasks.Requests()
            if taskAugmentedSamplingHandler != nil {
                requestsCap.sampling = Client.Capabilities.Tasks.Requests.Sampling(
                    createMessage: Client.Capabilities.Tasks.Requests.Sampling.CreateMessage()
                )
            }
            if taskAugmentedElicitationHandler != nil {
                requestsCap.elicitation = Client.Capabilities.Tasks.Requests.Elicitation(
                    create: Client.Capabilities.Tasks.Requests.Elicitation.Create()
                )
            }
            caps.tasks = Client.Capabilities.Tasks(requests: requestsCap)
        }

        return caps
    }
}

/// Model Context Protocol client
public actor Client: ProtocolLayer {
    /// The client configuration
    public struct Configuration: Hashable, Codable, Sendable {
        /// The default configuration.
        public static let `default` = Configuration(strict: false)

        /// The strict configuration.
        public static let strict = Configuration(strict: true)

        /// When strict mode is enabled, the client:
        /// - Requires server capabilities to be initialized before making requests
        /// - Rejects all requests that require capabilities before initialization
        ///
        /// While the MCP specification requires servers to respond to initialize requests
        /// with their capabilities, some implementations may not follow this.
        /// Disabling strict mode allows the client to be more lenient with non-compliant
        /// servers, though this may lead to undefined behavior.
        public var strict: Bool

        /// Protocol versions supported by this client, ordered by preference.
        ///
        /// The first element is the preferred version, sent in the initialize request.
        /// The server's response is validated against this list. Defaults to
        /// `Version.supported`.
        ///
        /// - Precondition: Must not be empty.
        public var supportedProtocolVersions: [String]

        public init(
            strict: Bool = false,
            supportedProtocolVersions: [String] = Version.supported
        ) {
            precondition(!supportedProtocolVersions.isEmpty, "supportedProtocolVersions must not be empty")
            self.strict = strict
            self.supportedProtocolVersions = supportedProtocolVersions
        }
    }

    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The client name
        public var name: String
        /// The client version
        public var version: String
        /// A human-readable title for the client, intended for UI display.
        /// If not provided, the `name` should be used for display.
        public var title: String?
        /// An optional human-readable description of what this implementation does.
        public var description: String?
        /// Optional icons representing this implementation.
        public var icons: [Icon]?
        /// An optional URL of the website for this implementation.
        public var websiteUrl: String?

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

    /// The client capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// The roots capabilities
        public struct Roots: Hashable, Codable, Sendable {
            /// Whether the list of roots has changed
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// The sampling capabilities
        public struct Sampling: Hashable, Codable, Sendable {
            /// Context capability for sampling requests.
            ///
            /// When declared, indicates the client supports the `includeContext` parameter
            /// with values "thisServer" and "allServers". If not declared, servers should
            /// only use `includeContext: "none"` (or omit it).
            public struct Context: Hashable, Codable, Sendable {
                public init() {}
            }

            /// Tools capability for sampling requests
            public struct Tools: Hashable, Codable, Sendable {
                public init() {}
            }

            /// Whether the client supports includeContext parameter
            public var context: Context?
            /// Whether the client supports tools in sampling requests
            public var tools: Tools?

            public init(context: Context? = nil, tools: Tools? = nil) {
                self.context = context
                self.tools = tools
            }
        }

        /// The elicitation capabilities
        public struct Elicitation: Hashable, Codable, Sendable {
            /// Form mode capabilities
            public struct Form: Hashable, Codable, Sendable {
                /// Whether the client applies schema defaults to missing fields.
                public var applyDefaults: Bool?

                public init(applyDefaults: Bool? = nil) {
                    self.applyDefaults = applyDefaults
                }
            }

            /// URL mode capabilities (for out-of-band flows like OAuth)
            public struct URL: Hashable, Codable, Sendable {
                public init() {}
            }

            /// Form mode capabilities
            public var form: Form?
            /// URL mode capabilities
            public var url: URL?

            public init(form: Form? = nil, url: URL? = nil) {
                self.form = form
                self.url = url
            }
        }

        /// Whether the client supports sampling
        public var sampling: Sampling?
        /// Whether the client supports elicitation (user input requests)
        public var elicitation: Elicitation?
        /// Experimental, non-standard capabilities that the client supports.
        public var experimental: [String: [String: Value]]?
        /// Whether the client supports roots
        public var roots: Capabilities.Roots?
        /// Task capabilities (experimental, for bidirectional task support)
        public var tasks: Tasks?

        public init(
            sampling: Sampling? = nil,
            elicitation: Elicitation? = nil,
            experimental: [String: [String: Value]]? = nil,
            roots: Capabilities.Roots? = nil,
            tasks: Tasks? = nil
        ) {
            self.sampling = sampling
            self.elicitation = elicitation
            self.experimental = experimental
            self.roots = roots
            self.tasks = tasks
        }
    }

    /// Protocol state for JSON-RPC message handling.
    package var protocolState = ProtocolState()

    /// Protocol logger, set from transport during `connect()`.
    package var protocolLogger: Logger?

    /// The logger for the client.
    var logger: Logger? { protocolLogger }

    /// The client information
    let clientInfo: Client.Info
    /// The client name
    public nonisolated var name: String { clientInfo.name }
    /// The client version
    public nonisolated var version: String { clientInfo.version }

    /// The client capabilities
    public var capabilities: Client.Capabilities
    /// The client configuration
    public let configuration: Configuration

    /// Experimental APIs for tasks and other features.
    ///
    /// Access experimental features via this property:
    /// ```swift
    /// let result = try await client.experimental.tasks.callToolAsTask(name: "tool", arguments: [:])
    /// let status = try await client.experimental.tasks.getTask(result.task.taskId)
    /// ```
    ///
    /// - Note: These APIs are experimental and may change without notice.
    public var experimental: ExperimentalClientFeatures {
        ExperimentalClientFeatures(client: self)
    }

    /// The server capabilities received during initialization.
    ///
    /// Use this to check what capabilities the server supports after connecting.
    /// Returns `nil` if the client has not been initialized yet.
    public private(set) var serverCapabilities: Server.Capabilities?

    /// The server information received during initialization.
    ///
    /// Contains the server's name, version, and optional metadata like title and description.
    /// Returns `nil` if the client has not been initialized yet.
    public private(set) var serverInfo: Server.Info?

    /// The protocol version negotiated during initialization.
    ///
    /// Returns `nil` if the client has not been initialized yet.
    public private(set) var protocolVersion: String?

    /// Instructions from the server describing how to use its features.
    ///
    /// This can be used to improve the LLM's understanding of available tools, resources, etc.
    /// Returns `nil` if the client has not been initialized or the server didn't provide instructions.
    public private(set) var instructions: String?

    /// Registry of handlers and their configuration.
    /// All handler-related state is consolidated here for clarity.
    var registeredHandlers = ClientHandlerRegistry()

    /// Continuation for the notification dispatch stream.
    ///
    /// User-registered notification handlers are dispatched through this stream
    /// rather than being awaited inline in the message loop. This prevents deadlocks
    /// when a handler makes a request back to the server (the message loop must remain
    /// free to process the response). Matches the TypeScript SDK which dispatches
    /// notification handlers via `Promise.resolve().then()`.
    var notificationContinuation: AsyncStream<Message<AnyNotification>>.Continuation?

    /// The task that consumes the notification dispatch stream and invokes handlers.
    var notificationTask: Task<Void, Never>?

    /// Explicit capability overrides from initializer.
    /// Only non-nil fields override auto-detection.
    let explicitCapabilities: Capabilities?

    /// Whether the CancelledNotification handler has been registered.
    /// Prevents duplicate registration when `connect()` is called multiple times (e.g., reconnection).
    private var cancelledNotificationRegistered: Bool = false

    /// In-flight server request handler Tasks, tracked by request ID.
    /// Used for protocol-level cancellation when CancelledNotification is received.
    var inFlightServerRequestTasks: [RequestId: Task<Void, Never>] = [:]

    /// JSON Schema validator for validating tool outputs.
    let validator: any JSONSchemaValidator

    /// Cached tool output schemas from listTools() calls.
    /// Used to validate tool results in callTool().
    var toolOutputSchemas: [String: Value] = [:]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    /// Initialize a new MCP client.
    ///
    /// - Parameters:
    ///   - name: The client name.
    ///   - version: The client version.
    ///   - title: A human-readable title for the client, intended for UI display.
    ///   - description: An optional human-readable description.
    ///   - icons: Optional icons representing this client.
    ///   - websiteUrl: An optional URL for the client's website.
    ///   - capabilities: Optional explicit capability overrides. Only non-nil fields override
    ///     auto-detection from handler registration. Use this for edge cases like testing,
    ///     forward compatibility with new capabilities, or advertising `experimental` capabilities.
    ///   - configuration: The client configuration.
    ///   - validator: A JSON Schema validator for validating tool outputs.
    public init(
        name: String,
        version: String,
        title: String? = nil,
        description: String? = nil,
        icons: [Icon]? = nil,
        websiteUrl: String? = nil,
        capabilities: Capabilities? = nil,
        configuration: Configuration = .default,
        validator: (any JSONSchemaValidator)? = nil
    ) {
        clientInfo = Client.Info(
            name: name,
            version: version,
            title: title,
            description: description,
            icons: icons,
            websiteUrl: websiteUrl
        )
        explicitCapabilities = capabilities
        self.capabilities = Capabilities() // Will be built at connect time
        self.configuration = configuration
        self.validator = validator ?? DefaultJSONSchemaValidator()
    }

    /// Connect to the server using the given transport.
    ///
    /// This method:
    /// 1. Establishes the transport connection
    /// 2. Builds capabilities from registered handlers and explicit overrides
    /// 3. Sends the initialization request to the server
    /// 4. Validates the server's protocol version
    ///
    /// After this method returns, the client is fully initialized and ready to make requests.
    ///
    /// - Parameter transport: The transport to use for communication.
    /// - Returns: The server's initialization response containing capabilities and server info.
    /// - Throws: `MCPError` if connection or initialization fails.
    @discardableResult
    public func connect(transport: any Transport) async throws -> Initialize.Result {
        // Build capabilities from handlers and explicit overrides
        capabilities = buildCapabilities()
        validateCapabilities(capabilities)

        // Lock handler registration after first connection
        registeredHandlers.isLocked = true

        await transport.setSupportedProtocolVersions(configuration.supportedProtocolVersions)
        try await transport.connect()
        protocolLogger = await transport.logger

        logger?.debug(
            "Client connected", metadata: ["name": "\(name)", "version": "\(version)"]
        )

        // Set up notification dispatch stream.
        // Clean up previous stream/task if connect() is called again (reconnection).
        notificationContinuation?.finish()
        notificationTask?.cancel()

        let (notificationStream, notifContinuation) = AsyncStream<Message<AnyNotification>>.makeStream()
        notificationContinuation = notifContinuation
        notificationTask = Task {
            for await notification in notificationStream {
                let handlers = registeredHandlers.notificationHandlers[notification.method] ?? []

                // Use fallback handler if no specific handlers registered
                if handlers.isEmpty, let fallbackHandler = registeredHandlers.fallbackNotificationHandler {
                    do {
                        try await fallbackHandler(notification)
                    } catch {
                        logger?.error(
                            "Error in fallback notification handler",
                            metadata: [
                                "method": "\(notification.method)",
                                "error": "\(error)",
                            ]
                        )
                    }
                } else {
                    for handler in handlers {
                        do {
                            try await handler(notification)
                        } catch {
                            logger?.error(
                                "Error handling notification",
                                metadata: [
                                    "method": "\(notification.method)",
                                    "error": "\(error)",
                                ]
                            )
                        }
                    }
                }
            }
        }

        // Configure close callback
        protocolState.onClose = { [weak self] in
            guard let self else { return }
            await cleanUpOnUnexpectedDisconnect()
        }

        // Start the message loop (transport is already connected)
        startProtocolOnConnectedTransport(transport)

        // Register default handler for CancelledNotification (protocol-level cancellation).
        // Guarded to prevent duplicate handlers when connect() is called multiple times
        // (e.g., during reconnection via MCPClient).
        if !cancelledNotificationRegistered {
            cancelledNotificationRegistered = true
            onNotification(CancelledNotification.self) { [weak self] message in
                guard let self else { return }
                guard let requestId = message.params.requestId else {
                    // Per protocol 2025-11-25+, requestId is optional.
                    // If not provided, we cannot cancel a specific request.
                    return
                }
                await cancelInFlightServerRequest(requestId, reason: message.params.reason)
            }
        }

        // Automatically initialize after connecting
        return try await _initialize()
    }

    /// Disconnect the client and cancel all pending requests
    public func disconnect() async {
        logger?.debug("Initiating client disconnect...")

        // Cancel all in-flight server request handlers
        for (requestId, handlerTask) in inFlightServerRequestTasks {
            handlerTask.cancel()
            logger?.debug(
                "Cancelled in-flight server request during disconnect",
                metadata: ["id": "\(requestId)"]
            )
        }
        inFlightServerRequestTasks.removeAll()

        // Grab notification task before clearing
        let notificationTaskToCancel = notificationTask

        notificationTask = nil
        protocolLogger = nil

        // End the notification stream so the processing task can exit
        notificationContinuation?.finish()
        notificationContinuation = nil

        // Cancel notification task
        notificationTaskToCancel?.cancel()

        // Disconnect via protocol conformance (cancels message loop, fails pending, disconnects transport)
        await stopProtocol()

        await notificationTaskToCancel?.value
    }

    /// Cleans up Client-specific state when the transport closes unexpectedly.
    func cleanUpOnUnexpectedDisconnect() {
        logger?.debug("Cleaning up Client state after unexpected disconnect")
    }

    // MARK: - ProtocolLayer

    /// Handle an incoming request from the peer (server→client).
    package func handleIncomingRequest(_ request: AnyRequest, data _: Data, context _: MessageMetadata?) async {
        await handleIncomingRequest(request)
    }

    /// Handle an incoming notification from the peer.
    package func handleIncomingNotification(_ notification: AnyMessage, data _: Data) async {
        await handleMessage(notification)
    }

    /// Called when the connection closes unexpectedly.
    package func handleConnectionClosed() async {
        cleanUpOnUnexpectedDisconnect()
    }

    /// Intercept a response before pending request matching.
    package func interceptResponse(_ response: AnyResponse) async {
        guard let id = response.id else { return }
        if case let .success(value) = response.result,
           case let .object(resultObject) = value
        {
            await checkForTaskResponse(response: Response<AnyMethod>(id: id, result: value), value: resultObject)
        }
    }

    // MARK: - In-Flight Server Request Tracking (Protocol-Level Cancellation)

    /// Track an in-flight server request handler Task.
    func trackInFlightServerRequest(_ requestId: RequestId, task: Task<Void, Never>) {
        inFlightServerRequestTasks[requestId] = task
    }

    /// Remove an in-flight server request handler Task.
    func removeInFlightServerRequest(_ requestId: RequestId) {
        inFlightServerRequestTasks.removeValue(forKey: requestId)
    }

    /// Cancel an in-flight server request handler Task.
    ///
    /// Called when a CancelledNotification is received for a specific requestId.
    /// Per MCP spec, if the request is unknown or already completed, this is a no-op.
    func cancelInFlightServerRequest(_ requestId: RequestId, reason: String?) async {
        if let task = inFlightServerRequestTasks[requestId] {
            task.cancel()
            logger?.debug(
                "Cancelled in-flight server request",
                metadata: [
                    "id": "\(requestId)",
                    "reason": "\(reason ?? "none")",
                ]
            )
        }
        // Per spec: MAY ignore if request is unknown - no error needed
    }

    // MARK: - Capability Building

    /// Build capabilities from explicit overrides and handler registrations.
    ///
    /// Uses `ClientCapabilityHelpers.merge()` to combine inferred capabilities
    /// from registered handlers with explicit overrides from the initializer.
    private func buildCapabilities() -> Capabilities {
        let inferred = registeredHandlers.inferCapabilities()

        // Log inferred capabilities at trace level to aid debugging
        logger?.trace(
            "Inferred capabilities from handlers",
            metadata: [
                "sampling": "\(inferred.sampling != nil)",
                "elicitation": "\(inferred.elicitation != nil)",
                "roots": "\(inferred.roots != nil)",
                "tasks": "\(inferred.tasks != nil)",
            ]
        )

        let merged = ClientCapabilityHelpers.merge(inferred: inferred, explicit: explicitCapabilities)

        if explicitCapabilities != nil {
            logger?.trace(
                "Merged with explicit overrides",
                metadata: [
                    "sampling": "\(merged.sampling != nil)",
                    "elicitation": "\(merged.elicitation != nil)",
                    "roots": "\(merged.roots != nil)",
                    "tasks": "\(merged.tasks != nil)",
                ]
            )
        }

        return merged
    }

    /// Validate capabilities configuration and log warnings for mismatches.
    ///
    /// Delegates to `ClientCapabilityHelpers.validate()` for the actual validation logic.
    private func validateCapabilities(_ capabilities: Capabilities) {
        ClientCapabilityHelpers.validate(capabilities, handlers: registeredHandlers, logger: logger)
    }

    // MARK: - Lifecycle

    /// Initialize the connection with the server.
    ///
    /// - Important: This method is deprecated. Initialization now happens automatically
    ///   when calling `connect(transport:)`. You should use that method instead.
    ///
    /// - Returns: The server's initialization response containing capabilities and server info
    @available(
        *, deprecated,
        message:
        "Initialization now happens automatically during connect. Use connect(transport:) instead."
    )
    public func initialize() async throws -> Initialize.Result {
        try await _initialize()
    }

    /// Internal initialization implementation
    func _initialize() async throws -> Initialize.Result {
        let supportedVersions = configuration.supportedProtocolVersions
        let request = Initialize.request(
            .init(
                protocolVersion: supportedVersions[0],
                capabilities: capabilities,
                clientInfo: clientInfo
            ))

        let result = try await send(request)

        // Per MCP spec: "If the client does not support the version in the
        // server's response, it SHOULD disconnect."
        guard supportedVersions.contains(result.protocolVersion) else {
            await disconnect()
            throw MCPError.invalidRequest(
                "Server responded with unsupported protocol version: \(result.protocolVersion). "
                    + "Supported versions: \(supportedVersions.joined(separator: ", "))"
            )
        }

        serverCapabilities = result.capabilities
        serverInfo = result.serverInfo
        protocolVersion = result.protocolVersion
        instructions = result.instructions

        // Set the negotiated protocol version on the transport.
        // HTTP transports use this to include the version in request headers.
        // Simple transports (stdio, in-memory) use the default no-op implementation.
        await protocolState.transport?.setProtocolVersion(result.protocolVersion)

        try await notify(InitializedNotification.message())

        return result
    }

    public func ping() async throws {
        let request = Ping.request()
        _ = try await send(request)
    }
}
