// Copyright © Anthony DePasquale

import Foundation
import Logging

/// High-level MCP client providing automatic reconnection, health monitoring,
/// and transparent retry on recoverable errors.
///
/// `MCPClient` wraps `Client` the same way `MCPServer` wraps `Server`:
/// - `MCPServer` manages sessions, shared registries, notification broadcasting
/// - `MCPClient` manages connection lifecycle, reconnection, health monitoring
///
/// These features work with any transport. For example, if a stdio server process
/// crashes, `MCPClient` re-invokes the transport factory to spawn a new process.
/// When used with `HTTPClientTransport`, `MCPClient` additionally hooks into
/// session expiration and event stream status callbacks for proactive reconnection.
///
/// ## Key Behaviors
///
/// - **Automatic reconnection**: When the connection drops or a session expires,
///   `MCPClient` creates a fresh transport and reconnects the underlying `Client`.
/// - **Deduplication**: Multiple concurrent failures trigger only one reconnection.
/// - **Transparent retry**: Protocol methods catch recoverable errors (session
///   expiration, connection closed, transport errors), reconnect, and retry the
///   operation once before propagating the error.
/// - **Health monitoring**: Optional periodic ping detects stale connections proactively.
///
/// ## Example
///
/// ```swift
/// let mcpClient = MCPClient(name: "MyApp", version: "1.0")
///
/// // Register handlers before connecting (same as Client)
/// await mcpClient.client.withSamplingHandler { params, context in
///     // handle sampling
/// }
///
/// // Connect with a transport factory (re-invoked on reconnection)
/// try await mcpClient.connect {
///     HTTPClientTransport(endpoint: URL(string: "https://example.com/mcp")!)
/// }
///
/// // Tool calls automatically retry on session expiration
/// let result = try await mcpClient.callTool(name: "my_tool", arguments: ["key": .string("value")])
/// ```
public actor MCPClient {
    // MARK: - Configuration

    /// Options controlling reconnection behavior.
    public struct ReconnectionOptions: Sendable {
        /// Maximum number of reconnection attempts before giving up.
        public var maxRetries: Int

        /// Initial delay before the first reconnection attempt.
        public var initialDelay: Duration

        /// Maximum delay between reconnection attempts.
        public var maxDelay: Duration

        /// Multiplier applied to the delay after each failed attempt.
        public var delayGrowFactor: Double

        /// Interval for periodic health check pings.
        /// Set to `nil` to disable periodic health checks.
        ///
        /// When the transport supports streaming, the event stream acts as a health signal
        /// via the `onSessionExpired` callback. Periodic pings serve as a fallback
        /// for transports without persistent connections.
        public var healthCheckInterval: Duration?

        /// Default reconnection options.
        public static let `default` = ReconnectionOptions(
            maxRetries: 3,
            initialDelay: .seconds(1),
            maxDelay: .seconds(30),
            delayGrowFactor: 2.0,
            healthCheckInterval: .seconds(60)
        )

        public init(
            maxRetries: Int = 3,
            initialDelay: Duration = .seconds(1),
            maxDelay: Duration = .seconds(30),
            delayGrowFactor: Double = 2.0,
            healthCheckInterval: Duration? = .seconds(60)
        ) {
            self.maxRetries = maxRetries
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
            self.delayGrowFactor = delayGrowFactor
            self.healthCheckInterval = healthCheckInterval
        }
    }

    /// Connection state.
    public enum ConnectionState: Sendable, Equatable {
        /// Not connected to any server.
        case disconnected
        /// Establishing initial connection.
        case connecting
        /// Connected and ready for requests.
        case connected
        /// Reconnecting after a connection failure or session expiration.
        case reconnecting(attempt: Int)
    }

    // MARK: - Public State

    /// The current connection state.
    public private(set) var state: ConnectionState = .disconnected

    /// The underlying `Client` instance.
    ///
    /// Use this to register notification/request handlers before calling `connect()`,
    /// or to access protocol methods not wrapped by `MCPClient`.
    ///
    /// Handlers registered on this client survive reconnection – the same `Client`
    /// instance is reused across reconnections with fresh transports.
    public nonisolated let client: Client

    /// Reconnection options.
    public let reconnectionOptions: ReconnectionOptions

    // MARK: - Observation

    /// Called when connection state changes.
    public var onStateChanged: (@Sendable (ConnectionState) async -> Void)?

    /// Sets the callback invoked when connection state changes.
    public func setOnStateChanged(_ callback: (@Sendable (ConnectionState) async -> Void)?) {
        onStateChanged = callback
    }

    /// Called when the server's tool list changes.
    ///
    /// This fires in two situations:
    /// - The server sends a ``ToolListChangedNotification``
    /// - Tools are refreshed after a successful reconnection
    ///
    /// Provides the updated tool list from the server.
    public var onToolsChanged: (@Sendable ([Tool]) async -> Void)?

    /// Sets the callback invoked when the server's tool list changes.
    public func setOnToolsChanged(_ callback: (@Sendable ([Tool]) async -> Void)?) {
        onToolsChanged = callback
    }

    /// Called when the event stream status changes.
    ///
    /// This fires independently of `ConnectionState` because event stream disruptions
    /// don't prevent POST-based tool calls from succeeding. See ``EventStreamStatus``.
    public var onEventStreamStatusChanged: (@Sendable (EventStreamStatus) async -> Void)?

    /// Sets the callback invoked when the event stream status changes.
    public func setOnEventStreamStatusChanged(_ callback: (@Sendable (EventStreamStatus) async -> Void)?) {
        onEventStreamStatusChanged = callback
    }

    // MARK: - Private State

    /// Whether the ToolListChangedNotification handler has been registered on the underlying client.
    /// Guarded to prevent duplicate handlers when `connect()` is called multiple times.
    private var toolListChangedHandlerRegistered: Bool = false

    /// Factory for creating fresh transport instances on reconnection.
    private var transportFactory: (@Sendable () async throws -> any Transport)?

    /// The active reconnection task, if any. Used for deduplication.
    private var reconnectionTask: Task<Void, Error>?

    /// The health check task, if active.
    private var healthCheckTask: Task<Void, Never>?

    /// Logger instance.
    private nonisolated let logger: Logger

    // MARK: - Initialization

    /// Creates a new MCPClient.
    ///
    /// After creating the client, register any notification/request handlers on
    /// `client` before calling `connect()`.
    ///
    /// - Parameters:
    ///   - name: The client name sent to servers during initialization.
    ///   - version: The client version sent to servers during initialization.
    ///   - reconnectionOptions: Options controlling reconnection behavior.
    ///   - capabilities: Explicit capability overrides for the underlying client.
    ///   - configuration: Configuration for the underlying client.
    ///   - logger: Optional logger for MCPClient events.
    public init(
        name: String,
        version: String,
        reconnectionOptions: ReconnectionOptions = .default,
        capabilities: Client.Capabilities? = nil,
        configuration: Client.Configuration = .default,
        logger: Logger? = nil
    ) {
        client = Client(
            name: name,
            version: version,
            capabilities: capabilities,
            configuration: configuration
        )
        self.reconnectionOptions = reconnectionOptions
        self.logger = logger ?? Logger(
            label: "mcp.client.managed",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
    }

    // MARK: - Connection Lifecycle

    /// Connects to an MCP server using a transport factory.
    ///
    /// The transport factory is stored and re-invoked on reconnection to create
    /// fresh transport instances. This is necessary because transports cannot be
    /// reused after disconnection (session state, streams, etc. are invalidated).
    ///
    /// - Parameter transport: A closure that creates a new transport instance.
    ///   Called on initial connection and on every reconnection attempt.
    /// - Throws: `MCPError` if connection or initialization fails.
    @discardableResult
    public func connect(
        transport: @escaping @Sendable () async throws -> any Transport
    ) async throws -> Initialize.Result {
        // Clean up any existing connection before establishing a new one
        if state != .disconnected {
            await disconnect()
        }

        // Register ToolListChangedNotification handler once, before first connection.
        // When the server signals that its tool list has changed, we refresh the list
        // and surface the update through the same onToolsChanged callback used after
        // reconnection – so consumers get a single callback for both cases.
        if !toolListChangedHandlerRegistered {
            toolListChangedHandlerRegistered = true
            await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
                guard let self else { return }
                await refreshToolsAndNotify()
            }
        }

        transportFactory = transport
        state = .connecting
        await notifyStateChanged()

        do {
            let result = try await connectInternal()
            state = .connected
            await notifyStateChanged()
            startHealthCheckIfNeeded()
            return result
        } catch {
            state = .disconnected
            await notifyStateChanged()
            throw error
        }
    }

    /// Disconnects from the server and cancels any reconnection attempts.
    ///
    /// After disconnecting, the client can be reconnected by calling `connect()` again.
    public func disconnect() async {
        // Cancel ongoing reconnection and health checks
        reconnectionTask?.cancel()
        reconnectionTask = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil

        await client.disconnect()

        state = .disconnected
        await notifyStateChanged()
    }

    // MARK: - Protocol Methods (with transparent reconnection)

    /// Calls a tool on the server, with automatic reconnection and retry on session expiration.
    ///
    /// If the call fails due to session expiration or connection loss, `MCPClient` will:
    /// 1. Trigger reconnection (or join an existing reconnection attempt)
    /// 2. Wait for reconnection to complete
    /// 3. Retry the tool call once on the fresh connection
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Optional arguments to pass to the tool.
    /// - Returns: The tool call result.
    /// - Throws: `MCPError` if the call fails after retry.
    public func callTool(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> CallTool.Result {
        try await withReconnection {
            try await $0.callTool(name: name, arguments: arguments)
        }
    }

    /// Calls a tool with progress notifications.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Optional arguments to pass to the tool.
    ///   - onProgress: A callback invoked when progress notifications are received.
    /// - Returns: The tool call result.
    /// - Throws: `MCPError` if the call fails after retry.
    public func callTool(
        name: String,
        arguments: [String: Value]? = nil,
        onProgress: @escaping ProgressCallback
    ) async throws -> CallTool.Result {
        try await withReconnection {
            try await $0.callTool(name: name, arguments: arguments, onProgress: onProgress)
        }
    }

    /// Lists available tools from the server.
    public func listTools(cursor: String? = nil) async throws -> ListTools.Result {
        try await withReconnection {
            try await $0.listTools(cursor: cursor)
        }
    }

    /// Lists available resources from the server.
    public func listResources(cursor: String? = nil) async throws -> ListResources.Result {
        try await withReconnection {
            try await $0.listResources(cursor: cursor)
        }
    }

    /// Lists available prompts from the server.
    public func listPrompts(cursor: String? = nil) async throws -> ListPrompts.Result {
        try await withReconnection {
            try await $0.listPrompts(cursor: cursor)
        }
    }

    /// Reads a resource by URI.
    public func readResource(uri: String) async throws -> ReadResource.Result {
        try await withReconnection {
            try await $0.readResource(uri: uri)
        }
    }

    /// Gets a prompt by name.
    public func getPrompt(
        name: String,
        arguments: [String: String]? = nil
    ) async throws -> GetPrompt.Result {
        try await withReconnection {
            try await $0.getPrompt(name: name, arguments: arguments)
        }
    }

    /// Pings the server to verify the connection is alive.
    ///
    /// Unlike other protocol methods, ping does NOT trigger reconnection on failure.
    /// Instead, a failed ping triggers reconnection as a side effect (via health monitoring),
    /// and the error is propagated to the caller.
    public func ping() async throws {
        try await client.ping()
    }

    // MARK: - Reconnection

    /// Executes an operation on the underlying client with transparent reconnection.
    ///
    /// If the operation fails with a session expiration or connection error,
    /// triggers reconnection and retries the operation once. If reconnection is
    /// already in progress (e.g., triggered by the event stream), the call waits
    /// for it to complete rather than failing immediately.
    private func withReconnection<T: Sendable>(
        _ operation: @Sendable (Client) async throws -> T
    ) async throws -> T {
        // If reconnection is already in progress, wait for it before attempting the operation.
        if case .reconnecting = state {
            try await reconnectAndWait()
        }

        guard state == .connected else {
            throw MCPError.connectionClosed
        }

        do {
            return try await operation(client)
        } catch {
            guard shouldReconnect(for: error) else { throw error }

            logger.info("Operation failed with recoverable error, attempting reconnection", metadata: [
                "error": "\(error)",
            ])

            try await reconnectAndWait()
            // Single retry after reconnection
            return try await operation(client)
        }
    }

    /// Determines whether an error should trigger reconnection.
    private nonisolated func shouldReconnect(for error: Error) -> Bool {
        guard let mcpError = error as? MCPError else { return false }
        switch mcpError {
            case .connectionClosed:
                return true
            case .sessionExpired:
                return true
            case .transportError:
                return true
            default:
                return false
        }
    }

    /// Triggers reconnection if not already in progress, then waits for completion.
    ///
    /// Multiple concurrent callers all call this method. The first spawns the
    /// reconnection task; subsequent callers await the same task.
    private func reconnectAndWait() async throws {
        if reconnectionTask == nil {
            reconnectionTask = Task {
                try await performReconnection()
            }
        }

        guard let task = reconnectionTask else { return }
        // Await the shared reconnection task
        try await task.value
    }

    /// Performs the reconnection loop with exponential backoff.
    private func performReconnection() async throws {
        guard transportFactory != nil else {
            throw MCPError.internalError("No transport factory configured")
        }

        // Stop health checks during reconnection
        healthCheckTask?.cancel()
        healthCheckTask = nil

        defer {
            reconnectionTask = nil
        }

        var attempt = 0

        while attempt < reconnectionOptions.maxRetries {
            attempt += 1
            state = .reconnecting(attempt: attempt)
            await notifyStateChanged()

            // Exponential backoff (skip delay on first attempt)
            if attempt > 1 {
                let delay = reconnectionDelay(attempt: attempt)
                logger.debug("Reconnection backoff", metadata: [
                    "attempt": "\(attempt)",
                    "delay": "\(delay)",
                ])
                try await Task.sleep(for: delay)
            }

            try Task.checkCancellation()

            do {
                // Disconnect the old connection
                await client.disconnect()

                // Connect with a fresh transport
                let result = try await connectInternal()

                state = .connected
                await notifyStateChanged()
                startHealthCheckIfNeeded()

                // Refresh tool cache and notify observers
                await refreshToolsAndNotify()

                // Signal event stream is back after full reconnection
                await onEventStreamStatusChanged?(.connected)

                logger.info("Reconnection successful", metadata: [
                    "attempt": "\(attempt)",
                    "serverName": "\(result.serverInfo.name)",
                ])
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Reconnection attempt failed", metadata: [
                    "attempt": "\(attempt)",
                    "maxRetries": "\(reconnectionOptions.maxRetries)",
                    "error": "\(error)",
                ])

                if attempt >= reconnectionOptions.maxRetries {
                    state = .disconnected
                    await notifyStateChanged()
                    throw error
                }
            }
        }

        state = .disconnected
        await notifyStateChanged()
        throw MCPError.connectionClosed
    }

    /// Calculates the reconnection delay with exponential backoff.
    private nonisolated func reconnectionDelay(attempt: Int) -> Duration {
        let seconds = Double(reconnectionOptions.initialDelay.components.seconds)
            + Double(reconnectionOptions.initialDelay.components.attoseconds) / 1e18
        let growFactor = reconnectionOptions.delayGrowFactor
        let maxSeconds = Double(reconnectionOptions.maxDelay.components.seconds)
            + Double(reconnectionOptions.maxDelay.components.attoseconds) / 1e18
        let delay = seconds * pow(growFactor, Double(attempt - 1))
        return .milliseconds(Int(min(delay, maxSeconds) * 1000))
    }

    /// Connects the underlying client using the transport factory.
    @discardableResult
    private func connectInternal() async throws -> Initialize.Result {
        guard let transportFactory else {
            throw MCPError.internalError("No transport factory configured")
        }

        let transport = try await transportFactory()

        // Hook into session expiration callback for proactive reconnection
        if let httpTransport = transport as? HTTPClientTransport {
            await httpTransport.setOnSessionExpired { [weak self] in
                guard let self else { return }
                Task {
                    await self.handleSessionExpired()
                }
            }
            await httpTransport.setOnEventStreamStatusChanged { [weak self] status in
                guard let self else { return }
                await onEventStreamStatusChanged?(status)
                if status == .failed {
                    await handleEventStreamFailed()
                }
            }
        }

        return try await client.connect(transport: transport)
    }

    /// Called by the transport when session expiration is detected (e.g., event stream gets 404).
    private func handleSessionExpired() {
        guard state == .connected else { return }
        logger.info("Session expiration detected via transport callback, triggering reconnection")

        // Fire-and-forget reconnection – callers will discover the new connection
        // on their next operation, or get an error if reconnection fails
        if reconnectionTask == nil {
            reconnectionTask = Task {
                try await performReconnection()
            }
        }
    }

    /// Called by the transport when the event stream exhausts all reconnection attempts.
    ///
    /// This triggers a full MCPClient-level reconnection (fresh transport + re-initialize)
    /// since the event stream is permanently lost.
    private func handleEventStreamFailed() {
        guard state == .connected else { return }
        logger.info("Event stream failed permanently, triggering full reconnection")

        if reconnectionTask == nil {
            reconnectionTask = Task {
                try await performReconnection()
            }
        }
    }

    /// Refreshes the tool list from the server and notifies observers via `onToolsChanged`.
    ///
    /// Called after reconnection and when the server sends a `ToolListChangedNotification`.
    private func refreshToolsAndNotify() async {
        guard state == .connected else { return }
        do {
            let result = try await client.listTools()
            await onToolsChanged?(result.tools)
        } catch {
            logger.warning("Failed to refresh tools", metadata: [
                "error": "\(error)",
            ])
        }
    }

    // MARK: - Health Monitoring

    /// Starts periodic health check pings if configured.
    private func startHealthCheckIfNeeded() {
        guard let interval = reconnectionOptions.healthCheckInterval else { return }

        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard let self else { return }

                do {
                    try await client.ping()
                } catch {
                    guard !Task.isCancelled else { return }
                    if shouldReconnect(for: error) {
                        await handleSessionExpired()
                        return // Stop pinging; reconnection will restart health checks
                    }
                }
            }
        }
    }

    // MARK: - State Notification

    private func notifyStateChanged() async {
        await onStateChanged?(state)
    }
}
