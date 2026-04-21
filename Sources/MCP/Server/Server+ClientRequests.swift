// Copyright © Anthony DePasquale

import Foundation

extension Server {
    // MARK: - Server to Client Requests

    /// Send a request to the client and wait for a response.
    ///
    /// This enables bidirectional communication where the server can request
    /// information from the client (e.g., roots, sampling, elicitation).
    ///
    /// Delegates to the protocol conformance for request tracking and response matching.
    ///
    /// - Parameter request: The request to send
    /// - Returns: The result from the client
    public func sendRequest<M: MCPCore.Method>(_ request: Request<M>) async throws -> M.Result {
        guard let connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        guard await connection.supportsServerToClientRequests else {
            throw MCPError.invalidRequest(
                "Server-to-client requests are not supported by this transport. " +
                    "The transport does not support bidirectional communication.",
            )
        }

        guard isProtocolConnected else {
            throw MCPError.internalError("Server protocol not initialized")
        }

        let requestData = try encoder.encode(request)

        let responseData = try await sendProtocolRequest(requestData, requestId: request.id)
        return try decoder.decode(M.Result.self, from: responseData)
    }

    // MARK: - In-Flight Request Tracking (Protocol-Level Cancellation)

    /// Track an in-flight request handler Task.
    func trackInFlightRequest(_ requestId: RequestId, task: Task<Void, Never>) {
        registeredHandlers.inFlightHandlerTasks[requestId] = task
    }

    /// Remove an in-flight request handler Task.
    func removeInFlightRequest(_ requestId: RequestId) {
        registeredHandlers.inFlightHandlerTasks.removeValue(forKey: requestId)
    }

    /// Cancel an in-flight request handler Task.
    ///
    /// Called when a CancelledNotification is received for a specific requestId.
    /// Per MCP spec, if the request is unknown or already completed, this is a no-op.
    func cancelInFlightRequest(_ requestId: RequestId, reason: String?) async {
        if let task = registeredHandlers.inFlightHandlerTasks[requestId] {
            task.cancel()
            logger?.debug(
                "Cancelled in-flight request",
                metadata: [
                    "id": "\(requestId)",
                    "reason": "\(reason ?? "none")",
                ],
            )
        }
        // Per spec: MAY ignore if request is unknown - no error needed
    }

    /// Generate a unique request ID for server→client requests.
    func generateRequestId() -> RequestId {
        generateProtocolRequestId()
    }

    /// Request the list of roots from the client.
    ///
    /// Roots represent filesystem directories that the client has access to.
    /// Servers can use this to understand the scope of files they can work with.
    ///
    /// - Throws: MCPError if the client doesn't support roots or if the request fails.
    /// - Returns: The list of roots from the client.
    public func listRoots() async throws -> [Root] {
        // Check that client supports roots
        guard clientCapabilities?.roots != nil else {
            throw MCPError.invalidRequest("Client does not support roots capability")
        }

        let request: Request<ListRoots> = ListRoots.request(id: generateRequestId())
        let result = try await sendRequest(request)
        return result.roots
    }

    /// Request a sampling completion from the client (without tools).
    ///
    /// This enables servers to request LLM completions through the client,
    /// allowing sophisticated agentic behaviors while maintaining security.
    ///
    /// The result will be a single content block (text, image, or audio).
    /// For tool-enabled sampling, use `createMessageWithTools(_:)` instead.
    ///
    /// - Parameter params: The sampling parameters including messages, model preferences, etc.
    /// - Throws: MCPError if the client doesn't support sampling or if the request fails.
    /// - Returns: The sampling result from the client containing a single content block.
    public func createMessage(_ params: CreateSamplingMessage.Parameters) async throws -> CreateSamplingMessage.Result {
        // Check that client supports sampling
        guard clientCapabilities?.sampling != nil else {
            throw MCPError.invalidRequest("Client does not support sampling capability")
        }

        let request: Request<CreateSamplingMessage> = CreateSamplingMessage.request(id: generateRequestId(), params)
        return try await sendRequest(request)
    }

    /// Request a sampling completion from the client with tool support.
    ///
    /// This enables servers to request LLM completions that may involve tool use.
    /// The result may contain tool use content, and content can be an array for parallel tool calls.
    ///
    /// - Parameter params: The sampling parameters including messages, tools, and model preferences.
    /// - Throws: MCPError if the client doesn't support sampling or tool capabilities.
    /// - Returns: The sampling result from the client, which may include tool use content.
    public func createMessageWithTools(_ params: CreateSamplingMessageWithTools.Parameters) async throws -> CreateSamplingMessageWithTools.Result {
        // Check that client supports sampling
        guard clientCapabilities?.sampling != nil else {
            throw MCPError.invalidRequest("Client does not support sampling capability")
        }

        // Check tools capability
        guard clientCapabilities?.sampling?.tools != nil else {
            throw MCPError.invalidRequest("Client does not support sampling tools capability")
        }

        // Validate tool_use/tool_result message structure per MCP specification
        try Sampling.Message.validateToolUseResultMessages(params.messages)

        let request: Request<CreateSamplingMessageWithTools> = CreateSamplingMessageWithTools.request(id: generateRequestId(), params)
        return try await sendRequest(request)
    }

    /// Request user input via elicitation from the client.
    ///
    /// Elicitation allows servers to request structured input from users through
    /// the client, either via forms or external URLs (e.g., OAuth flows).
    ///
    /// - Parameter params: The elicitation parameters.
    /// - Throws: MCPError if the client doesn't support elicitation or if the request fails.
    /// - Returns: The elicitation result from the client.
    public func elicit(_ params: Elicit.Parameters) async throws -> Elicit.Result {
        // Check that client supports elicitation
        guard clientCapabilities?.elicitation != nil else {
            throw MCPError.invalidRequest("Client does not support elicitation capability")
        }

        // Check mode-specific capabilities
        switch params {
            case .form:
                guard clientCapabilities?.elicitation?.form != nil else {
                    throw MCPError.invalidRequest("Client does not support form elicitation")
                }
            case .url:
                guard clientCapabilities?.elicitation?.url != nil else {
                    throw MCPError.invalidRequest("Client does not support URL elicitation")
                }
        }

        let request: Request<Elicit> = Elicit.request(id: generateRequestId(), params)
        var result = try await sendRequest(request)

        // Apply schema defaults and validate elicitation response (form mode only)
        if case let .form(formParams) = params,
           result.action == .accept,
           let content = result.content
        {
            // Apply schema defaults to missing fields before validation
            var contentWithDefaults = content
            applyElicitationDefaults(from: formParams.requestedSchema, to: &contentWithDefaults)
            result.content = contentWithDefaults

            // Validate against schema
            let schemaValue = try Value(formParams.requestedSchema)
            let contentValue = elicitContentToValue(contentWithDefaults)
            try validator.validate(contentValue, against: schemaValue)
        }

        return result
    }

    /// Applies schema defaults to elicitation content for missing fields.
    ///
    /// Walks the schema's `properties` and fills in any missing content fields
    /// that have a `default` value defined in the schema.
    private func applyElicitationDefaults(
        from schema: ElicitationSchema,
        to content: inout [String: ElicitValue],
    ) {
        for (key, property) in schema.properties {
            // Skip if content already has this key
            guard content[key] == nil else { continue }

            // Apply default if present
            if let defaultValue = property.default {
                content[key] = defaultValue
            }
        }
    }

    /// Converts elicitation content to a Value for JSON Schema validation.
    private func elicitContentToValue(_ content: [String: ElicitValue]) -> Value {
        var dict: [String: Value] = [:]
        for (key, elicitValue) in content {
            switch elicitValue {
                case let .string(s):
                    dict[key] = .string(s)
                case let .int(i):
                    dict[key] = .int(i)
                case let .double(d):
                    dict[key] = .double(d)
                case let .bool(b):
                    dict[key] = .bool(b)
                case let .strings(arr):
                    dict[key] = .array(arr.map { .string($0) })
            }
        }
        return .object(dict)
    }

    // MARK: - Client Task Polling (Server → Client)

    /// Get a task from the client.
    ///
    /// Internal method used by experimental server task features.
    func getClientTask(taskId: String) async throws -> GetTask.Result {
        guard clientCapabilities?.tasks != nil else {
            throw MCPError.invalidRequest("Client does not support tasks capability")
        }

        let request = GetTask.request(.init(taskId: taskId))
        return try await sendRequest(request)
    }

    /// Get the result payload of a client task.
    ///
    /// Internal method used by experimental server task features.
    func getClientTaskResult(taskId: String) async throws -> GetTaskPayload.Result {
        guard clientCapabilities?.tasks != nil else {
            throw MCPError.invalidRequest("Client does not support tasks capability")
        }

        let request = GetTaskPayload.request(.init(taskId: taskId))
        return try await sendRequest(request)
    }

    /// Get the task result decoded as a specific type.
    ///
    /// Internal method used by experimental server task features.
    func getClientTaskResultAs<T: Decodable & Sendable>(taskId: String, type _: T.Type) async throws -> T {
        let result = try await getClientTaskResult(taskId: taskId)

        // The result's extraFields contain the actual result payload
        guard let extraFields = result.extraFields else {
            throw MCPError.invalidParams("Task result has no payload")
        }

        // Convert extraFields to the target type
        let jsonData = try encoder.encode(extraFields)
        return try decoder.decode(T.self, from: jsonData)
    }
}
