// Copyright © Anthony DePasquale

import Foundation

public extension Client {
    // MARK: - Prompts

    /// Get a prompt by name.
    ///
    /// - Parameters:
    ///   - name: The name of the prompt to retrieve.
    ///   - arguments: Optional arguments to pass to the prompt.
    /// - Returns: The prompt result containing description and messages.
    func getPrompt(name: String, arguments: [String: String]? = nil) async throws
        -> GetPrompt.Result
    {
        try validateServerCapability(\.prompts, "Prompts")
        let request = GetPrompt.request(.init(name: name, arguments: arguments))
        return try await send(request)
    }

    /// List available prompts from the server.
    ///
    /// - Parameter cursor: Optional cursor for pagination.
    /// - Returns: The list result containing prompts and optional next cursor.
    func listPrompts(cursor: String? = nil) async throws -> ListPrompts.Result {
        if !configuration.strict, let caps = serverCapabilities, caps.prompts == nil {
            logger?.debug("Server does not support prompts, returning empty list")
            return ListPrompts.Result(prompts: [])
        }
        try validateServerCapability(\.prompts, "Prompts")
        let request: Request<ListPrompts> = if let cursor {
            ListPrompts.request(.init(cursor: cursor))
        } else {
            ListPrompts.request(.init())
        }
        return try await send(request)
    }

    // MARK: - Resources

    /// Read a resource by URI.
    ///
    /// - Parameter uri: The URI of the resource to read.
    /// - Returns: The read result containing resource contents.
    func readResource(uri: String) async throws -> ReadResource.Result {
        try validateServerCapability(\.resources, "Resources")
        let request = ReadResource.request(.init(uri: uri))
        return try await send(request)
    }

    /// List available resources from the server.
    ///
    /// - Parameter cursor: Optional cursor for pagination.
    /// - Returns: The list result containing resources and optional next cursor.
    func listResources(cursor: String? = nil) async throws -> ListResources.Result {
        if !configuration.strict, let caps = serverCapabilities, caps.resources == nil {
            logger?.debug("Server does not support resources, returning empty list")
            return ListResources.Result(resources: [])
        }
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResources> = if let cursor {
            ListResources.request(.init(cursor: cursor))
        } else {
            ListResources.request(.init())
        }
        return try await send(request)
    }

    /// Subscribe to updates for a resource.
    ///
    /// - Parameter uri: The URI of the resource to subscribe to.
    func subscribeToResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceSubscribe.request(.init(uri: uri))
        _ = try await send(request)
    }

    /// Unsubscribe from updates for a resource.
    ///
    /// - Parameter uri: The URI of the resource to unsubscribe from.
    func unsubscribeFromResource(uri: String) async throws {
        try validateServerCapability(\.resources?.subscribe, "Resource subscription")
        let request = ResourceUnsubscribe.request(.init(uri: uri))
        _ = try await send(request)
    }

    /// List available resource templates from the server.
    ///
    /// - Parameter cursor: Optional cursor for pagination.
    /// - Returns: The list result containing templates and optional next cursor.
    func listResourceTemplates(cursor: String? = nil) async throws
        -> ListResourceTemplates.Result
    {
        if !configuration.strict, let caps = serverCapabilities, caps.resources == nil {
            logger?.debug("Server does not support resources, returning empty template list")
            return ListResourceTemplates.Result(templates: [])
        }
        try validateServerCapability(\.resources, "Resources")
        let request: Request<ListResourceTemplates> = if let cursor {
            ListResourceTemplates.request(.init(cursor: cursor))
        } else {
            ListResourceTemplates.request(.init())
        }
        return try await send(request)
    }

    // MARK: - Tools

    /// List available tools from the server.
    ///
    /// Output schemas from tools are cached for client-side validation when
    /// `callTool()` is called. To validate tool results, call this method
    /// at least once before calling tools.
    ///
    /// - Parameter cursor: Optional cursor for pagination.
    /// - Returns: The list result containing tools and optional next cursor.
    func listTools(cursor: String? = nil) async throws -> ListTools.Result {
        if !configuration.strict, let caps = serverCapabilities, caps.tools == nil {
            logger?.debug("Server does not support tools, returning empty list")
            return ListTools.Result(tools: [])
        }
        try validateServerCapability(\.tools, "Tools")
        let request: Request<ListTools> = if let cursor {
            ListTools.request(.init(cursor: cursor))
        } else {
            ListTools.request(.init())
        }
        let result = try await send(request)

        // Cache output schemas for client-side validation
        for tool in result.tools {
            if let outputSchema = tool.outputSchema {
                toolOutputSchemas[tool.name] = outputSchema
            }
        }

        return result
    }

    /// Call a tool by name.
    ///
    /// If the tool has an output schema, the result's `structuredContent` will be
    /// validated against it. Output schemas are cached from `listTools()` calls.
    /// If the tool is not in the cache, the cache is automatically refreshed.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Optional arguments to pass to the tool.
    /// - Returns: The tool call result containing content, structured content, and error flag.
    /// - Throws: `MCPError.invalidParams` if output validation fails.
    func callTool(name: String, arguments: [String: Value]? = nil) async throws
        -> CallTool.Result
    {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments))
        let result = try await send(request)

        try validateToolOutput(name: name, result: result)

        return result
    }

    /// Call a tool by name with progress notifications.
    ///
    /// This overload accepts a progress callback that is invoked when the server
    /// sends progress notifications during tool execution. The client automatically
    /// injects a progress token into the request metadata.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: Optional arguments to pass to the tool.
    ///   - onProgress: A callback invoked when progress notifications are received.
    /// - Returns: The tool call result containing content, structured content, and error flag.
    /// - Throws: `MCPError.invalidParams` if output validation fails.
    func callTool(
        name: String,
        arguments: [String: Value]? = nil,
        onProgress: @escaping ProgressCallback
    ) async throws -> CallTool.Result {
        try validateServerCapability(\.tools, "Tools")
        let request = CallTool.request(.init(name: name, arguments: arguments))
        let result = try await send(request, onProgress: onProgress)

        try validateToolOutput(name: name, result: result)

        return result
    }

    /// Validates tool output against cached schemas.
    private func validateToolOutput(name: String, result: CallTool.Result) throws {
        // We intentionally don't auto-refresh the cache if the tool is missing (unlike Python SDK).
        // Rationale: auto-refresh is a hidden side effect, and if the client cares about validation,
        // they should call listTools() first. This matches TypeScript SDK behavior.
        if let outputSchema = toolOutputSchemas[name] {
            if let structuredContent = result.structuredContent {
                try validator.validate(structuredContent, against: outputSchema)
            } else if !(result.isError ?? false) {
                // Tool has outputSchema but server returned no structuredContent
                throw MCPError.invalidParams(
                    "Tool '\(name)' has an output schema but server returned no structured content"
                )
            }
        }
    }

    // MARK: - Completions

    /// Request completion suggestions from the server.
    ///
    /// Completions provide autocomplete suggestions for prompt arguments or resource
    /// template URI parameters.
    ///
    /// - Parameters:
    ///   - ref: A reference to the prompt or resource template to get completions for.
    ///   - argument: The argument being completed, including its name and partial value.
    ///   - context: Optional additional context with previously-resolved argument values.
    /// - Returns: The completion result from the server.
    func complete(
        ref: CompletionReference,
        argument: CompletionArgument,
        context: CompletionContext? = nil
    ) async throws -> Complete.Result {
        try validateServerCapability(\.completions, "Completions")
        let request = Complete.request(.init(ref: ref, argument: argument, context: context))
        return try await send(request)
    }

    // MARK: - Logging

    /// Set the minimum log level for messages from the server.
    ///
    /// After calling this method, the server should only send log messages
    /// at the specified level or higher (more severe).
    ///
    /// - Parameter level: The minimum log level to receive.
    func setLoggingLevel(_ level: LoggingLevel) async throws {
        try validateServerCapability(\.logging, "Logging")
        let request = SetLoggingLevel.request(.init(level: level))
        _ = try await send(request)
    }
}
