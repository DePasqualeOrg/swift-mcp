// Copyright © Anthony DePasquale

import Foundation
import Logging

// MARK: - Request Handler Context

/// Context provided to request handlers when handling incoming requests.
///
/// This is the Swift equivalent of TypeScript's `RequestHandlerExtra`. It provides:
/// - Session and request identification
/// - Authentication and request information (for HTTP transports)
/// - SSE stream management (for HTTP transports)
/// - Notification and request sending capabilities
/// - Cancellation support
///
/// ## Example
///
/// ```swift
/// server.withRequestHandler(CallTool.self) { params, context in
///     // Check for cancellation
///     try context.checkCancellation()
///
///     // Send progress notification
///     try await context.sendNotification(ProgressNotification.message(...))
///
///     return CallTool.Result(content: [.text("Done")])
/// }
/// ```
public struct RequestHandlerContext: Sendable {
    /// The session identifier for this request's connection.
    ///
    /// For HTTP transports with multiple clients, each session has a unique identifier.
    /// For simple transports (stdio), this is `nil`.
    public let sessionId: String?

    /// The JSON-RPC request ID.
    public let requestId: RequestId

    /// Request metadata from `_meta` field.
    public let _meta: RequestMeta?

    /// The task ID if this request is associated with a task.
    public let taskId: String?

    /// Authentication information for this request (HTTP transports only).
    public let authInfo: AuthInfo?

    /// HTTP request information (HTTP transports only).
    public let requestInfo: RequestInfo?

    /// Closes the SSE stream for this request, triggering client reconnection.
    ///
    /// Only available when using HTTPServerTransport with eventStore configured.
    public let closeResponseStream: (@Sendable () async -> Void)?

    /// Closes the standalone GET SSE stream.
    ///
    /// Only available when using HTTPServerTransport with eventStore configured.
    public let closeNotificationStream: (@Sendable () async -> Void)?

    /// Send a notification to the peer.
    ///
    /// The notification will be associated with this request via `relatedRequestId`
    /// for proper routing in multiplexed transports.
    private let _sendNotification: @Sendable (any NotificationMessageProtocol) async throws -> Void

    /// Send a request to the peer and wait for a response.
    ///
    /// For bidirectional communication (e.g., sampling, elicitation).
    private let _sendRequest: @Sendable (Data) async throws -> Data

    /// Send raw data to the peer.
    ///
    /// Used internally for sending queued task messages (such as elicitation
    /// or sampling requests that were queued during task execution).
    private let _sendData: (@Sendable (Data) async throws -> Void)?

    /// Check if a log message at the given level should be sent.
    ///
    /// Respects the minimum log level set by the client via `logging/setLevel`.
    private let _shouldSendLogMessage: (@Sendable (LoggingLevel) async -> Bool)?

    /// The server's declared capabilities.
    ///
    /// Used internally to validate capability requirements before sending notifications.
    private let serverCapabilities: Server.Capabilities?

    /// Check if the request has been cancelled.
    public var isCancelled: Bool {
        Task.isCancelled
    }

    /// Throw `CancellationError` if the request has been cancelled.
    public func checkCancellation() throws {
        try Task.checkCancellation()
    }

    /// Send a notification message to the peer.
    public func sendNotification(_ notification: some NotificationMessageProtocol) async throws {
        try await _sendNotification(notification)
    }

    /// Send a parameterless notification to the peer.
    ///
    /// For notifications with `Empty` or `NotificationParams` parameters,
    /// this creates the message automatically.
    public func sendNotification<N: Notification>(_: N) async throws where N.Parameters == Empty {
        try await _sendNotification(N.message())
    }

    /// Send a parameterless notification to the peer (NotificationParams variant).
    public func sendNotification<N: Notification>(_: N) async throws where N.Parameters == NotificationParams {
        try await _sendNotification(N.message())
    }

    /// Send a request to the peer and wait for a response.
    ///
    /// - Parameter request: The request to send (must be Encodable)
    /// - Returns: The raw response data
    public func sendRequest(_ request: some Encodable & Sendable) async throws -> Data {
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        return try await _sendRequest(data)
    }

    /// Send a progress notification to the peer.
    ///
    /// - Parameters:
    ///   - token: The progress token from the request's `_meta.progressToken`
    ///   - progress: The current progress value (should increase monotonically)
    ///   - total: The total progress value, if known
    ///   - message: An optional human-readable message describing current progress
    public func sendProgress(
        token: ProgressToken,
        progress: Double,
        total: Double? = nil,
        message: String? = nil,
    ) async throws {
        try await _sendNotification(
            ProgressNotification.message(
                .init(
                    progressToken: token,
                    progress: progress,
                    total: total,
                    message: message,
                ),
            ),
        )
    }

    /// Send raw data to the peer.
    ///
    /// Used internally for sending queued task messages.
    public func sendData(_ data: Data) async throws {
        guard let _sendData else {
            throw MCPError.internalError("sendData is not available in this context")
        }
        try await _sendData(data)
    }

    /// Check if a log message at the given level should be sent.
    ///
    /// Returns `true` if no log level filtering is configured.
    public func shouldSendLogMessage(at level: LoggingLevel) async -> Bool {
        guard let _shouldSendLogMessage else { return true }
        return await _shouldSendLogMessage(level)
    }

    /// Send a log message notification to the client.
    ///
    /// The message will only be sent if its level is at or above the minimum
    /// log level set by the client via `logging/setLevel`.
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: An optional name for the logger producing the message
    ///   - data: The log message data
    public func sendLogMessage(
        level: LoggingLevel,
        logger: String? = nil,
        data: Value,
    ) async throws {
        guard await shouldSendLogMessage(at: level) else { return }
        try await _sendNotification(
            LogMessageNotification.message(
                .init(level: level, logger: logger, data: data),
            ),
        )
    }

    /// Send a resource list changed notification to the client.
    ///
    /// - Throws: `MCPError` if the server does not have the resources capability declared.
    public func sendResourceListChanged() async throws {
        guard serverCapabilities?.resources != nil else {
            throw MCPError.internalError("Server does not support resources capability (required for notifications/resources/list_changed)")
        }
        try await _sendNotification(ResourceListChangedNotification.message())
    }

    /// Send a resource updated notification to the client.
    ///
    /// - Parameter uri: The URI of the resource that was updated.
    /// - Throws: `MCPError` if the server does not have the resources capability declared.
    public func sendResourceUpdated(uri: String) async throws {
        guard serverCapabilities?.resources != nil else {
            throw MCPError.internalError("Server does not support resources capability (required for notifications/resources/updated)")
        }
        try await _sendNotification(ResourceUpdatedNotification.message(.init(uri: uri)))
    }

    /// Send a tool list changed notification to the client.
    ///
    /// - Throws: `MCPError` if the server does not have the tools capability declared.
    public func sendToolListChanged() async throws {
        guard serverCapabilities?.tools != nil else {
            throw MCPError.internalError("Server does not support tools capability (required for notifications/tools/list_changed)")
        }
        try await _sendNotification(ToolListChangedNotification.message())
    }

    /// Send a prompt list changed notification to the client.
    ///
    /// - Throws: `MCPError` if the server does not have the prompts capability declared.
    public func sendPromptListChanged() async throws {
        guard serverCapabilities?.prompts != nil else {
            throw MCPError.internalError("Server does not support prompts capability (required for notifications/prompts/list_changed)")
        }
        try await _sendNotification(PromptListChangedNotification.message())
    }

    /// Send a cancellation notification to the peer.
    ///
    /// - Parameters:
    ///   - requestId: The ID of the request being cancelled
    ///   - reason: An optional reason for the cancellation
    public func sendCancelled(requestId: RequestId? = nil, reason: String? = nil) async throws {
        try await _sendNotification(
            CancelledNotification.message(
                .init(requestId: requestId, reason: reason),
            ),
        )
    }

    /// Send an elicitation complete notification to the client.
    ///
    /// - Parameter elicitationId: The ID of the elicitation that completed.
    public func sendElicitationComplete(elicitationId: String) async throws {
        try await _sendNotification(
            ElicitationCompleteNotification.message(
                .init(elicitationId: elicitationId),
            ),
        )
    }

    /// Send a task status notification to the client.
    ///
    /// - Parameter task: The task to send the status notification for.
    public func sendTaskStatus(task: MCPTask) async throws {
        try await _sendNotification(TaskStatusNotification.message(.init(task: task)))
    }

    /// Request user input via form elicitation from the client.
    ///
    /// - Parameters:
    ///   - message: The message to present to the user
    ///   - requestedSchema: The schema defining the form fields
    /// - Returns: The elicitation result from the client
    public func elicit(
        message: String,
        requestedSchema: ElicitationSchema,
    ) async throws -> ElicitResult {
        let params = ElicitRequestFormParams(
            mode: "form",
            message: message,
            requestedSchema: requestedSchema,
        )
        let request = Elicit.request(id: .random, .form(params))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let requestData = try encoder.encode(request)

        let responseData = try await _sendRequest(requestData)
        return try JSONDecoder().decode(ElicitResult.self, from: responseData)
    }

    /// Request user interaction via URL-mode elicitation from the client.
    ///
    /// - Parameters:
    ///   - message: Human-readable explanation of why the interaction is needed
    ///   - url: The URL the user should navigate to
    ///   - elicitationId: Unique identifier for tracking this elicitation
    /// - Returns: The elicitation result from the client
    public func elicitUrl(
        message: String,
        url: String,
        elicitationId: String,
    ) async throws -> ElicitResult {
        let params = ElicitRequestURLParams(
            message: message,
            elicitationId: elicitationId,
            url: url,
        )
        let request = Elicit.request(id: .random, .url(params))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let requestData = try encoder.encode(request)

        let responseData = try await _sendRequest(requestData)
        return try JSONDecoder().decode(ElicitResult.self, from: responseData)
    }

    public init(
        sessionId: String?,
        requestId: RequestId,
        _meta: RequestMeta?,
        taskId: String?,
        authInfo: AuthInfo?,
        requestInfo: RequestInfo?,
        closeResponseStream: (@Sendable () async -> Void)?,
        closeNotificationStream: (@Sendable () async -> Void)?,
        sendNotification: @escaping @Sendable (any NotificationMessageProtocol) async throws -> Void,
        sendRequest: @escaping @Sendable (Data) async throws -> Data,
        sendData: (@Sendable (Data) async throws -> Void)? = nil,
        shouldSendLogMessage: (@Sendable (LoggingLevel) async -> Bool)? = nil,
        serverCapabilities: Server.Capabilities? = nil,
    ) {
        self.sessionId = sessionId
        self.requestId = requestId
        self._meta = _meta
        self.taskId = taskId
        self.authInfo = authInfo
        self.requestInfo = requestInfo
        self.closeResponseStream = closeResponseStream
        self.closeNotificationStream = closeNotificationStream
        _sendNotification = sendNotification
        _sendRequest = sendRequest
        _sendData = sendData
        _shouldSendLogMessage = shouldSendLogMessage
        self.serverCapabilities = serverCapabilities
    }
}

// MARK: - Protocol Pending Request

/// Type-erased pending request that stores the continuation.
///
/// Uses `Data` as the intermediate type, requiring a Value→Data→T round trip.
/// A custom `ValueDecoder` could avoid re-encoding, but the overhead is negligible
/// for typical MCP payloads.
package struct ProtocolPendingRequest {
    private let _resume: @Sendable (Result<Data, any Error>) -> Void

    init<T>(continuation: AsyncThrowingStream<T, any Error>.Continuation, transform: @escaping @Sendable (Data) throws -> T) {
        _resume = { result in
            switch result {
                case let .success(data):
                    do {
                        let value = try transform(data)
                        continuation.yield(value)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                case let .failure(error):
                    continuation.finish(throwing: error)
            }
        }
    }

    func resume(returning data: Data) {
        _resume(.success(data))
    }

    func resume(throwing error: any Error) {
        _resume(.failure(error))
    }
}

// MARK: - Progress Callback

/// Callback for handling progress notifications.
public typealias ProtocolProgressCallback = @Sendable (ProgressNotification.Parameters) async -> Void

// MARK: - Request Options

/// Options for a request sent through the protocol layer.
///
/// Encapsulates progress tracking, timeout behavior, and progress-aware timeout
/// resets for a single request.
public struct ProtocolRequestOptions: Sendable {
    /// The progress token for this request.
    public let progressToken: ProgressToken?
    /// A callback invoked when progress notifications are received.
    public let onProgress: ProtocolProgressCallback?
    /// A timeout for this request. If exceeded, the request is cancelled.
    public let timeout: Duration?
    /// If true, receiving a progress notification resets the timeout clock.
    public let resetTimeoutOnProgress: Bool
    /// Maximum total time to wait regardless of progress.
    public let maxTotalTimeout: Duration?

    public init(
        progressToken: ProgressToken? = nil,
        onProgress: ProtocolProgressCallback? = nil,
        timeout: Duration? = nil,
        resetTimeoutOnProgress: Bool = false,
        maxTotalTimeout: Duration? = nil,
    ) {
        self.progressToken = progressToken
        self.onProgress = onProgress
        self.timeout = timeout
        self.resetTimeoutOnProgress = resetTimeoutOnProgress
        self.maxTotalTimeout = maxTotalTimeout
    }
}

// MARK: - Timeout Controller

/// Controls timeout behavior for a single request, supporting reset on progress.
///
/// When progress is received, calling `signalProgress()` resets the timeout clock.
/// An optional maximum total timeout provides a hard upper limit.
package actor TimeoutController {
    let timeout: Duration
    let resetOnProgress: Bool
    let maxTotalTimeout: Duration?
    let startTime: ContinuousClock.Instant
    private var deadline: ContinuousClock.Instant
    private var isCancelled = false
    private var progressContinuation: AsyncStream<Void>.Continuation?

    init(timeout: Duration, resetOnProgress: Bool, maxTotalTimeout: Duration?) {
        self.timeout = timeout
        self.resetOnProgress = resetOnProgress
        self.maxTotalTimeout = maxTotalTimeout
        startTime = ContinuousClock.now
        deadline = ContinuousClock.now.advanced(by: timeout)
    }

    /// Signal that progress was received, resetting the timeout.
    func signalProgress() {
        guard resetOnProgress, !isCancelled else { return }
        deadline = ContinuousClock.now.advanced(by: timeout)
        progressContinuation?.yield()
    }

    /// Cancel the timeout controller.
    func cancel() {
        isCancelled = true
        progressContinuation?.finish()
    }

    /// Wait until the timeout expires.
    ///
    /// If `resetOnProgress` is true, the timeout resets each time `signalProgress()` is called.
    /// If `maxTotalTimeout` is set, the wait will end when that limit is exceeded.
    ///
    /// - Throws: `MCPError.requestTimeout` when the timeout expires.
    func waitForTimeout() async throws {
        let clock = ContinuousClock()

        let (progressStream, continuation) = AsyncStream<Void>.makeStream()
        progressContinuation = continuation

        while !isCancelled {
            if let maxTotal = maxTotalTimeout {
                let elapsed = clock.now - startTime
                if elapsed >= maxTotal {
                    throw MCPError.requestTimeout(
                        timeout: maxTotal,
                        message: "Request exceeded maximum total timeout",
                    )
                }
            }

            let now = clock.now
            let timeUntilDeadline = deadline - now

            if timeUntilDeadline <= .zero {
                throw MCPError.requestTimeout(
                    timeout: timeout,
                    message: "Request timed out",
                )
            }

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await Task.sleep(for: timeUntilDeadline)
                    }

                    if resetOnProgress {
                        group.addTask {
                            for await _ in progressStream {
                                return
                            }
                        }
                    }

                    try await group.next()
                    group.cancelAll()
                }
            } catch is CancellationError {
                return
            }
        }
    }
}

// MARK: - Message Preprocessing

/// Result of message preprocessing.
public enum MessagePreprocessResult: Sendable {
    /// The message was fully handled by the preprocessor (e.g., batch response).
    case handled
    /// Continue with standard message handling using the provided data.
    case `continue`(Data)
}

// MARK: - Connection State

/// Connection lifecycle state machine.
package enum ProtocolConnectionState {
    case disconnected
    case connecting
    case connected(transport: any Transport)
    case disconnecting
}
