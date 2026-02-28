// Copyright © Anthony DePasquale

import Foundation
import Logging

// MARK: - Protocol State

/// Holds all mutable state for protocol-level JSON-RPC handling.
///
/// `Client` and `Server` each own an instance of this struct to track
/// connection state, pending requests, progress callbacks, and other
/// protocol-level concerns.
package struct ProtocolState {
    /// Current connection state.
    package var connectionState: ProtocolConnectionState = .disconnected

    /// The connected transport (convenience accessor).
    package var transport: (any Transport)? {
        if case let .connected(transport) = connectionState {
            return transport
        }
        return nil
    }

    /// Task that runs the message receive loop.
    package var messageLoopTask: Task<Void, Never>?

    /// Pending requests waiting for responses.
    package var pendingRequests: [RequestId: ProtocolPendingRequest] = [:]

    /// Progress callbacks keyed by progress token.
    package var progressCallbacks: [ProgressToken: ProtocolProgressCallback] = [:]

    /// Timeout controllers for requests with progress-aware timeouts.
    package var timeoutControllers: [ProgressToken: TimeoutController] = [:]

    /// Mapping from request ID to progress token.
    package var requestProgressTokens: [RequestId: ProgressToken] = [:]

    /// Task progress token mapping - keeps progress handlers alive after CreateTaskResult.
    package var taskProgressTokens: [String: ProgressToken] = [:]

    /// Response routers for task result handling.
    package var responseRouters: [any ResponseRouter] = []

    /// Methods that should have their notifications debounced.
    package var debouncedNotificationMethods: Set<String> = []

    /// Pending debounced notifications waiting to be sent.
    package var pendingDebouncedNotifications: Set<String> = []

    /// Tasks that flush debounced notifications, keyed by method.
    package var pendingFlushTasks: [String: Task<Void, Never>] = [:]

    /// Called when the connection is closed.
    package var onClose: (@Sendable () async -> Void)?

    /// Called when an error occurs.
    package var onError: (@Sendable (any Error) async -> Void)?

    /// Counter for generating unique request IDs.
    package var nextRequestId = 0

    package init() {}
}

// MARK: - ProtocolLayer

/// Protocol that `Client` and `Server` conform to for JSON-RPC message handling.
///
/// Conformers implement customization points (dynamic dispatch) and get
/// shared infrastructure as protocol extension methods (static dispatch).
package protocol ProtocolLayer: Actor {
    /// The mutable protocol state.
    var protocolState: ProtocolState { get set }

    /// Logger for protocol-level events.
    var protocolLogger: Logger? { get }

    // MARK: - Customization Points

    //
    // These are declared in the protocol body so they are dynamically dispatched.
    // When the message loop calls `self.handleIncomingRequest(...)`, it invokes
    // Client's or Server's override, not the default implementation.
    //
    // Do NOT add new customization points as extension-only methods -- those are
    // statically dispatched and overrides would be silently ignored when called
    // through the protocol.

    /// Handle an incoming request from the peer.
    /// Default implementation sends a "method not found" error.
    func handleIncomingRequest(_ request: AnyRequest, data: Data, context: MessageMetadata?) async

    /// Handle an incoming notification from the peer.
    /// Default implementation is a no-op.
    func handleIncomingNotification(_ notification: AnyMessage, data: Data) async

    /// Called when the connection closes unexpectedly.
    /// Default implementation is a no-op.
    func handleConnectionClosed() async

    /// Intercept a response before it is matched against pending requests.
    /// Default implementation is a no-op.
    func interceptResponse(_ response: AnyResponse) async

    /// Preprocess a message before standard handling.
    /// Default implementation returns `.continue(data)`.
    func preprocessMessage(_ data: Data, context: MessageMetadata?) async -> MessagePreprocessResult

    /// Handle a message that could not be decoded as any known JSON-RPC type.
    /// Default implementation logs a warning.
    func handleUnknownMessage(_ data: Data, context: MessageMetadata?) async

    /// Handle an error response with null or missing `id`.
    ///
    /// Per the MCP schema, `id` is not required on `JSONRPCErrorResponse`. Such errors
    /// cannot be correlated with a pending request. The default implementation logs the
    /// error code and message.
    func handleNullIdError(_ response: AnyResponse) async
}

// MARK: - Default Implementations for Customization Points

package extension ProtocolLayer {
    /// Default: send a "method not found" error response.
    func handleIncomingRequest(_ request: AnyRequest, data _: Data, context _: MessageMetadata?) async {
        await sendProtocolErrorResponse(
            id: request.id,
            error: MCPError.methodNotFound("Unknown method: \(request.method)")
        )
    }

    /// Default: no-op.
    func handleIncomingNotification(_: AnyMessage, data _: Data) async {}

    /// Default: no-op.
    func handleConnectionClosed() async {}

    /// Default: no interception.
    func interceptResponse(_: AnyResponse) async {}

    /// Default: pass through unchanged.
    func preprocessMessage(_ data: Data, context _: MessageMetadata?) async -> MessagePreprocessResult {
        .continue(data)
    }

    /// Default: log a warning.
    func handleUnknownMessage(_: Data, context _: MessageMetadata?) async {
        protocolLogger?.warning("Unknown message type received")
    }

    /// Default: log the error.
    func handleNullIdError(_ response: AnyResponse) async {
        switch response.result {
            case let .failure(error):
                protocolLogger?.error(
                    "Received error response with null/missing id",
                    metadata: ["error": "\(error)"]
                )
            case .success:
                protocolLogger?.warning("Received success response with null/missing id (schema violation)")
        }
    }
}

// MARK: - Protocol Extension Methods (Shared Infrastructure)

package extension ProtocolLayer {
    // MARK: Connection Lifecycle

    /// Connect to a transport and start processing messages.
    func startProtocol(transport: any Transport) async throws {
        guard case .disconnected = protocolState.connectionState else {
            throw MCPError.internalError("Already connected")
        }

        protocolState.connectionState = .connecting

        do {
            try await transport.connect()
            protocolState.connectionState = .connected(transport: transport)
            startProtocolMessageLoop()
        } catch {
            protocolState.connectionState = .disconnected
            throw error
        }
    }

    /// Start the message loop with an already-connected transport.
    func startProtocolOnConnectedTransport(_ transport: any Transport) {
        guard case .disconnected = protocolState.connectionState else {
            return
        }

        protocolState.connectionState = .connected(transport: transport)
        startProtocolMessageLoop()
    }

    /// Disconnect from the transport and clean up all state.
    func stopProtocol() async {
        guard case let .connected(transport) = protocolState.connectionState else {
            return
        }

        protocolState.connectionState = .disconnecting

        // Cancel the message loop and wait for it to finish.
        // Awaiting ensures the task isn't still accessing state while we clear it.
        let loopTask = protocolState.messageLoopTask
        protocolState.messageLoopTask = nil
        loopTask?.cancel()
        await loopTask?.value

        // Fail all pending requests
        let pendingToCancel = protocolState.pendingRequests
        protocolState.pendingRequests.removeAll()

        for (_, request) in pendingToCancel {
            request.resume(throwing: MCPError.connectionClosed)
        }

        // Clear pending debounced notifications and cancel flush tasks
        protocolState.pendingDebouncedNotifications.removeAll()
        for (_, task) in protocolState.pendingFlushTasks {
            task.cancel()
        }
        protocolState.pendingFlushTasks.removeAll()

        // Clear progress/timeout state
        protocolState.progressCallbacks.removeAll()
        protocolState.timeoutControllers.removeAll()
        protocolState.requestProgressTokens.removeAll()
        protocolState.taskProgressTokens.removeAll()

        // Disconnect the transport
        await transport.disconnect()

        protocolState.connectionState = .disconnected

        // Invoke close callback
        await protocolState.onClose?()
    }

    /// Wait for the message loop to complete.
    func waitForProtocolMessageLoop() async {
        await protocolState.messageLoopTask?.value
    }

    // MARK: Message Loop

    /// Start the message receive loop.
    private func startProtocolMessageLoop() {
        guard let transport = protocolState.transport else { return }

        protocolState.messageLoopTask = Task { [weak self] in
            do {
                let stream = await transport.receive()
                for try await transportMessage in stream {
                    guard !Task.isCancelled else { break }
                    await self?.handleTransportMessage(transportMessage)
                }
            } catch {
                await self?.handleMessageLoopError(error)
            }
            await self?.handleMessageLoopEnded()
        }
    }

    /// Handle a message from the transport.
    func handleTransportMessage(_ message: TransportMessage) async {
        var data = message.data
        let context = message.context

        // Run preprocessor
        switch await preprocessMessage(data, context: context) {
            case .handled:
                return
            case let .continue(processedData):
                data = processedData
        }

        let decoder = JSONDecoder()

        // Try as batch of responses
        if let responses = try? decoder.decode([AnyResponse].self, from: data) {
            for response in responses {
                if response.id != nil {
                    await handleResponse(response)
                } else {
                    await handleNullIdError(response)
                }
            }
            return
        }

        // Try as single response
        if let response = try? decoder.decode(AnyResponse.self, from: data) {
            if response.id != nil {
                await handleResponse(response)
            } else {
                await handleNullIdError(response)
            }
            return
        }

        // Try as request
        if let request = try? decoder.decode(AnyRequest.self, from: data) {
            await handleIncomingRequest(request, data: data, context: context)
            return
        }

        // Try as notification
        if let notification = try? decoder.decode(AnyMessage.self, from: data) {
            await handleNotificationInternal(notification, data: data)
            return
        }

        // Unknown message - delegate to conformer
        await handleUnknownMessage(data, context: context)
    }

    /// Handle a response message with a non-nil ID.
    ///
    /// Callers must ensure `response.id` is non-nil before calling this method.
    /// Null-id responses are routed to `handleNullIdError(_:)` instead.
    private func handleResponse(_ response: AnyResponse) async {
        guard let id = response.id else {
            assertionFailure("handleResponse called with null-id response")
            protocolLogger?.error("handleResponse called with null-id response")
            return
        }

        // Call response interceptor first
        await interceptResponse(response)

        // Check response routers
        for router in protocolState.responseRouters {
            let handled: Bool = switch response.result {
                case let .success(value):
                    await router.routeResponse(requestId: id, response: value)
                case let .failure(error):
                    await router.routeError(requestId: id, error: error)
            }
            if handled {
                return
            }
        }

        // Check pending requests
        guard let pending = protocolState.pendingRequests.removeValue(forKey: id) else {
            protocolLogger?.warning("Received response for unknown request", metadata: ["id": "\(id)"])
            return
        }

        switch response.result {
            case let .success(value):
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(value) {
                    pending.resume(returning: data)
                } else {
                    pending.resume(throwing: MCPError.internalError("Failed to encode response"))
                }
            case let .failure(error):
                pending.resume(throwing: error)
        }
    }

    /// Handle a notification message (internal routing).
    private func handleNotificationInternal(_ notification: AnyMessage, data: Data) async {
        // Check for progress notification
        if notification.method == ProgressNotification.name {
            await handleProgressNotification(data)
        }

        // Delegate to conformer
        await handleIncomingNotification(notification, data: data)
    }

    /// Handle a progress notification.
    private func handleProgressNotification(_ data: Data) async {
        let decoder = JSONDecoder()
        guard let message = try? decoder.decode(Message<ProgressNotification>.self, from: data) else {
            return
        }

        let progressToken = message.params.progressToken

        // Signal timeout controller to reset deadline
        if let controller = protocolState.timeoutControllers[progressToken] {
            await controller.signalProgress()
        }

        if let callback = protocolState.progressCallbacks[progressToken] {
            await callback(message.params)
        }
    }

    /// Handle message loop error.
    private func handleMessageLoopError(_ error: any Error) async {
        protocolLogger?.error("Message loop error", metadata: ["error": "\(error)"])
        await protocolState.onError?(error)
    }

    /// Handle message loop ending unexpectedly.
    ///
    /// Transitions to `.disconnected` and calls `onClose`, mirroring the graceful
    /// shutdown path in `stopProtocol()`. This ensures `onClose` fires exactly once
    /// regardless of whether the close was graceful or unexpected, and prevents a
    /// subsequent `stop()` call from running cleanup a second time.
    private func handleMessageLoopEnded() async {
        guard case let .connected(transport) = protocolState.connectionState else { return }

        let pendingToCancel = protocolState.pendingRequests
        protocolState.pendingRequests.removeAll()

        for (_, request) in pendingToCancel {
            request.resume(throwing: MCPError.connectionClosed)
        }

        // Clear pending debounced notifications and cancel flush tasks
        protocolState.pendingDebouncedNotifications.removeAll()
        for (_, task) in protocolState.pendingFlushTasks {
            task.cancel()
        }
        protocolState.pendingFlushTasks.removeAll()

        // Notify the conformer about the unexpected closure (e.g., cancel in-flight handlers)
        await handleConnectionClosed()

        // Disconnect the transport and transition to .disconnected so that
        // a subsequent stop() call is a no-op.
        protocolState.messageLoopTask = nil
        await transport.disconnect()
        protocolState.connectionState = .disconnected
        await protocolState.onClose?()
    }

    // MARK: Sending Messages

    /// Send raw data to the transport.
    func sendProtocolData(_ data: Data, relatedRequestId: RequestId? = nil) async throws {
        guard let transport = protocolState.transport else {
            throw MCPError.internalError("Not connected")
        }
        try await transport.send(data, options: TransportSendOptions(relatedRequestId: relatedRequestId))
    }

    /// Send an error response.
    func sendProtocolErrorResponse(
        id: RequestId,
        error: any Error
    ) async {
        let mcpError = (error as? MCPError) ?? MCPError.internalError(String(describing: error))
        let response = AnyResponse(id: id, error: mcpError)

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(response)
            try await sendProtocolData(data, relatedRequestId: id)
        } catch {
            protocolLogger?.error("Failed to send error response", metadata: ["error": "\(error)"])
        }
    }

    // MARK: Sending Requests

    /// Send a request and wait for its response.
    func sendProtocolRequest(_ request: Data, requestId: RequestId) async throws -> Data {
        // Create stream for receiving the response
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()

        // Register cleanup on termination
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeProtocolPendingRequest(id: requestId) }
        }

        // Register the pending request
        protocolState.pendingRequests[requestId] = ProtocolPendingRequest(continuation: continuation) { $0 }

        // Send the request
        do {
            try await sendProtocolData(request)
        } catch {
            protocolState.pendingRequests.removeValue(forKey: requestId)
            continuation.finish(throwing: error)
            throw error
        }

        // Wait for response
        for try await responseData in stream {
            return responseData
        }

        try Task.checkCancellation()
        throw MCPError.connectionClosed
    }

    /// Send a request with options for progress tracking and timeout.
    ///
    /// - Parameters:
    ///   - request: The encoded request data.
    ///   - requestId: The ID of the request.
    ///   - options: Options for progress tracking and timeout.
    ///   - metaValues: Optional metadata values to inject into the request's `_meta` field.
    ///     If provided, these values are merged into any existing `_meta` fields in the request.
    ///     This is the centralized location for the decode-mutate-encode pattern needed to
    ///     inject metadata like `progressToken` into typed request parameters.
    func sendProtocolRequest(
        _ request: Data,
        requestId: RequestId,
        options: ProtocolRequestOptions,
        metaValues: [String: Value]? = nil
    ) async throws -> Data {
        // Inject metadata values if provided
        let requestData: Data = if let metaValues {
            try injectMeta(into: request, values: metaValues)
        } else {
            request
        }

        // Register progress callback and request→token mapping
        if let token = options.progressToken, let onProgress = options.onProgress {
            protocolState.progressCallbacks[token] = onProgress
            protocolState.requestProgressTokens[requestId] = token
        }

        // Set up timeout controller if progress-aware timeout is requested
        let controller: TimeoutController?
        if let timeout = options.timeout, options.resetTimeoutOnProgress,
           let token = options.progressToken
        {
            let c = TimeoutController(
                timeout: timeout,
                resetOnProgress: true,
                maxTotalTimeout: options.maxTotalTimeout
            )
            protocolState.timeoutControllers[token] = c
            controller = c
        } else {
            controller = nil
        }

        let timeout = options.timeout
        let progressToken = options.progressToken

        do {
            let responseData: Data = if let timeout {
                if let controller {
                    // Progress-aware timeout
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await self.sendProtocolRequest(requestData, requestId: requestId)
                        }
                        group.addTask {
                            try await controller.waitForTimeout()
                            throw MCPError.internalError("Unreachable - timeout should throw")
                        }
                        guard let result = try await group.next() else {
                            throw MCPError.internalError("No response received")
                        }
                        group.cancelAll()
                        await controller.cancel()
                        return result
                    }
                } else {
                    // Simple timeout
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await self.sendProtocolRequest(requestData, requestId: requestId)
                        }
                        group.addTask {
                            try await Task.sleep(for: timeout)
                            throw MCPError.requestTimeout(timeout: timeout, message: "Request timed out")
                        }
                        guard let result = try await group.next() else {
                            throw MCPError.internalError("No response received")
                        }
                        group.cancelAll()
                        return result
                    }
                }
            } else {
                try await sendProtocolRequest(requestData, requestId: requestId)
            }

            // Clean up on success
            if let progressToken {
                cleanUpProtocolProgressState(token: progressToken, requestId: requestId)
            }
            return responseData
        } catch {
            // Clean up on error
            if let progressToken {
                cleanUpProtocolProgressState(token: progressToken, requestId: requestId)
            }
            throw error
        }
    }

    /// Send raw request data with an optional send override.
    ///
    /// This allows callers to register a pending request on the protocol's
    /// tracking while sending the request via a different transport (e.g., Server's
    /// captured connection for HTTP routing).
    func sendProtocolRequestData(
        _ requestData: Data,
        relatedRequestId: RequestId? = nil,
        sendOverride: (@Sendable (Data, RequestId?) async throws -> Void)? = nil
    ) async throws -> Data {
        let decoder = JSONDecoder()
        guard let requestInfo = try? decoder.decode(AnyRequest.self, from: requestData) else {
            throw MCPError.internalError("Invalid request data")
        }

        let requestId = requestInfo.id
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()

        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeProtocolPendingRequest(id: requestId) }
        }

        protocolState.pendingRequests[requestId] = ProtocolPendingRequest(continuation: continuation) { $0 }

        do {
            if let sendOverride {
                try await sendOverride(requestData, relatedRequestId)
            } else {
                try await sendProtocolData(requestData, relatedRequestId: relatedRequestId)
            }
        } catch {
            protocolState.pendingRequests.removeValue(forKey: requestId)
            continuation.finish(throwing: error)
            throw error
        }

        for try await responseData in stream {
            return responseData
        }

        try Task.checkCancellation()
        throw MCPError.connectionClosed
    }

    // MARK: Sending Notifications

    /// Send a notification with optional debouncing.
    func sendProtocolNotification(
        _ notification: some NotificationMessageProtocol,
        relatedRequestId: RequestId? = nil
    ) async throws {
        let method = notification.method

        let canDebounce = protocolState.debouncedNotificationMethods.contains(method)
            && relatedRequestId == nil

        if canDebounce {
            guard !protocolState.pendingDebouncedNotifications.contains(method) else { return }

            protocolState.pendingDebouncedNotifications.insert(method)
            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)

            let task = Task { [weak self] in
                guard let self else { return }
                await Task.yield()
                await flushDebouncedNotification(data, method: method)
            }
            protocolState.pendingFlushTasks[method] = task
            return
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)
        try await sendProtocolData(data, relatedRequestId: relatedRequestId)
    }

    /// Flush a debounced notification.
    private func flushDebouncedNotification(_ data: Data, method: String) async {
        protocolState.pendingDebouncedNotifications.remove(method)
        protocolState.pendingFlushTasks.removeValue(forKey: method)

        guard protocolState.transport != nil else { return }

        do {
            try await sendProtocolData(data)
        } catch {
            protocolLogger?.error(
                "Failed to send debounced notification",
                metadata: ["method": "\(method)", "error": "\(error)"]
            )
        }
    }

    // MARK: Pending Request Management

    /// Register a pending request without sending it (for batch operations).
    func registerProtocolPendingRequest(id: RequestId) -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()

        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeProtocolPendingRequest(id: id) }
        }

        protocolState.pendingRequests[id] = ProtocolPendingRequest(continuation: continuation) { $0 }
        return stream
    }

    /// Resume a pending request with a response.
    @discardableResult
    func resumeProtocolPendingRequest(id requestId: RequestId, with data: Data) -> Bool {
        guard let pending = protocolState.pendingRequests.removeValue(forKey: requestId) else {
            return false
        }
        pending.resume(returning: data)
        return true
    }

    /// Cancel a pending request by its ID.
    @discardableResult
    func cancelProtocolPendingRequest(id: RequestId, error: any Error) -> Bool {
        guard let pending = protocolState.pendingRequests.removeValue(forKey: id) else {
            return false
        }
        pending.resume(throwing: error)
        return true
    }

    /// Check if a request ID is pending.
    func hasProtocolPendingRequest(id requestId: RequestId) -> Bool {
        protocolState.pendingRequests[requestId] != nil
    }

    /// Remove a pending request without resuming it.
    private func removeProtocolPendingRequest(id requestId: RequestId) {
        protocolState.pendingRequests.removeValue(forKey: requestId)
    }

    // MARK: Request ID Generation

    /// Generate a unique request ID.
    func generateProtocolRequestId() -> RequestId {
        let id = protocolState.nextRequestId
        protocolState.nextRequestId += 1
        return .number(id)
    }

    // MARK: Progress Management

    /// Get the progress token associated with a request ID.
    func progressToken(forRequestId requestId: RequestId) -> ProgressToken? {
        protocolState.requestProgressTokens[requestId]
    }

    /// Associate a task ID with a progress token.
    func setTaskProgressToken(taskId: String, progressToken: ProgressToken) {
        protocolState.taskProgressTokens[taskId] = progressToken
    }

    /// Clean up progress handler when a task reaches terminal status.
    func cleanUpTaskProgressHandler(taskId: String) {
        guard let progressToken = protocolState.taskProgressTokens.removeValue(forKey: taskId) else { return }
        protocolState.progressCallbacks.removeValue(forKey: progressToken)
        protocolState.timeoutControllers.removeValue(forKey: progressToken)
    }

    /// Clean up progress/timeout state for a cancelled request.
    func cleanUpRequestProgress(requestId: RequestId) {
        if let token = protocolState.requestProgressTokens.removeValue(forKey: requestId) {
            protocolState.progressCallbacks.removeValue(forKey: token)
            protocolState.timeoutControllers.removeValue(forKey: token)
        }
    }

    /// Clean up progress/timeout state for a completed or failed request.
    private func cleanUpProtocolProgressState(token: ProgressToken, requestId: RequestId) {
        // Don't remove if the token has been migrated to task tracking
        if !protocolState.taskProgressTokens.values.contains(token) {
            protocolState.progressCallbacks.removeValue(forKey: token)
            protocolState.timeoutControllers.removeValue(forKey: token)
        }
        protocolState.requestProgressTokens.removeValue(forKey: requestId)
    }

    // MARK: Response Router Management

    /// Add a response router.
    func addProtocolResponseRouter(_ router: any ResponseRouter) {
        protocolState.responseRouters.append(router)
    }

    /// Remove all response routers.
    func removeAllProtocolResponseRouters() {
        protocolState.responseRouters.removeAll()
    }

    // MARK: Notification Debouncing

    /// Configure which notification methods should be debounced.
    func setDebouncedNotificationMethods(_ methods: Set<String>) {
        protocolState.debouncedNotificationMethods = methods
    }

    /// Wait for all pending debounced notifications to be flushed.
    func waitForPendingDebouncedNotifications() async {
        let tasks = protocolState.pendingFlushTasks.values
        for task in tasks {
            await task.value
        }
    }

    // MARK: Transport Access

    /// Check if connected.
    var isProtocolConnected: Bool {
        if case .connected = protocolState.connectionState {
            return true
        }
        return false
    }

    /// Fail all pending requests with the given error.
    func failAllProtocolPendingRequests(with error: any Error) {
        let pendingToFail = protocolState.pendingRequests
        protocolState.pendingRequests.removeAll()

        for (_, request) in pendingToFail {
            request.resume(throwing: error)
        }
    }

    // MARK: Request Metadata Injection

    /// Injects metadata values into the `_meta` field of a JSON-RPC request.
    ///
    /// This is the single location for the decode-mutate-encode pattern needed to
    /// inject metadata (like `progressToken`) into typed request parameters. Swift's
    /// type system prevents generically adding fields to arbitrary `M.Parameters`
    /// types, so this runtime approach is necessary.
    ///
    /// Both TypeScript and Python SDKs use a similar pattern at the protocol layer:
    /// - TypeScript: object spread in `Protocol.request()` (lines 1121-1129)
    /// - Python: dict mutation in `BaseSession.send_request()` (lines 252-261)
    ///
    /// - Parameters:
    ///   - requestData: The encoded request data.
    ///   - values: The metadata values to inject into `_meta`.
    /// - Returns: The modified request data with metadata injected.
    /// - Throws: `MCPError.internalError` if the request cannot be decoded or re-encoded.
    private func injectMeta(into requestData: Data, values: [String: Value]) throws -> Data {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        // Decode to dictionary for mutation
        var dict: [String: Value]
        do {
            dict = try decoder.decode([String: Value].self, from: requestData)
        } catch {
            protocolLogger?.error("Failed to decode request for metadata injection", metadata: ["error": "\(error)"])
            throw MCPError.internalError("Failed to decode request for metadata injection: \(error)")
        }

        // Get or create params
        var params = dict["params"]?.objectValue ?? [:]

        // Get or create _meta
        var meta = params["_meta"]?.objectValue ?? [:]

        // Merge in the new values (overwrites existing keys)
        for (key, value) in values {
            meta[key] = value
        }

        // Update the structure
        params["_meta"] = .object(meta)
        dict["params"] = .object(params)

        // Re-encode
        do {
            return try encoder.encode(dict)
        } catch {
            protocolLogger?.error("Failed to re-encode request after metadata injection", metadata: ["error": "\(error)"])
            throw MCPError.internalError("Failed to re-encode request after metadata injection: \(error)")
        }
    }
}
