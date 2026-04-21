// Copyright © Anthony DePasquale

import Foundation

public extension Server {
    // MARK: - Sending

    /// Send a response to a request
    func send(_ response: Response<some MCPCore.Method>) async throws {
        guard let connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let responseData = try encoder.encode(response)
        try await connection.send(responseData)
    }

    /// Send a notification to connected clients
    func notify(_ notification: Message<some MCPCore.Notification>) async throws {
        guard let connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Send a log message notification to connected clients.
    ///
    /// This method can be called outside of request handlers to send log messages
    /// asynchronously. The message will only be sent if:
    /// - The server has declared the `logging` capability
    /// - The message's level is at or above the minimum level set by the session
    ///
    /// If the logging capability is not declared, this method silently returns without
    /// sending (matching TypeScript SDK behavior).
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: An optional name for the logger producing the message
    ///   - data: The log message data (can be a string or structured data)
    ///   - sessionId: Optional session ID for per-session log level filtering.
    ///     If `nil`, the log level for the nil-session (default) is used.
    func sendLogMessage(
        level: LoggingLevel,
        logger: String? = nil,
        data: Value,
        sessionId: String? = nil,
    ) async throws {
        // Check if logging capability is declared (matching TypeScript SDK behavior)
        guard capabilities.logging != nil else { return }

        // Check if this message should be sent based on the session's log level
        guard shouldSendLogMessage(at: level, forSession: sessionId) else { return }

        try await notify(LogMessageNotification.message(.init(
            level: level,
            logger: logger,
            data: data,
        )))
    }

    // MARK: - List Changed Notifications

    /// Send a resource list changed notification to connected clients.
    ///
    /// Call this when the set of available resources has changed (resources added or removed).
    ///
    /// - Throws: `MCPError` if the server does not have the resources capability declared.
    func sendResourceListChanged() async throws {
        guard capabilities.resources != nil else {
            throw MCPError.internalError("Server does not support resources capability (required for notifications/resources/list_changed)")
        }
        try await notify(ResourceListChangedNotification.message())
    }

    /// Send a resource updated notification to connected clients.
    ///
    /// Call this when the contents of a specific resource have changed.
    ///
    /// - Parameter uri: The URI of the resource that was updated.
    /// - Throws: `MCPError` if the server does not have the resources capability declared.
    func sendResourceUpdated(uri: String) async throws {
        guard capabilities.resources != nil else {
            throw MCPError.internalError("Server does not support resources capability (required for notifications/resources/updated)")
        }
        try await notify(ResourceUpdatedNotification.message(.init(uri: uri)))
    }

    /// Send a tool list changed notification to connected clients.
    ///
    /// Call this when the set of available tools has changed (tools added or removed).
    ///
    /// - Throws: `MCPError` if the server does not have the tools capability declared.
    func sendToolListChanged() async throws {
        guard capabilities.tools != nil else {
            throw MCPError.internalError("Server does not support tools capability (required for notifications/tools/list_changed)")
        }
        try await notify(ToolListChangedNotification.message())
    }

    /// Send a prompt list changed notification to connected clients.
    ///
    /// Call this when the set of available prompts has changed (prompts added or removed).
    ///
    /// - Throws: `MCPError` if the server does not have the prompts capability declared.
    func sendPromptListChanged() async throws {
        guard capabilities.prompts != nil else {
            throw MCPError.internalError("Server does not support prompts capability (required for notifications/prompts/list_changed)")
        }
        try await notify(PromptListChangedNotification.message())
    }
}
