// Copyright © Anthony DePasquale

import Foundation

public extension Client {
    // MARK: - Handler Registration

    /// Register a handler for a notification.
    func onNotification<N: Notification>(
        _: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) {
        notificationHandlers[N.name, default: []].append(TypedNotificationHandler(handler))
    }

    /// Send a notification to the server
    func notify(_ notification: Message<some Notification>) async throws {
        guard let connection else {
            throw MCPError.internalError("Client connection not initialized")
        }

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Send a progress notification to the server.
    ///
    /// This is a convenience method for sending progress notifications from the client
    /// to the server. This enables bidirectional progress reporting where clients can
    /// inform servers about their own progress (e.g., during client-side processing).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Client reports its own progress to the server
    /// try await client.sendProgressNotification(
    ///     token: .string("client-task-123"),
    ///     progress: 50.0,
    ///     total: 100.0,
    ///     message: "Processing client-side data..."
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - token: The progress token to associate with this notification
    ///   - progress: The current progress value (should increase monotonically)
    ///   - total: The total progress value, if known
    ///   - message: An optional human-readable message describing current progress
    func sendProgressNotification(
        token: ProgressToken,
        progress: Double,
        total: Double? = nil,
        message: String? = nil
    ) async throws {
        try await notify(ProgressNotification.message(.init(
            progressToken: token,
            progress: progress,
            total: total,
            message: message
        )))
    }

    /// Send a notification that the list of available roots has changed.
    ///
    /// Servers that receive this notification should request an updated
    /// list of roots via the roots/list request.
    ///
    /// - Throws: `MCPError.invalidRequest` if the client has not declared
    ///   the `roots.listChanged` capability.
    func sendRootsChanged() async throws {
        guard capabilities.roots?.listChanged == true else {
            throw MCPError.invalidRequest(
                "Client does not support roots.listChanged capability")
        }
        try await notify(RootsListChangedNotification.message(.init()))
    }

    /// Register a handler for server→client requests.
    ///
    /// This enables bidirectional communication where the server can send requests
    /// to the client (e.g., sampling, roots, elicitation).
    ///
    /// The handler receives a `RequestHandlerContext` that provides:
    /// - `isCancelled` and `checkCancellation()` for responding to cancellation
    /// - `sendProgressNotification()` for reporting progress back to the server
    ///
    /// ## Example
    ///
    /// ```swift
    /// client.withRequestHandler(CreateSamplingMessage.self) { params, context in
    ///     // Check for cancellation during long operations
    ///     try context.checkCancellation()
    ///
    ///     // Process the request
    ///     let result = try await processRequest(params)
    ///
    ///     return result
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - type: The method type to handle
    ///   - handler: The handler function that receives parameters and context, returns a result
    func withRequestHandler<M: Method>(
        _: M.Type,
        handler: @escaping @Sendable (M.Parameters, RequestHandlerContext) async throws -> M.Result
    ) {
        requestHandlers[M.name] = TypedClientRequestHandler<M>(handler)
    }

    /// Register a handler for `roots/list` requests from the server.
    ///
    /// Automatically advertises the `roots` capability.
    /// Must be called before `connect()`.
    ///
    /// When the server requests the list of roots, this handler will be called
    /// to provide the available filesystem directories.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Dynamic roots that may change
    /// await client.withRootsHandler(listChanged: true) { context in
    ///     return await workspace.getCurrentRoots()
    /// }
    ///
    /// // Static roots (consider using withStaticRoots instead)
    /// await client.withRootsHandler { context in
    ///     return [
    ///         Root(uri: "file:///home/user/project", name: "Project"),
    ///         Root(uri: "file:///home/user/docs", name: "Documents")
    ///     ]
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - listChanged: Whether the client will send `roots/list_changed` notifications
    ///     when roots change. Set to `true` if your roots can change during the session
    ///     and you will call `sendRootsChanged()` to notify the server. Default: `false`.
    ///   - handler: A closure that receives the request context and returns the list of available roots.
    /// - Precondition: Must not be called after `connect()`.
    func withRootsHandler(
        listChanged: Bool = false,
        handler: @escaping @Sendable (RequestHandlerContext) async throws -> [Root]
    ) {
        precondition(
            !handlersLocked,
            "Cannot register handlers after connect(). Register all handlers before calling connect()."
        )
        rootsConfig = RootsConfig(listChanged: listChanged)
        withRequestHandler(ListRoots.self) { _, context in
            try await ListRoots.Result(roots: handler(context))
        }
    }

    /// Register a static list of roots that never changes.
    ///
    /// This is a convenience method for the common case where roots are known at startup
    /// and don't change during the session. For dynamic roots that may change, use
    /// `withRootsHandler(listChanged:handler:)` instead.
    ///
    /// Must be called before `connect()`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let client = Client(name: "MyClient", version: "1.0")
    /// await client.withStaticRoots([
    ///     Root(uri: "file:///home/user/project", name: "Project"),
    ///     Root(uri: "file:///home/user/docs", name: "Documents")
    /// ])
    ///
    /// try await client.connect(transport: transport)
    /// ```
    ///
    /// - Parameter roots: The fixed list of roots to return for all requests.
    /// - Precondition: Must not be called after `connect()`.
    func withStaticRoots(_ roots: [Root]) {
        withRootsHandler(listChanged: false) { _ in roots }
    }

    /// Configure experimental task capabilities.
    ///
    /// Automatically advertises the `tasks` capability with the specified configuration.
    /// Must be called before `connect()`.
    ///
    /// The `Tasks` capability controls support for task-augmented requests:
    /// - `list`: Whether the client supports `tasks/list` requests
    /// - `cancel`: Whether the client supports `tasks/cancel` requests
    /// - `requests.sampling.createMessage`: Support for task-augmented sampling
    /// - `requests.elicitation.create`: Support for task-augmented elicitation
    ///
    /// - Note: This is an experimental feature that may change without notice.
    ///
    /// - Parameter config: Configuration for task capability support.
    /// - Precondition: Must not be called after `connect()`.
    func withTasksCapability(_ config: Capabilities.Tasks) {
        precondition(
            !handlersLocked,
            "Cannot register handlers after connect(). Register all handlers before calling connect()."
        )
        tasksConfig = config
    }

    /// Register a handler for `sampling/createMessage` requests from the server.
    ///
    /// Automatically advertises the `sampling` capability with the specified sub-capabilities.
    /// Must be called before `connect()`.
    ///
    /// When the server requests a sampling completion, this handler will be called
    /// to generate the LLM response.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let client = Client(name: "MyClient", version: "1.0")
    /// await client.withSamplingHandler(supportsTools: true) { params, context in
    ///     // Check for cancellation during long operations
    ///     try context.checkCancellation()
    ///
    ///     // Call your LLM with the messages
    ///     let response = try await llm.complete(
    ///         messages: params.messages,
    ///         tools: params.tools,  // Available when supportsTools is true
    ///         maxTokens: params.maxTokens
    ///     )
    ///
    ///     return ClientSamplingRequest.Result(
    ///         model: "gpt-4",
    ///         stopReason: .endTurn,
    ///         role: .assistant,
    ///         content: .text(response.text)
    ///     )
    /// }
    ///
    /// try await client.connect(transport: transport)
    /// ```
    ///
    /// - Parameters:
    ///   - supportsContext: Whether the client supports `includeContext` parameter values
    ///     other than "none". When `true`, servers may request context from this or all servers.
    ///     Default: `false`.
    ///   - supportsTools: Whether the client supports `tools` and `toolChoice` parameters
    ///     in sampling requests. When `true`, servers may include tools for the LLM to use.
    ///     Default: `false`.
    ///   - handler: A closure that receives sampling parameters and context, returns the result.
    /// - Precondition: Must not be called after `connect()`.
    func withSamplingHandler(
        supportsContext: Bool = false,
        supportsTools: Bool = false,
        handler: @escaping @Sendable (ClientSamplingRequest.Parameters, RequestHandlerContext) async throws -> ClientSamplingRequest.Result
    ) {
        precondition(
            !handlersLocked,
            "Cannot register handlers after connect(). Register all handlers before calling connect()."
        )
        samplingConfig = SamplingConfig(supportsContext: supportsContext, supportsTools: supportsTools)
        withRequestHandler(ClientSamplingRequest.self, handler: handler)
    }

    /// Register a handler for `elicitation/create` requests from the server.
    ///
    /// Automatically advertises the `elicitation` capability with the specified mode support.
    /// Must be called before `connect()`.
    ///
    /// When the server requests user input via elicitation, this handler will be called
    /// to collect the input and return the result. The handler receives parameters that
    /// include the requested mode (`form` or `url`).
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Form mode only (default)
    /// await client.withElicitationHandler { params, context in
    ///     guard case .form(let formParams) = params else {
    ///         return ElicitResult(action: .decline)
    ///     }
    ///     let userInput = try await presentForm(formParams.requestedSchema)
    ///     return ElicitResult(action: .accept, content: userInput)
    /// }
    ///
    /// // Both modes
    /// await client.withElicitationHandler(
    ///     formMode: .enabled(applyDefaults: true),
    ///     urlMode: .enabled
    /// ) { params, context in
    ///     switch params {
    ///         case .form(let formParams):
    ///             return try await handleFormElicitation(formParams)
    ///         case .url(let urlParams):
    ///             return try await handleUrlElicitation(urlParams)
    ///     }
    /// }
    ///
    /// // URL mode only
    /// await client.withElicitationHandler(formMode: nil, urlMode: .enabled) { params, context in
    ///     // Handle OAuth flow
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - formMode: Configuration for form-mode support. Pass `.enabled(applyDefaults:)` to support
    ///     form elicitation, or `nil` to disable. Default: `.enabled()`.
    ///   - urlMode: Configuration for URL-mode support (OAuth flows, etc.). Pass `.enabled` to support,
    ///     or `nil` to disable. Default: `nil`.
    ///   - handler: A closure that receives elicitation parameters and context, returns the result.
    /// - Precondition: Must not be called after `connect()`.
    /// - Precondition: At least one mode must be enabled.
    func withElicitationHandler(
        formMode: FormModeConfig? = .enabled(),
        urlMode: URLModeConfig? = nil,
        handler: @escaping @Sendable (Elicit.Parameters, RequestHandlerContext) async throws -> Elicit.Result
    ) {
        precondition(
            !handlersLocked,
            "Cannot register handlers after connect(). Register all handlers before calling connect()."
        )
        precondition(
            formMode != nil || urlMode != nil,
            "At least one elicitation mode (formMode or urlMode) must be enabled."
        )
        elicitationConfig = ElicitationConfig(formMode: formMode, urlMode: urlMode)
        withRequestHandler(Elicit.self, handler: handler)
    }

    /// Internal method to set the task-augmented sampling handler.
    ///
    /// This handler is called when the server sends a `sampling/createMessage` request
    /// with a `task` field. The handler should return `CreateTaskResult` instead of
    /// the normal sampling result.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _setTaskAugmentedSamplingHandler(
        _ handler: @escaping ExperimentalClientTaskHandlers.TaskAugmentedSamplingHandler
    ) {
        taskAugmentedSamplingHandler = handler
    }

    /// Internal method to set the task-augmented elicitation handler.
    ///
    /// This handler is called when the server sends an `elicitation/create` request
    /// with a `task` field. The handler should return `CreateTaskResult` instead of
    /// the normal elicitation result.
    ///
    /// - Important: This is an internal API that may change without notice.
    internal func _setTaskAugmentedElicitationHandler(
        _ handler: @escaping ExperimentalClientTaskHandlers.TaskAugmentedElicitationHandler
    ) {
        taskAugmentedElicitationHandler = handler
    }
}
