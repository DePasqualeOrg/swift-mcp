// Copyright © Anthony DePasquale

import Foundation

public extension Client {
    // MARK: - Request Options

    /// Options that can be given per request.
    ///
    /// Similar to TypeScript SDK's `RequestOptions`, this allows configuring
    /// timeout behavior for individual requests, including progress-aware timeouts.
    struct RequestOptions: Sendable {
        /// The default request timeout (60 seconds), matching TypeScript SDK.
        public static let defaultTimeout: Duration = .seconds(60)

        /// A timeout for this request.
        ///
        /// If exceeded, the request will be cancelled and an `MCPError.requestTimeout`
        /// will be thrown. A `CancelledNotification` will also be sent to the server.
        ///
        /// If `nil`, no timeout is applied (the request can wait indefinitely).
        /// Default is `nil` to match existing behavior.
        public var timeout: Duration?

        /// If `true`, receiving a progress notification resets the timeout clock.
        ///
        /// This is useful for long-running operations that send periodic progress updates.
        /// As long as the server keeps sending progress, the request won't time out.
        ///
        /// When combined with `maxTotalTimeout`, this allows both:
        /// - Per-interval timeout that resets on progress
        /// - Overall hard limit that prevents infinite waiting
        ///
        /// Default is `false`.
        ///
        /// - Note: Only effective when `timeout` is set and the request uses `onProgress`.
        public var resetTimeoutOnProgress: Bool

        /// Maximum total time to wait for the request, regardless of progress.
        ///
        /// When `resetTimeoutOnProgress` is `true`, this provides a hard upper limit
        /// on the total wait time. Even if progress notifications keep arriving,
        /// the request will be cancelled if this limit is exceeded.
        ///
        /// If `nil`, there's no maximum total timeout (only the regular `timeout`
        /// applies, potentially reset by progress).
        ///
        /// - Note: Only effective when both `timeout` and `resetTimeoutOnProgress` are set.
        public var maxTotalTimeout: Duration?

        /// Creates request options with the specified configuration.
        ///
        /// - Parameters:
        ///   - timeout: The timeout duration, or `nil` for no timeout.
        ///   - resetTimeoutOnProgress: Whether to reset the timeout when progress is received.
        ///   - maxTotalTimeout: Maximum total time to wait regardless of progress.
        public init(
            timeout: Duration? = nil,
            resetTimeoutOnProgress: Bool = false,
            maxTotalTimeout: Duration? = nil,
        ) {
            self.timeout = timeout
            self.resetTimeoutOnProgress = resetTimeoutOnProgress
            self.maxTotalTimeout = maxTotalTimeout
        }

        /// Request options with the default timeout (60 seconds).
        public static let withDefaultTimeout = RequestOptions(timeout: defaultTimeout)

        /// Request options with no timeout.
        public static let noTimeout = RequestOptions(timeout: nil)
    }

    // MARK: - Requests

    /// Send a request and receive its response.
    ///
    /// This method sends a request without a timeout. For timeout support,
    /// use `send(_:options:)` instead.
    func send<M: Method>(_ request: Request<M>) async throws -> M.Result {
        try await send(request, options: nil)
    }

    /// Send a request and receive its response with options.
    ///
    /// Delegates to the protocol conformance for request tracking, timeout, and response matching.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - options: Options for this request, including timeout configuration.
    /// - Returns: The response result.
    /// - Throws: `MCPError.requestTimeout` if the timeout is exceeded.
    func send<M: Method>(
        _ request: Request<M>,
        options: RequestOptions?,
    ) async throws -> M.Result {
        guard isProtocolConnected else {
            throw MCPError.internalError("Client connection not initialized")
        }

        let requestData = try encoder.encode(request)
        let requestId = request.id

        do {
            let protocolOptions = ProtocolRequestOptions(
                timeout: options?.timeout,
                resetTimeoutOnProgress: options?.resetTimeoutOnProgress ?? false,
                maxTotalTimeout: options?.maxTotalTimeout,
            )

            let responseData = try await sendProtocolRequest(
                requestData,
                requestId: requestId,
                options: protocolOptions,
            )

            return try decoder.decode(M.Result.self, from: responseData)
        } catch {
            // Send CancelledNotification for timeouts and task cancellations per MCP spec.
            // Check Task.isCancelled as well since the error may propagate as
            // MCPError.connectionClosed when the stream ends due to cancellation.
            if error is CancellationError || Task.isCancelled {
                await sendCancellationNotification(
                    requestId: requestId,
                    reason: "Client cancelled the request",
                )
            } else if case let .requestTimeout(t, _) = error as? MCPError {
                await sendCancellationNotification(
                    requestId: requestId,
                    reason: "Request timed out after \(t)",
                )
            }
            throw error
        }
    }

    /// Send a request with a progress callback.
    ///
    /// This method automatically sets up progress tracking by:
    /// 1. Generating a unique progress token based on the request ID
    /// 2. Injecting the token into the request's `_meta.progressToken`
    /// 3. Invoking the callback when progress notifications are received
    ///
    /// The callback is automatically cleaned up when the request completes.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = try await client.send(
    ///     CallTool.request(.init(name: "slow_operation", arguments: ["steps": 5])),
    ///     onProgress: { progress in
    ///         print("Progress: \(progress.value)/\(progress.total ?? 0) - \(progress.message ?? "")")
    ///     }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - request: The request to send
    ///   - onProgress: A callback invoked when progress notifications are received
    /// - Returns: The response result
    func send<M: Method>(
        _ request: Request<M>,
        onProgress: @escaping ProgressCallback,
    ) async throws -> M.Result {
        try await send(request, options: nil, onProgress: onProgress)
    }

    /// Send a request with options and a progress callback.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - options: Options for this request, including timeout configuration.
    ///   - onProgress: A callback invoked when progress notifications are received.
    /// - Returns: The response result.
    /// - Throws: `MCPError.requestTimeout` if the timeout is exceeded.
    func send<M: Method>(
        _ request: Request<M>,
        options: RequestOptions?,
        onProgress: @escaping ProgressCallback,
    ) async throws -> M.Result {
        guard isProtocolConnected else {
            throw MCPError.internalError("Client connection not initialized")
        }

        // Use request ID as the progress token (matching TypeScript/Python SDK behavior).
        // This provides a natural, deterministic mapping without separate token generation.
        let progressToken: ProgressToken = switch request.id {
            case let .number(n): .integer(n)
            case let .string(s): .string(s)
        }

        // Encode the request
        let requestData = try encoder.encode(request)
        let requestId = request.id

        // Build protocol options with progress tracking
        let protocolOptions = ProtocolRequestOptions(
            progressToken: progressToken,
            onProgress: { params in
                let progress = Progress(
                    value: params.progress,
                    total: params.total,
                    message: params.message,
                )
                await onProgress(progress)
            },
            timeout: options?.timeout,
            resetTimeoutOnProgress: options?.resetTimeoutOnProgress ?? false,
            maxTotalTimeout: options?.maxTotalTimeout,
        )

        // Build metadata values to inject (progressToken).
        // The progressToken overwrites any user-provided token (matching TypeScript SDK behavior).
        let progressTokenValue: Value = switch progressToken {
            case let .string(s): .string(s)
            case let .integer(n): .int(n)
        }
        let metaValues: [String: Value] = ["progressToken": progressTokenValue]

        do {
            // Pass metadata values to ProtocolLayer for injection
            let responseData = try await sendProtocolRequest(
                requestData,
                requestId: requestId,
                options: protocolOptions,
                metaValues: metaValues,
            )

            return try decoder.decode(M.Result.self, from: responseData)
        } catch {
            // Send CancelledNotification for timeouts and task cancellations per MCP spec.
            // Check Task.isCancelled as well since the error may propagate as
            // MCPError.connectionClosed when the stream ends due to cancellation.
            if error is CancellationError || Task.isCancelled {
                await sendCancellationNotification(
                    requestId: requestId,
                    reason: "Client cancelled the request",
                )
            } else if case let .requestTimeout(t, _) = error as? MCPError {
                await sendCancellationNotification(
                    requestId: requestId,
                    reason: "Request timed out after \(t)",
                )
            }
            throw error
        }
    }

    // MARK: - Request Cancellation

    /// Cancel an in-flight request by its ID.
    ///
    /// This method cancels a pending request and sends a `CancelledNotification` to the server.
    /// Use this when you need to cancel a request that was sent earlier but hasn't completed yet.
    ///
    /// Per MCP spec: "When a party wants to cancel an in-progress request, it sends a
    /// `notifications/cancelled` notification containing the ID of the request to cancel."
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a request with a known ID
    /// let requestId = RequestId.string("my-request-123")
    /// let request = CallTool.request(id: requestId, .init(name: "slow_operation"))
    ///
    /// // Start the request in a separate task
    /// Task {
    ///     do {
    ///         let result = try await client.send(request)
    ///         print("Result: \(result)")
    ///     } catch let error as MCPError where error.code == MCPError.Code.requestCancelled {
    ///         print("Request was cancelled")
    ///     }
    /// }
    ///
    /// // Later, cancel it by ID
    /// try await client.cancelRequest(requestId, reason: "User cancelled")
    /// ```
    ///
    /// - Parameters:
    ///   - id: The ID of the request to cancel. This must match the ID used when sending the request.
    ///   - reason: An optional human-readable reason for the cancellation, for logging/debugging.
    /// - Throws: This method does not throw. Cancellation notifications are best-effort per the spec.
    ///
    /// - Note: If the request has already completed or is unknown, this is a no-op per the MCP spec.
    /// - Note: The `initialize` request MUST NOT be cancelled per the MCP spec.
    /// - Important: For task-augmented requests, use the `tasks/cancel` method instead.
    func cancelRequest(_ id: RequestId, reason: String? = nil) async {
        // Cancel pending request and clean up progress/timeout state
        cancelProtocolPendingRequest(
            id: id,
            error: MCPError.requestCancelled(reason: reason),
        )
        cleanUpRequestProgress(requestId: id)

        // Send cancellation notification to server (best-effort)
        await sendCancellationNotification(requestId: id, reason: reason)
    }

    /// Send a CancelledNotification to the server for a cancelled request.
    ///
    /// Per MCP spec: "When a party wants to cancel an in-progress request, it sends
    /// a `notifications/cancelled` notification containing the ID of the request to cancel."
    ///
    /// This is called when a client Task waiting for a response is cancelled.
    /// The notification is sent on a best-effort basis - failures are logged but not thrown.
    internal func sendCancellationNotification(requestId: RequestId, reason: String?) async {
        guard let transport = protocolState.transport else {
            logger?.debug(
                "Cannot send cancellation notification - not connected",
                metadata: ["requestId": "\(requestId)"],
            )
            return
        }

        let notification = CancelledNotification.message(.init(
            requestId: requestId,
            reason: reason,
        ))

        do {
            let notificationData = try encoder.encode(notification)
            try await transport.send(notificationData)
            logger?.debug(
                "Sent cancellation notification",
                metadata: [
                    "requestId": "\(requestId)",
                    "reason": "\(reason ?? "none")",
                ],
            )
        } catch {
            // Log but don't throw - cancellation notification is best-effort
            // per MCP spec's fire-and-forget nature of notifications
            logger?.debug(
                "Failed to send cancellation notification",
                metadata: [
                    "requestId": "\(requestId)",
                    "error": "\(error)",
                ],
            )
        }
    }

    // MARK: - Batching

    /// A batch of requests.
    ///
    /// Objects of this type are passed as an argument to the closure
    /// of the ``Client/withBatch(body:)`` method.
    actor Batch {
        unowned let client: Client
        var requests: [AnyRequest] = []

        init(client: Client) {
            self.client = client
        }

        /// Adds a request to the batch and prepares its expected response task.
        /// The actual sending happens when the `withBatch` scope completes.
        /// - Returns: A `Task` that will eventually produce the result or throw an error.
        public func addRequest<M: Method>(_ request: Request<M>) async throws -> Task<
            M.Result, Swift.Error,
        > {
            try requests.append(AnyRequest(request))

            // Register pending request (will be matched when response arrives)
            let stream = await client.registerProtocolPendingRequest(id: request.id)

            // Return a Task that waits for the response via the stream and decodes it
            return Task<M.Result, Swift.Error> {
                for try await data in stream {
                    return try JSONDecoder().decode(M.Result.self, from: data)
                }
                throw MCPError.internalError("No response received")
            }
        }
    }

    /// Executes multiple requests in a single batch.
    ///
    /// This method allows you to group multiple MCP requests together,
    /// which are then sent to the server as a single JSON array.
    /// The server processes these requests and sends back a corresponding
    /// JSON array of responses.
    ///
    /// Within the `body` closure, use the provided `Batch` actor to add
    /// requests using `batch.addRequest(_:)`. Each call to `addRequest`
    /// returns a `Task` handle representing the asynchronous operation
    /// for that specific request's result.
    ///
    /// It's recommended to collect these `Task` handles into an array
    /// within the `body` closure`. After the `withBatch` method returns
    /// (meaning the batch request has been sent), you can then process
    /// the results by awaiting each `Task` in the collected array.
    ///
    /// Example 1: Batching multiple tool calls and collecting typed tasks:
    /// ```swift
    /// // Array to hold the task handles for each tool call
    /// var toolTasks: [Task<CallTool.Result, Error>] = []
    /// try await client.withBatch { batch in
    ///     for i in 0..<10 {
    ///         toolTasks.append(
    ///             try await batch.addRequest(
    ///                 CallTool.request(.init(name: "square", arguments: ["n": i]))
    ///             )
    ///         )
    ///     }
    /// }
    ///
    /// // Process results after the batch is sent
    /// print("Processing \(toolTasks.count) tool results...")
    /// for (index, task) in toolTasks.enumerated() {
    ///     do {
    ///         let result = try await task.value
    ///         print("\(index): \(result.content)")
    ///     } catch {
    ///         print("\(index) failed: \(error)")
    ///     }
    /// }
    /// ```
    ///
    /// Example 2: Batching different request types and awaiting individual tasks:
    /// ```swift
    /// // Declare optional task variables beforehand
    /// var pingTask: Task<Ping.Result, Error>?
    /// var promptTask: Task<GetPrompt.Result, Error>?
    ///
    /// try await client.withBatch { batch in
    ///     // Assign the tasks within the batch closure
    ///     pingTask = try await batch.addRequest(Ping.request())
    ///     promptTask = try await batch.addRequest(GetPrompt.request(.init(name: "greeting")))
    /// }
    ///
    /// // Await the results after the batch is sent
    /// do {
    ///     if let pingTask {
    ///         try await pingTask.value // Await ping result (throws if ping failed)
    ///         print("Ping successful")
    ///     }
    ///     if let promptTask {
    ///         let promptResult = try await promptTask.value // Await prompt result
    ///         print("Prompt description: \(promptResult.description ?? "None")")
    ///     }
    /// } catch {
    ///     print("Error processing batch results: \(error)")
    /// }
    /// ```
    ///
    /// - Parameter body: An asynchronous closure that takes a `Batch` object as input.
    ///                   Use this object to add requests to the batch.
    /// - Throws: `MCPError.internalError` if the client is not connected.
    ///           Can also rethrow errors from the `body` closure or from sending the batch request.
    func withBatch(body: @escaping (Batch) async throws -> Void) async throws {
        guard let transport = protocolState.transport else {
            throw MCPError.internalError("Client connection not initialized")
        }

        // Create Batch actor, passing self (Client)
        let batch = Batch(client: self)

        // Populate the batch actor by calling the user's closure.
        try await body(batch)

        // Get the collected requests from the batch actor
        let requests = await batch.requests

        // Check if there are any requests to send
        guard !requests.isEmpty else {
            logger?.debug("Batch requested but no requests were added.")
            return // Nothing to send
        }

        logger?.debug(
            "Sending batch request", metadata: ["count": "\(requests.count)"],
        )

        // Encode the array of AnyMethod requests into a single JSON payload
        let data = try encoder.encode(requests)
        try await transport.send(data)

        // Responses will be handled asynchronously by the protocol conformance's batch response detection
        // which matches each response against the registered pending requests.
    }
}
