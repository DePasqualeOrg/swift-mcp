import Foundation

/// Context provided to all high-level API handlers.
///
/// Provides access to:
/// - Progress reporting during long-running operations
/// - Logging at various levels (info, debug, warning, error)
/// - Request cancellation checking
/// - Request metadata (request ID, session ID)
/// - User elicitation (requesting additional input during execution)
///
/// Example:
/// ```swift
/// func perform(context: HandlerContext) async throws -> String {
///     for (index, item) in items.enumerated() {
///         try context.checkCancellation()
///         try await context.reportProgress(Double(index), total: Double(items.count))
///         try await context.info("Processing item \(index)")
///         // ... process item
///     }
///     return "Processed \(items.count) items"
/// }
/// ```
public struct HandlerContext: Sendable {
    private let requestContext: Server.RequestHandlerContext
    private let progressToken: ProgressToken?

    /// Creates a new handler context.
    /// - Parameters:
    ///   - handlerContext: The underlying request handler context.
    ///   - progressToken: Optional progress token from the request metadata.
    public init(handlerContext: Server.RequestHandlerContext, progressToken: ProgressToken? = nil) {
        self.requestContext = handlerContext
        self.progressToken = progressToken
    }

    // MARK: - Cancellation

    /// Check if the current request has been cancelled.
    /// Equivalent to `Task.isCancelled`.
    public var isCancelled: Bool {
        Task.isCancelled
    }

    /// Throws `CancellationError` if the request has been cancelled.
    /// Use this at cancellation points in long-running operations.
    public func checkCancellation() throws {
        try Task.checkCancellation()
    }

    // MARK: - Progress

    /// Report progress for the current operation.
    /// Silently returns without error if the request didn't include a progress token.
    /// - Parameters:
    ///   - progress: The current progress value.
    ///   - total: The total value (optional).
    ///   - message: A human-readable progress message (optional).
    public func reportProgress(
        _ progress: Double,
        total: Double? = nil,
        message: String? = nil
    ) async throws {
        guard let token = progressToken else { return }
        try await requestContext.sendProgress(token: token, progress: progress, total: total, message: message)
    }

    // MARK: - Logging

    /// Sends a log message at the specified level.
    /// - Parameters:
    ///   - level: The logging level.
    ///   - message: The message to log.
    ///   - logger: Optional logger name.
    public func log(
        level: LoggingLevel,
        _ message: String,
        logger: String? = nil
    ) async throws {
        try await requestContext.sendLogMessage(
            level: level,
            logger: logger,
            data: .string(message)
        )
    }

    /// Log at info level.
    /// - Parameters:
    ///   - message: The message to log.
    ///   - logger: Optional logger name.
    public func info(_ message: String, logger: String? = nil) async throws {
        try await log(level: .info, message, logger: logger)
    }

    /// Log at debug level.
    /// - Parameters:
    ///   - message: The message to log.
    ///   - logger: Optional logger name.
    public func debug(_ message: String, logger: String? = nil) async throws {
        try await log(level: .debug, message, logger: logger)
    }

    /// Log at warning level.
    /// - Parameters:
    ///   - message: The message to log.
    ///   - logger: Optional logger name.
    public func warning(_ message: String, logger: String? = nil) async throws {
        try await log(level: .warning, message, logger: logger)
    }

    /// Log at error level.
    /// - Parameters:
    ///   - message: The message to log.
    ///   - logger: Optional logger name.
    public func error(_ message: String, logger: String? = nil) async throws {
        try await log(level: .error, message, logger: logger)
    }

    // MARK: - Request Info

    /// The request ID for this handler invocation.
    public var requestId: RequestId {
        requestContext.requestId
    }

    /// The session ID, if available.
    public var sessionId: String? {
        requestContext.sessionId
    }

    // MARK: - Elicitation

    /// Request user input via form-based elicitation.
    ///
    /// Elicitation allows tools to request additional information from users
    /// during execution. The client presents a form based on the provided schema.
    ///
    /// Example:
    /// ```swift
    /// func perform(context: HandlerContext) async throws -> String {
    ///     let schema = ElicitationSchema(
    ///         properties: [
    ///             "confirm": .boolean(description: "Confirm deletion?")
    ///         ],
    ///         required: ["confirm"]
    ///     )
    ///     let result = try await context.elicit(
    ///         message: "Please confirm this action",
    ///         requestedSchema: schema
    ///     )
    ///     guard result.action == .accept else {
    ///         throw MCPError.invalidRequest("User cancelled")
    ///     }
    ///     // Process result.content...
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - message: The message to present to the user.
    ///   - requestedSchema: The schema defining the form fields.
    /// - Returns: The elicitation result from the client.
    /// - Throws: `MCPError` if the request fails.
    public func elicit(
        message: String,
        requestedSchema: ElicitationSchema
    ) async throws -> ElicitResult {
        try await requestContext.elicit(message: message, requestedSchema: requestedSchema)
    }

    /// Request user interaction via URL-based elicitation.
    ///
    /// This enables out-of-band interactions through external URLs,
    /// such as OAuth flows or credential collection.
    ///
    /// Example:
    /// ```swift
    /// func perform(context: HandlerContext) async throws -> String {
    ///     let result = try await context.elicitUrl(
    ///         message: "Please authenticate with the service",
    ///         url: "https://auth.example.com/oauth?state=xyz",
    ///         elicitationId: UUID().uuidString
    ///     )
    ///     guard result.action == .accept else {
    ///         throw MCPError.invalidRequest("Authentication cancelled")
    ///     }
    ///     // User completed the URL flow
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - message: Human-readable explanation of why the interaction is needed.
    ///   - url: The URL the user should navigate to.
    ///   - elicitationId: Unique identifier for tracking this elicitation.
    /// - Returns: The elicitation result from the client.
    /// - Throws: `MCPError` if the request fails.
    public func elicitUrl(
        message: String,
        url: String,
        elicitationId: String
    ) async throws -> ElicitResult {
        try await requestContext.elicitUrl(message: message, url: url, elicitationId: elicitationId)
    }

    // MARK: - Sampling

    /// Request a sampling completion from the client.
    ///
    /// This enables tools to request LLM completions during execution.
    /// The client will generate a completion using its LLM and return the result.
    ///
    /// Example:
    /// ```swift
    /// func perform(context: HandlerContext) async throws -> String {
    ///     let result = try await context.createMessage(
    ///         messages: [.init(role: .user, content: .text("What is 2+2?"))],
    ///         maxTokens: 100
    ///     )
    ///     return "LLM said: \(result.content)"
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - messages: The conversation history to use for completion.
    ///   - maxTokens: The maximum number of tokens to generate.
    ///   - modelPreferences: Optional model preferences.
    ///   - systemPrompt: Optional system prompt.
    ///   - includeContext: How to include context from the server.
    ///   - temperature: Optional temperature for generation.
    ///   - stopSequences: Optional stop sequences.
    ///   - metadata: Optional metadata for the request.
    /// - Returns: The sampling result from the client.
    /// - Throws: `MCPError` if the request fails.
    public func createMessage(
        messages: [Sampling.Message],
        maxTokens: Int,
        modelPreferences: ModelPreferences? = nil,
        systemPrompt: String? = nil,
        includeContext: Sampling.ContextInclusion? = nil,
        temperature: Double? = nil,
        stopSequences: [String]? = nil,
        metadata: [String: Value]? = nil
    ) async throws -> CreateSamplingMessage.Result {
        let params = SamplingParameters(
            messages: messages,
            modelPreferences: modelPreferences,
            systemPrompt: systemPrompt,
            includeContext: includeContext,
            temperature: temperature,
            maxTokens: maxTokens,
            stopSequences: stopSequences,
            metadata: metadata
        )
        let request = CreateSamplingMessage.request(id: .random, params)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let requestData = try encoder.encode(request)

        let responseData = try await requestContext.sendRequest(requestData)
        return try JSONDecoder().decode(CreateSamplingMessage.Result.self, from: responseData)
    }
}

