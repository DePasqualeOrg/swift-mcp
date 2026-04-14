// Copyright © Anthony DePasquale

import Foundation

extension Server {
    // MARK: - Request Handling

    /// A JSON-RPC batch containing multiple requests and/or notifications
    struct Batch {
        /// An item in a JSON-RPC batch
        enum Item {
            case request(Request<AnyMethod>)
            case notification(Message<AnyNotification>)
        }

        var items: [Item]
    }

    /// Process a batch of requests and/or notifications
    func handleBatch(_ batch: Batch, messageContext: MessageMetadata? = nil) async throws {
        // Capture the connection at batch start.
        // This ensures all batch responses go to the correct client.
        let capturedConnection = connection

        logger?.trace("Processing batch request", metadata: ["size": "\(batch.items.count)"])

        if batch.items.isEmpty {
            // Empty batch is invalid according to JSON-RPC spec
            let error = MCPError.invalidRequest("Batch array must not be empty")
            let response = AnyMethod.response(id: .random, error: error)
            // Use captured connection for error response
            if let connection = capturedConnection {
                let responseData = try encoder.encode(response)
                try await connection.send(responseData)
            }
            return
        }

        // Process each item in the batch and collect responses
        var responses: [Response<AnyMethod>] = []

        for item in batch.items {
            do {
                switch item {
                    case let .request(request):
                        // For batched requests, collect responses instead of sending immediately
                        if let response = try await handleRequest(request, sendResponse: false, messageContext: messageContext) {
                            responses.append(response)
                        }

                    case let .notification(notification):
                        // Handle notification (no response needed)
                        try await handleMessage(notification)
                }
            } catch {
                // Only add errors to response for requests (notifications don't have responses)
                if case let .request(request) = item {
                    // Log full error for debugging, but sanitize for client response.
                    // Only log non-MCP errors since MCP errors are expected/user-facing.
                    if !(error is MCPError) {
                        logger?.error("Error handling batch item", metadata: ["error": "\(error)"])
                    }
                    let mcpError =
                        error as? MCPError ?? MCPError.internalError("An internal error occurred")
                    responses.append(AnyMethod.response(id: request.id, error: mcpError))
                }
            }
        }

        // Send collected responses if any (using captured connection)
        if !responses.isEmpty {
            guard let connection = capturedConnection else {
                logger?.warning("Cannot send batch response - connection was nil at batch start")
                return
            }

            let responseData = try encoder.encode(responses)
            try await connection.send(responseData)
        }
    }

    // MARK: - Request and Message Handling

    /// Internal context for routing responses to the correct transport.
    ///
    /// When handling requests, we capture the current connection at request time.
    /// This ensures that when the handler completes (which may be async), the response
    /// is sent to the correct client even if `self.connection` has changed in the meantime.
    ///
    /// This pattern is critical for HTTP transports where multiple clients can connect
    /// and the server's `connection` reference gets reassigned.
    struct RequestContext {
        /// The transport connection captured at request time
        let capturedConnection: (any Transport)?
        /// The ID of the request being handled
        let requestId: RequestId
        /// The session ID from the transport, if available.
        ///
        /// For HTTP transports with multiple concurrent clients, this identifies
        /// the specific session. Used for per-session features like log levels.
        let sessionId: String?
        /// The request metadata from `_meta` field, if present.
        ///
        /// Contains the progress token and any additional metadata.
        let meta: RequestMeta?
        /// Authentication information, if available.
        ///
        /// Set by HTTP transports when OAuth or other authentication is in use.
        let authInfo: AuthInfo?
        /// Information about the incoming HTTP request.
        ///
        /// Contains HTTP headers from the original request. Only available for
        /// HTTP transports. This matches TypeScript SDK's `extra.requestInfo`.
        let requestInfo: RequestInfo?
        /// Closure to close the SSE stream for this request.
        ///
        /// Only set by HTTP transports with SSE support.
        let closeResponseStream: (@Sendable () async -> Void)?
        /// Closure to close the standalone SSE stream.
        ///
        /// Only set by HTTP transports with SSE support.
        let closeNotificationStream: (@Sendable () async -> Void)?
    }

    /// Extract `_meta` from request parameters if present.
    ///
    /// Since `AnyMethod.Parameters` is `Value`, we need to extract `_meta` manually.
    private func extractMeta(from params: Value) -> RequestMeta? {
        guard case let .object(dict) = params,
              let metaValue = dict["_meta"]
        else {
            return nil
        }
        // Decode the _meta value as RequestMeta
        guard let data = try? encoder.encode(metaValue),
              let meta = try? decoder.decode(RequestMeta.self, from: data)
        else {
            return nil
        }
        return meta
    }

    /// Send a response using the captured request context.
    ///
    /// This ensures responses are routed to the correct client by:
    /// 1. Using the connection that was active when the request was received
    /// 2. Passing the request ID so multiplexing transports can route correctly
    func send(_ response: Response<some Method>, using context: RequestContext) async throws {
        guard let connection = context.capturedConnection else {
            logger?.warning(
                "Cannot send response - connection was nil at request time",
                metadata: ["requestId": "\(context.requestId)"],
            )
            return
        }

        let responseData = try encoder.encode(response)
        try await connection.send(responseData, options: TransportSendOptions(relatedRequestId: context.requestId))
    }

    /// Handle a request and either send the response immediately or return it
    ///
    /// - Parameters:
    ///   - request: The request to handle
    ///   - sendResponse: Whether to send the response immediately (true) or return it (false)
    ///   - messageContext: Optional context from the transport message (authInfo, SSE closures)
    /// - Returns: The response when sendResponse is false
    func handleRequest(_ request: Request<AnyMethod>, sendResponse: Bool = true, messageContext: MessageMetadata? = nil)
        async throws -> Response<AnyMethod>?
    {
        // Capture the connection and session ID at request time.
        // This ensures responses go to the correct client even if self.connection
        // changes while the handler is executing (e.g., another client connects).
        let capturedConnection = connection
        let requestMeta = extractMeta(from: request.params)

        // Extract context from transport message (set by HTTP transports with per-message context)
        // This pattern aligns with TypeScript's onmessage(message, { authInfo, requestInfo, closeResponseStream, ... })
        let authInfo = messageContext?.authInfo
        let requestInfo = messageContext?.requestInfo
        let closeResponseStream = messageContext?.closeResponseStream
        let closeNotificationStream = messageContext?.closeNotificationStream

        let context = await RequestContext(
            capturedConnection: capturedConnection,
            requestId: request.id,
            sessionId: capturedConnection?.sessionId,
            meta: requestMeta,
            authInfo: authInfo,
            requestInfo: requestInfo,
            closeResponseStream: closeResponseStream,
            closeNotificationStream: closeNotificationStream,
        )

        // Check if this is a pre-processed error request (empty method)
        if request.method.isEmpty, !sendResponse {
            // This is a placeholder for an invalid request that couldn't be parsed in batch mode
            return AnyMethod.response(
                id: request.id,
                error: MCPError.invalidRequest("Invalid batch item format"),
            )
        }

        logger?.trace(
            "Processing request",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ],
        )

        // Check initialization state for strict mode (matches Python SDK behavior).
        // We chose to align with Python (block at Server level) rather than TypeScript
        // (block only at HTTP transport level) for consistent behavior across all transports.
        if configuration.strict {
            switch request.method {
                case Initialize.name, Ping.name:
                    // Always allow initialize and ping requests
                    break
                default:
                    guard isInitialized else {
                        let error = MCPError.invalidRequest("Server is not initialized")
                        let response = AnyMethod.response(id: request.id, error: error)

                        if sendResponse {
                            try await send(response, using: context)
                            return nil
                        }

                        return response
                    }
            }
        }

        // Find handler for method name (try specific handler first, then fallback)
        let handler: RequestHandlerBox
        if let specificHandler = registeredHandlers.methodHandlers[request.method] {
            handler = specificHandler
        } else if let fallbackHandler = registeredHandlers.fallbackRequestHandler {
            logger?.debug(
                "Using fallback handler for request",
                metadata: ["method": "\(request.method)"],
            )
            handler = fallbackHandler
        } else {
            let error = MCPError.methodNotFound("Unknown method: \(request.method)")
            let response = AnyMethod.response(id: request.id, error: error)

            if sendResponse {
                try await send(response, using: context)
                return nil
            }

            return response
        }

        // Create the handler context (RequestHandlerContext)
        let handlerContext = RequestHandlerContext(
            sessionId: context.sessionId,
            requestId: context.requestId,
            _meta: context.meta,
            taskId: context.meta?.relatedTaskId,
            authInfo: context.authInfo,
            requestInfo: context.requestInfo,
            closeResponseStream: context.closeResponseStream,
            closeNotificationStream: context.closeNotificationStream,
            sendNotification: { [weak self, context] message in
                guard let self else {
                    throw MCPError.internalError("Server was deallocated")
                }
                guard let connection = context.capturedConnection else {
                    throw MCPError.internalError("Cannot send notification - connection was nil at request time")
                }

                let messageData = try encoder.encode(message)
                try await connection.send(messageData, options: TransportSendOptions(relatedRequestId: context.requestId))
            },
            sendRequest: { [weak self, context] requestData in
                guard let self else {
                    throw MCPError.internalError("Server was deallocated")
                }
                guard let capturedConnection = context.capturedConnection else {
                    throw MCPError.internalError("Cannot send request - connection was nil at request time")
                }

                // Delegate to protocol for request tracking and response matching,
                // using a send override to route through the captured connection
                // for correct HTTP client routing.
                return try await sendProtocolRequestData(
                    requestData,
                    relatedRequestId: context.requestId,
                    sendOverride: { data, relatedId in
                        try await capturedConnection.send(data, options: TransportSendOptions(relatedRequestId: relatedId))
                    },
                )
            },
            sendData: { [context] data in
                guard let connection = context.capturedConnection else {
                    throw MCPError.internalError("Cannot send data - connection was nil at request time")
                }
                try await connection.send(data, options: TransportSendOptions(relatedRequestId: context.requestId))
            },
            shouldSendLogMessage: { [weak self, context] level in
                guard let self else { return true }
                return await shouldSendLogMessage(at: level, forSession: context.sessionId)
            },
            serverCapabilities: capabilities,
        )

        do {
            // Handle request and get response
            let response: Response<AnyMethod> = try await handler(request, context: handlerContext)

            // Check cancellation before sending response (per MCP spec:
            // "Receivers of a cancellation notification SHOULD... Not send a response
            // for the cancelled request")
            if Task.isCancelled {
                logger?.debug(
                    "Request cancelled, suppressing response",
                    metadata: ["id": "\(request.id)"],
                )
                return nil
            }

            if sendResponse {
                try await send(response, using: context)
                return nil
            }

            return response
        } catch {
            // Also check cancellation on error path - don't send error response if cancelled
            if Task.isCancelled {
                logger?.debug(
                    "Request cancelled during error handling, suppressing response",
                    metadata: ["id": "\(request.id)"],
                )
                return nil
            }

            // Log full error for debugging, but sanitize for client response
            if !(error is MCPError) {
                logger?.error("Request handler error", metadata: ["error": "\(error)"])
            }
            let mcpError = error as? MCPError ?? MCPError.internalError("An internal error occurred")
            let response: Response<AnyMethod> = AnyMethod.response(id: request.id, error: mcpError)

            if sendResponse {
                try await send(response, using: context)
                return nil
            }

            return response
        }
    }

    func handleMessage(_ message: Message<AnyNotification>) async throws {
        logger?.trace(
            "Processing notification",
            metadata: ["method": "\(message.method)"],
        )

        // Check initialization state for strict mode (matches Python SDK behavior).
        // For notifications (unlike requests), we log and ignore since no response is expected.
        if configuration.strict {
            if message.method != InitializedNotification.name, !isInitialized {
                logger?.warning(
                    "Ignoring notification before initialization",
                    metadata: ["method": "\(message.method)"],
                )
                return
            }
        }

        // Find notification handlers for this method (try specific handlers first, then fallback)
        let handlers = registeredHandlers.notificationHandlers[message.method] ?? []

        // Use fallback handler if no specific handlers registered
        if handlers.isEmpty, let fallbackHandler = registeredHandlers.fallbackNotificationHandler {
            do {
                try await fallbackHandler(message)
            } catch {
                logger?.error(
                    "Error in fallback notification handler",
                    metadata: [
                        "method": "\(message.method)",
                        "error": "\(error)",
                    ],
                )
            }
        } else {
            for handler in handlers {
                do {
                    try await handler(message)
                } catch {
                    logger?.error(
                        "Error handling notification",
                        metadata: [
                            "method": "\(message.method)",
                            "error": "\(error)",
                        ],
                    )
                }
            }
        }
    }

    // Response handling is delegated to the protocol conformance, which handles response
    // routers and pending request matching internally.
}
