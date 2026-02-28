// Copyright © Anthony DePasquale

import Foundation

extension Client {
    // MARK: - Message Handling

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
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        guard let data = try? encoder.encode(metaValue),
              let meta = try? decoder.decode(RequestMeta.self, from: data)
        else {
            return nil
        }
        return meta
    }

    /// Check if a response is a task-augmented response (CreateTaskResult).
    ///
    /// If the response contains a `task` object with `taskId`, this is a task-augmented
    /// response. Per MCP spec, progress notifications can continue until the task reaches
    /// terminal status, so we migrate the progress handler from request tracking to task tracking.
    ///
    /// This matches the TypeScript SDK pattern where task progress tokens are kept alive
    /// until the task completes.
    func checkForTaskResponse(response: Response<AnyMethod>, value: [String: Value]) async {
        // Check if we have a progress token for this request
        guard let id = response.id,
              let progressToken = progressToken(forRequestId: id)
        else { return }

        // Check if response has task.taskId (CreateTaskResult pattern)
        guard let taskValue = value["task"],
              case let .object(taskObject) = taskValue,
              let taskIdValue = taskObject["taskId"],
              case let .string(taskId) = taskIdValue
        else {
            return
        }

        // This is a task-augmented response!
        // Migrate progress token from request tracking to task tracking.
        setTaskProgressToken(taskId: taskId, progressToken: progressToken)

        logger?.debug(
            "Keeping progress handler alive for task",
            metadata: [
                "taskId": "\(taskId)",
                "progressToken": "\(progressToken)",
            ]
        )
    }

    func handleMessage(_ message: Message<AnyNotification>) async {
        logger?.trace(
            "Processing notification",
            metadata: ["method": "\(message.method)"]
        )

        // Check if this is a task status notification and clean up progress handlers
        // for terminal task statuses (per MCP spec, progress tokens are valid until terminal status).
        // Progress notification handling (callbacks and timeout signaling) is done by the protocol conformance
        // before the notification dispatcher fires.
        if message.method == TaskStatusNotification.name {
            await handleTaskStatusNotification(message)
        }

        // Dispatch to the notification processing task.
        // Handlers are invoked on a separate task so they don't block the message loop,
        // which must remain free to process responses to any requests the handlers make.
        notificationContinuation?.yield(message)
    }

    /// Handle a task status notification by cleaning up progress handlers for terminal tasks.
    ///
    /// Per MCP spec 2025-11-25: progress tokens continue throughout task lifetime until terminal status.
    /// This method automatically cleans up progress handlers when a task reaches completed, failed, or cancelled.
    func handleTaskStatusNotification(_ message: Message<AnyNotification>) async {
        do {
            let paramsData = try encoder.encode(message.params)
            let params = try decoder.decode(TaskStatusNotification.Parameters.self, from: paramsData)

            if params.status.isTerminal {
                cleanUpTaskProgressHandler(taskId: params.taskId)
            }
        } catch {
            // Don't log errors for task status notifications - they may not be task-related
        }
    }

    /// Handle an incoming request from the server (bidirectional communication).
    ///
    /// This enables server→client requests such as sampling, roots, and elicitation.
    ///
    /// ## Task-Augmented Request Handling
    ///
    /// For `sampling/createMessage` and `elicitation/create` requests, this method
    /// checks for a `task` field in the request params. If present, it routes to
    /// the task-augmented handler (which returns `CreateTaskResult`) instead of
    /// the normal handler.
    ///
    /// This follows the Python SDK pattern of storing task-augmented handlers
    /// separately and checking at dispatch time, rather than the TypeScript pattern
    /// of wrapping handlers at registration time. The Python pattern was chosen
    /// because:
    /// - It allows handlers to be registered in any order without losing task-awareness
    /// - It keeps task logic separate from normal handler logic
    /// - It's more explicit about which handler is called for which request type
    func handleIncomingRequest(_ request: Request<AnyMethod>) async {
        // --- Logging ---
        logger?.trace(
            "Processing incoming request from server",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ]
        )

        // --- Pre-dispatch validation ---
        // Elicitation mode validation requires runtime capabilities, so it stays at dispatch time.
        // Per spec: Client MUST return -32602 if server requests unsupported mode.
        if request.method == Elicit.name {
            if let modeError = await validateElicitationMode(request) {
                await sendResponse(modeError)
                return
            }
        }

        // --- Task-augmented routing ---
        // Check for task-augmented sampling/elicitation requests before normal handling.
        // This matches the Python SDK pattern where task detection happens at dispatch time.
        if let taskResponse = await handleTaskAugmentedRequest(request) {
            await sendResponse(taskResponse)
            return
        }

        // --- Handler lookup ---
        // Try specific handler first, then fallback handler
        let handler: ClientRequestHandlerBox
        if let specificHandler = registeredHandlers.requestHandlers[request.method] {
            handler = specificHandler
        } else if let fallbackHandler = registeredHandlers.fallbackRequestHandler {
            logger?.debug(
                "Using fallback handler for server request",
                metadata: ["method": "\(request.method)"]
            )
            handler = fallbackHandler
        } else {
            logger?.warning(
                "No handler registered for server request",
                metadata: ["method": "\(request.method)"]
            )
            let response = AnyMethod.response(
                id: request.id,
                error: MCPError.methodNotFound("Client has no handler for: \(request.method)")
            )
            await sendResponse(response)
            return
        }

        // --- Context creation ---
        // Create the request handler context with closures for sending notifications/requests.
        let requestMeta = extractMeta(from: request.params)
        let context = RequestHandlerContext(
            sessionId: nil,
            requestId: request.id,
            _meta: requestMeta,
            taskId: requestMeta?.relatedTaskId,
            authInfo: nil,
            requestInfo: nil,
            closeResponseStream: nil,
            closeNotificationStream: nil,
            sendNotification: { [weak self] notification in
                guard let self else {
                    throw MCPError.internalError("Client was deallocated")
                }
                guard let transport = await protocolState.transport else {
                    throw MCPError.internalError("Cannot send notification - client not connected")
                }
                let notificationData = try JSONEncoder().encode(notification)
                try await transport.send(notificationData)
            },
            sendRequest: { [weak self] requestData in
                guard let self else {
                    throw MCPError.internalError("Client was deallocated")
                }
                guard let transport = await protocolState.transport else {
                    throw MCPError.internalError("Cannot send request - client not connected")
                }
                try await transport.send(requestData)
                // Client doesn't support bidirectional requests from client handlers
                throw MCPError.internalError("Client handlers cannot send requests")
            }
        )

        // --- Execution with cancellation awareness ---
        // Per MCP spec: "Receivers of a cancellation notification SHOULD... Not send a response
        // for the cancelled request". Check cancellation on both success and error paths.
        do {
            let response = try await handler(request, context: context)

            if Task.isCancelled {
                logger?.debug(
                    "Server request cancelled, suppressing response",
                    metadata: ["id": "\(request.id)"]
                )
                return
            }

            await sendResponse(response)
        } catch {
            if Task.isCancelled {
                logger?.debug(
                    "Server request cancelled during error handling, suppressing response",
                    metadata: ["id": "\(request.id)"]
                )
                return
            }

            logger?.error(
                "Error handling server request",
                metadata: [
                    "method": "\(request.method)",
                    "error": "\(error)",
                ]
            )
            let errorResponse = AnyMethod.response(
                id: request.id,
                error: (error as? MCPError) ?? MCPError.internalError("An internal error occurred")
            )
            await sendResponse(errorResponse)
        }
    }

    /// Validate that an elicitation request uses a mode supported by client capabilities.
    ///
    /// Per MCP spec: Client MUST return -32602 (Invalid params) if server sends
    /// an elicitation/create request with a mode not declared in client capabilities.
    ///
    /// - Parameter request: The incoming elicitation request
    /// - Returns: An error response if mode is unsupported, nil if valid
    func validateElicitationMode(_ request: Request<AnyMethod>) async -> Response<AnyMethod>? {
        do {
            let paramsData = try encoder.encode(request.params)
            let params = try decoder.decode(Elicit.Parameters.self, from: paramsData)

            switch params {
                case .form:
                    // Form mode requires form capability
                    if capabilities.elicitation?.form == nil {
                        return Response(
                            id: request.id,
                            error: .invalidParams("Client does not support form elicitation mode")
                        )
                    }
                case .url:
                    // URL mode requires url capability
                    if capabilities.elicitation?.url == nil {
                        return Response(
                            id: request.id,
                            error: .invalidParams("Client does not support URL elicitation mode")
                        )
                    }
            }
        } catch {
            // If we can't decode the params, let the normal handler deal with it
            logger?.warning(
                "Failed to decode elicitation params for mode validation",
                metadata: ["error": "\(error)"]
            )
        }

        return nil
    }

    /// Check if a request is task-augmented and handle it if so.
    ///
    /// - Parameter request: The incoming request
    /// - Returns: A response if the request was task-augmented and handled, nil otherwise
    func handleTaskAugmentedRequest(_ request: Request<AnyMethod>) async -> Response<AnyMethod>? {
        do {
            // Check for task-augmented sampling request
            if request.method == CreateSamplingMessage.name,
               let taskHandler = registeredHandlers.taskAugmentedSamplingHandler
            {
                let paramsData = try encoder.encode(request.params)
                let params = try decoder.decode(CreateSamplingMessage.Parameters.self, from: paramsData)

                if let taskMetadata = params.task {
                    let result = try await taskHandler(params, taskMetadata)
                    let resultData = try encoder.encode(result)
                    let resultValue = try decoder.decode(Value.self, from: resultData)
                    return Response(id: request.id, result: resultValue)
                }
            }

            // Check for task-augmented elicitation request
            if request.method == Elicit.name,
               let taskHandler = registeredHandlers.taskAugmentedElicitationHandler
            {
                let paramsData = try encoder.encode(request.params)
                let params = try decoder.decode(Elicit.Parameters.self, from: paramsData)

                let taskMetadata: TaskMetadata? = switch params {
                    case let .form(formParams): formParams.task
                    case let .url(urlParams): urlParams.task
                }

                if let taskMetadata {
                    let result = try await taskHandler(params, taskMetadata)
                    let resultData = try encoder.encode(result)
                    let resultValue = try decoder.decode(Value.self, from: resultData)
                    return Response(id: request.id, result: resultValue)
                }
            }
        } catch let error as MCPError {
            return Response(id: request.id, error: error)
        } catch {
            // Log full error for debugging, but sanitize for response
            logger?.error("Task handler error", metadata: ["error": "\(error)"])
            return Response(id: request.id, error: MCPError.internalError("An internal error occurred"))
        }

        // Not a task-augmented request
        return nil
    }

    /// Send a response back to the server.
    func sendResponse(_ response: Response<AnyMethod>) async {
        guard let transport = protocolState.transport else {
            logger?.warning("Cannot send response - client not connected")
            return
        }

        do {
            let responseData = try encoder.encode(response)
            try await transport.send(responseData)
        } catch {
            logger?.error(
                "Failed to send response to server",
                metadata: ["error": "\(error)"]
            )
        }
    }

    // MARK: -

    /// Validate the server capabilities.
    /// Throws an error if the client is configured to be strict and the capability is not supported.
    func validateServerCapability(
        _ keyPath: KeyPath<Server.Capabilities, (some Any)?>,
        _ name: String
    )
        throws
    {
        if configuration.strict {
            guard let capabilities = serverCapabilities else {
                throw MCPError.methodNotFound("Server capabilities not initialized")
            }
            guard capabilities[keyPath: keyPath] != nil else {
                throw MCPError.methodNotFound("\(name) is not supported by the server")
            }
        }
    }

    // Batch responses are handled natively by the protocol conformance's handleTransportMessage.
}
