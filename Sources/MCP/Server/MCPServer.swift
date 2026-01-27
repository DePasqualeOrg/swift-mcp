// Copyright © Anthony DePasquale

/// High-level MCP server providing ergonomic APIs for tools, resources, and prompts.
///
/// `MCPServer` provides:
/// - Simplified registration APIs for tools, resources, and prompts
/// - Shared registries that can be used across multiple sessions
/// - Factory method for creating per-session Server instances (for HTTP)
/// - Automatic broadcasting of list-changed notifications to all connected sessions
/// - Simple one-liner for stdio transport
///
/// ## Stdio Transport (CLI tools)
///
/// For command-line tools invoked by clients like Claude Desktop:
///
/// ```swift
/// let server = MCPServer(name: "my-server", version: "1.0.0")
///
/// try await server.register {
///     GetWeather.self
///     CreateEvent.self
/// }
///
/// try await server.run(transport: .stdio)
/// ```
///
/// ## HTTP Transport (Web servers)
///
/// For HTTP servers with multiple concurrent clients, use `createSession()` to create
/// per-session Server instances that share the same tool/resource/prompt definitions:
///
/// ```swift
/// let mcpServer = MCPServer(name: "my-server", version: "1.0.0")
/// try await mcpServer.register { Echo.self }
///
/// // In your HTTP handler (Vapor, Hummingbird, etc.):
/// let session = await mcpServer.createSession()
/// let transport = HTTPServerTransport(...)
/// try await session.start(transport: transport)
/// ```
///
/// For simple demos and testing, `BasicHTTPSessionManager` handles sessions automatically:
///
/// ```swift
/// let sessionManager = BasicHTTPSessionManager(server: mcpServer, port: 8080)
/// // In Vapor/Hummingbird route:
/// let response = await sessionManager.handleRequest(httpRequest)
/// ```
///
/// See ``BasicHTTPSessionManager`` for limitations and when to implement custom session management.
public actor MCPServer {
    // MARK: - Server Configuration

    /// Server name for identification.
    public let name: String

    /// Server version.
    public let version: String

    /// Optional human-readable title.
    public let title: String?

    /// Optional description of what this server does.
    public let serverDescription: String?

    /// Optional icons representing this server.
    public let icons: [Icon]?

    /// Optional URL to the server's website.
    public let websiteUrl: String?

    /// Optional instructions for the LLM on how to use this server.
    public let instructions: String?

    /// Base capabilities (tools/resources/prompts capabilities are added dynamically).
    private let baseCapabilities: Server.Capabilities

    // MARK: - Registries (Shared Across Sessions)

    /// Tool registry for DSL-based and closure-based tools.
    public let toolRegistry: ToolRegistry

    /// Resource registry for resources and templates.
    public let resourceRegistry: ResourceRegistry

    /// Prompt registry for prompts.
    public let promptRegistry: PromptRegistry

    // MARK: - Internal State

    /// Whether any tools have been registered.
    private var hasTools = false

    /// Whether any resources have been registered.
    private var hasResources = false

    /// Whether any prompts have been registered.
    private var hasPrompts = false

    /// Active sessions for broadcasting notifications.
    ///
    /// MCPServer maintains its own session list so it can broadcast list-changed
    /// notifications (tools, resources, prompts) to all connected clients when
    /// registrations change. This is separate from HTTP-level session management
    /// (e.g., `BasicHTTPSessionManager`), which tracks sessions by ID for request
    /// routing. The two stay in sync via the `onDisconnect` callback set in
    /// `createSession()`, and failed sessions are also pruned during broadcast.
    ///
    /// Neither the Python nor TypeScript reference SDKs provide built-in broadcasting.
    /// In those SDKs, if tools are registered at runtime, application code must
    /// manually iterate sessions and send notifications. This array enables MCPServer
    /// to handle that automatically.
    private var sessions: [Server] = []

    /// JSON Schema validator for tool input/output validation.
    private let validator: JSONSchemaValidator = DefaultJSONSchemaValidator()

    /// Creates a new MCPServer.
    ///
    /// - Parameters:
    ///   - name: The server name.
    ///   - version: The server version.
    ///   - title: Optional human-readable title.
    ///   - description: Optional description of what this server does.
    ///   - icons: Optional icons representing this server.
    ///   - websiteUrl: Optional URL to the server's website.
    ///   - instructions: Optional instructions for the LLM on how to use this server.
    ///   - capabilities: Optional capability overrides. By default, tools/resources/prompts
    ///     capabilities are auto-detected based on registrations. Set explicit values here
    ///     to force capabilities regardless of registration state (useful for dynamic
    ///     registration based on client identity).
    public init(
        name: String,
        version: String,
        title: String? = nil,
        description: String? = nil,
        icons: [Icon]? = nil,
        websiteUrl: String? = nil,
        instructions: String? = nil,
        capabilities: Server.Capabilities? = nil
    ) {
        self.name = name
        self.version = version
        self.title = title
        serverDescription = description
        self.icons = icons
        self.websiteUrl = websiteUrl
        self.instructions = instructions
        baseCapabilities = capabilities ?? .init()
        toolRegistry = ToolRegistry()
        resourceRegistry = ResourceRegistry()
        promptRegistry = PromptRegistry()
    }

    // MARK: - Session Creation

    /// Creates a new Server instance wired to the shared registries.
    ///
    /// Use this method for HTTP integrations where each client session needs its own
    /// Server instance, but all sessions share the same tool/resource/prompt definitions.
    ///
    /// ## Capability Detection
    ///
    /// By default, capabilities are auto-detected based on what's registered:
    /// - If tools are registered, `tools` capability is advertised
    /// - If resources are registered, `resources` capability is advertised
    /// - If prompts are registered, `prompts` capability is advertised
    ///
    /// For dynamic registration scenarios (e.g., tools determined by client identity),
    /// you can force capabilities via the initializer:
    ///
    /// ```swift
    /// // Force tools capability even before any tools are registered
    /// let mcpServer = MCPServer(
    ///     name: "my-server",
    ///     version: "1.0.0",
    ///     capabilities: Server.Capabilities(tools: .init(listChanged: true))
    /// )
    ///
    /// // Later, after client connects and authenticates:
    /// try await mcpServer.register { toolsForUser(clientInfo) }
    /// ```
    ///
    /// - Returns: A configured Server instance ready to be started with a transport.
    public func createSession() async -> Server {
        // Build capabilities: use explicit overrides from baseCapabilities,
        // otherwise auto-detect based on registrations.
        var capabilities = baseCapabilities
        if capabilities.tools == nil, hasTools {
            capabilities.tools = .init(listChanged: true)
        }
        if capabilities.resources == nil, hasResources {
            capabilities.resources = .init(subscribe: false, listChanged: true)
        }
        if capabilities.prompts == nil, hasPrompts {
            capabilities.prompts = .init(listChanged: true)
        }

        let session = Server(
            name: name,
            version: version,
            title: title,
            description: serverDescription,
            icons: icons,
            websiteUrl: websiteUrl,
            instructions: instructions,
            capabilities: capabilities
        )

        // Wire up handlers to shared registries
        await setUpSessionHandlers(session)

        // Auto-remove session when its transport disconnects
        await session.setOnDisconnect { [weak self] in
            await self?.removeSession(session)
        }

        sessions.append(session)

        return session
    }

    /// Removes a session when its transport disconnects.
    public func removeSession(_ session: Server) {
        sessions.removeAll { $0 === session }
    }

    // MARK: - List Changed Notifications

    /// Callback for `RegisteredTool` to notify all sessions when the tool list changes.
    private var toolListChangedCallback: @Sendable () async -> Void {
        { [weak self] in
            await self?.notifyToolListChanged()
        }
    }

    /// Callback for `RegisteredResource` to notify all sessions when the resource list changes.
    private var resourceListChangedCallback: @Sendable () async -> Void {
        { [weak self] in
            await self?.notifyResourceListChanged()
        }
    }

    /// Callback for `RegisteredPrompt` to notify all sessions when the prompt list changes.
    private var promptListChangedCallback: @Sendable () async -> Void {
        { [weak self] in
            await self?.notifyPromptListChanged()
        }
    }

    private func notifyToolListChanged() async {
        await broadcastNotification(ToolListChangedNotification.message())
    }

    private func notifyResourceListChanged() async {
        await broadcastNotification(ResourceListChangedNotification.message())
    }

    private func notifyPromptListChanged() async {
        await broadcastNotification(PromptListChangedNotification.message())
    }

    /// Broadcasts a notification to all active sessions concurrently.
    /// Sessions that fail to receive the notification (e.g., disconnected) are automatically removed.
    private func broadcastNotification(_ notification: Message<some Notification>) async {
        let currentSessions = sessions

        let failedIDs = await withTaskGroup(
            of: ObjectIdentifier?.self,
            returning: Set<ObjectIdentifier>.self
        ) { group in
            for session in currentSessions {
                group.addTask {
                    do {
                        try await session.notify(notification)
                        return nil
                    } catch {
                        return ObjectIdentifier(session)
                    }
                }
            }
            var failed = Set<ObjectIdentifier>()
            for await id in group {
                if let id { failed.insert(id) }
            }
            return failed
        }

        if !failedIDs.isEmpty {
            sessions.removeAll { failedIDs.contains(ObjectIdentifier($0)) }
        }
    }

    /// Sets up request handlers on a session server, delegating to shared registries.
    /// Handlers are always wired to support dynamic registration after session creation.
    private func setUpSessionHandlers(_ session: Server) async {
        // Tools
        await session.withRequestHandler(ListTools.self) { [toolRegistry] _, _ in
            let tools = await toolRegistry.definitions
            return ListTools.Result(tools: tools)
        }

        await session.withRequestHandler(CallTool.self) { [toolRegistry, validator] request, handlerContext in
            let name = request.name

            // Helper to extract error message
            // Uses localizedDescription which works for LocalizedError types,
            // falls back to type description for other errors
            func errorMessage(_ error: Error) -> String {
                let description = error.localizedDescription
                // localizedDescription returns generic "operation couldn't be completed" for
                // non-LocalizedError types, so fall back to String(describing:) in that case.
                // Check for both straight quote (') and typographic apostrophe (U+2019)
                if description.contains("operation couldn't be completed")
                    || description.contains("operation couldn\u{2019}t be completed")
                {
                    return String(describing: error)
                }
                return description
            }

            // Helper to create tool error result
            func toolError(_ message: String) -> CallTool.Result {
                CallTool.Result(
                    content: [.text(message, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            // Get tool definition for validation
            // Unknown tool is a protocol error per MCP spec
            guard let toolDef = await toolRegistry.toolDefinition(for: name) else {
                throw MCPError.invalidParams("Unknown tool: \(name)")
            }

            // Validate input against schema
            // Schema validation errors are tool execution errors per MCP spec,
            // providing actionable feedback that LLMs can use to self-correct
            let inputValue: Value = request.arguments.map { .object($0) } ?? .object([:])
            do {
                try validator.validate(inputValue, against: toolDef.inputSchema)
            } catch {
                return toolError("Input validation error: \(errorMessage(error))")
            }

            // Execute tool and catch errors
            // Tool execution errors are returned with isError: true per MCP spec
            let context = HandlerContext(
                handlerContext: handlerContext,
                progressToken: request._meta?.progressToken
            )

            let result: CallTool.Result
            do {
                result = try await toolRegistry.execute(
                    name,
                    arguments: request.arguments,
                    context: context
                )
            } catch {
                return toolError(errorMessage(error))
            }

            // Validate output against schema if present
            // Output validation errors indicate server bugs, so remain as protocol errors
            if let outputSchema = toolDef.outputSchema {
                if let structuredContent = result.structuredContent {
                    try validator.validate(structuredContent, against: outputSchema)
                } else if !(result.isError ?? false) {
                    throw MCPError.invalidParams(
                        "Tool '\(name)' has an output schema but no structured content was provided"
                    )
                }
            }

            return result
        }

        // Resources
        await session.withRequestHandler(ListResources.self) { [resourceRegistry] _, _ in
            let resources = await resourceRegistry.listResources()
            let templateResources = try await resourceRegistry.listTemplateResources()
            return ListResources.Result(resources: resources + templateResources)
        }

        await session.withRequestHandler(ListResourceTemplates.self) { [resourceRegistry] _, _ in
            let templates = await resourceRegistry.listTemplates()
            return ListResourceTemplates.Result(templates: templates)
        }

        await session.withRequestHandler(ReadResource.self) { [resourceRegistry] request, _ in
            let contents = try await resourceRegistry.read(uri: request.uri)
            return ReadResource.Result(contents: [contents])
        }

        // Prompts
        await session.withRequestHandler(ListPrompts.self) { [promptRegistry] _, _ in
            let prompts = await promptRegistry.listPrompts()
            return ListPrompts.Result(prompts: prompts)
        }

        await session.withRequestHandler(GetPrompt.self) { [promptRegistry] request, handlerContext in
            let context = HandlerContext(
                handlerContext: handlerContext,
                progressToken: request._meta?.progressToken
            )
            return try await promptRegistry.getPrompt(
                request.name,
                arguments: request.arguments,
                context: context
            )
        }
    }

    // MARK: - Transport and Connection

    /// Runs the server with the specified transport.
    ///
    /// This is a convenience method for single-session transports like stdio.
    /// For HTTP with multiple clients, use `createSession()` instead.
    public func run(transport: TransportType) async throws {
        let session = await createSession()

        switch transport {
            case .stdio:
                let stdioTransport = StdioTransport()
                try await session.start(transport: stdioTransport)

            case let .custom(customTransport):
                try await session.start(transport: customTransport)
        }
    }
}

// MARK: - Tool Registration

/// Tool registration and error handling.
///
/// ## Error Handling
///
/// When a tool throws an error during execution, the MCP server handles it according to
/// the MCP specification (see "Error Handling" section of the Tools spec):
///
/// - **Tool execution errors** are returned to the LLM with `isError: true`, providing
///   actionable feedback that enables self-correction and retry with adjusted parameters.
///   This includes input validation errors (e.g., wrong type, missing required field).
///
/// - **Protocol errors** (unknown tool, malformed request) are returned as JSON-RPC errors.
///
/// Note: Both the TypeScript and Python SDKs incorrectly return `isError: true` for
/// unknown tools instead of a JSON-RPC protocol error. This Swift SDK correctly
/// returns a protocol error per the MCP spec.
/// TODO: Remove this note after these PRs are merged:
/// - https://github.com/modelcontextprotocol/typescript-sdk/pull/1389
/// - https://github.com/modelcontextprotocol/python-sdk/pull/1872
///
/// ## Providing Actionable Error Messages
///
/// For the best LLM experience, make your error types conform to `LocalizedError` and
/// provide clear, actionable `errorDescription` values:
///
/// ```swift
/// enum MyToolError: LocalizedError {
///     case invalidDate(String)
///     case resourceNotFound(String)
///
///     var errorDescription: String? {
///         switch self {
///             case .invalidDate(let date):
///                 return "Invalid date '\(date)': must be in ISO 8601 format (e.g., 2024-01-15)"
///             case .resourceNotFound(let id):
///                 return "Resource '\(id)' not found. Use list_resources to see available resources."
///         }
///     }
/// }
/// ```
///
/// Errors conforming to `LocalizedError` will have their `errorDescription` surfaced directly
/// to the LLM. For other error types, the server uses `String(describing:)` as a fallback.
public extension MCPServer {
    // MARK: DSL-Based Tools

    /// Registers multiple tools using a result builder.
    ///
    /// Example:
    /// ```swift
    /// try await server.register {
    ///     GetWeather.self
    ///     CreateEvent.self
    ///     if includeAdmin {
    ///         AdminTool.self
    ///     }
    /// }
    /// ```
    ///
    /// - Returns: An array of `RegisteredTool` for managing the tools.
    /// - Throws: `MCPError.invalidParams` if any tool name is already registered.
    @discardableResult
    func register(@ToolBuilder tools: () -> [any ToolSpec.Type]) async throws -> [RegisteredTool] {
        let onListChanged = toolListChangedCallback
        var registeredTools: [RegisteredTool] = []
        for tool in tools() {
            let registered = try await toolRegistry.register(tool, onListChanged: onListChanged)
            registeredTools.append(registered)
        }
        hasTools = true
        await notifyToolListChanged()
        return registeredTools
    }

    /// Registers a single DSL-based tool.
    ///
    /// Example:
    /// ```swift
    /// let tool = try await server.register(GetWeather.self)
    /// await tool.disable()  // Temporarily disable
    /// await tool.enable()   // Re-enable
    /// await tool.remove()   // Permanently remove
    /// ```
    ///
    /// - Returns: A `RegisteredTool` for managing the tool.
    /// - Throws: `MCPError.invalidParams` if a tool with the same name is already registered.
    @discardableResult
    func register(_ tool: (some ToolSpec).Type) async throws -> RegisteredTool {
        let onListChanged = toolListChangedCallback
        let registered = try await toolRegistry.register(tool, onListChanged: onListChanged)
        hasTools = true
        await notifyToolListChanged()
        return registered
    }

    // MARK: Closure-Based Tools (Dynamic Registration)

    /// Registers a dynamically defined tool with a closure handler.
    ///
    /// **When to use this method:**
    /// Use this for tools discovered or generated at runtime, such as:
    /// - Tools loaded from configuration files
    /// - Tools generated from database schemas
    /// - Plugin-provided tools
    /// - Tools from external API definitions
    ///
    /// **For compile-time known tools:**
    /// If your tool is known at compile time, use the `@Tool` macro instead.
    /// The macro provides compile-time schema generation and type safety:
    /// ```swift
    /// @Tool
    /// struct Echo {
    ///     static let name = "echo"
    ///     @Parameter(description: "Message to echo")
    ///     var message: String
    ///     func perform() async throws -> String { message }
    /// }
    /// try await server.register(Echo.self)
    /// ```
    ///
    /// The `inputSchema` parameter is required because dynamic tools should
    /// provide their schema from the authoritative source (config, database, etc.).
    ///
    /// If `Output` conforms to `StructuredOutput` (via `@OutputSchema`),
    /// the tool's `outputSchema` is automatically populated.
    ///
    /// Example:
    /// ```swift
    /// // Tool definition from external config
    /// let toolConfig = loadToolConfig()
    ///
    /// try await server.register(
    ///     name: toolConfig.name,
    ///     description: toolConfig.description,
    ///     inputSchema: toolConfig.schema
    /// ) { (args: [String: Value], context: HandlerContext) in
    ///     // Dynamic execution
    ///     "Executed \(toolConfig.name)"
    /// }
    /// ```
    ///
    /// - Throws: `MCPError.invalidParams` if a tool with the same name is already registered.
    @discardableResult
    func register<Input: Codable & Sendable, Output: ToolOutput>(
        name: String,
        description: String? = nil,
        inputSchema: Value,
        inputType: Input.Type = Input.self,
        annotations: [AnnotationOption] = [],
        handler: @escaping @Sendable (Input, HandlerContext) async throws -> Output
    ) async throws -> RegisteredTool {
        let onListChanged = toolListChangedCallback
        let registered = try await toolRegistry.registerClosure(
            name: name,
            description: description,
            inputSchema: inputSchema,
            inputType: inputType,
            outputSchema: outputSchema(for: Output.self),
            annotations: annotations,
            onListChanged: onListChanged,
            handler: handler
        )
        hasTools = true
        await notifyToolListChanged()
        return registered
    }

    /// Registers a dynamically defined tool with no input parameters.
    ///
    /// Use this for dynamic tools that take no arguments. For compile-time known tools,
    /// prefer the `@Tool` macro instead.
    ///
    /// - Throws: `MCPError.invalidParams` if a tool with the same name is already registered.
    @discardableResult
    func register(
        name: String,
        description: String? = nil,
        annotations: [AnnotationOption] = [],
        handler: @escaping @Sendable (HandlerContext) async throws -> some ToolOutput
    ) async throws -> RegisteredTool {
        let onListChanged = toolListChangedCallback
        let registered = try await toolRegistry.registerClosure(
            name: name,
            description: description,
            annotations: annotations,
            onListChanged: onListChanged,
            handler: handler
        )
        hasTools = true
        await notifyToolListChanged()
        return registered
    }
}

// MARK: - Resource Registration

public extension MCPServer {
    /// Registers a static resource with a closure handler.
    ///
    /// Example:
    /// ```swift
    /// try await server.registerResource(
    ///     uri: "config://app",
    ///     name: "app_config",
    ///     description: "Application configuration"
    /// ) {
    ///     .text("{\"debug\": true}", uri: "config://app")
    /// }
    /// ```
    ///
    /// - Throws: `MCPError.invalidParams` if a resource with the same URI is already registered.
    @discardableResult
    func registerResource(
        uri: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        read: @escaping @Sendable () async throws -> Resource.Contents
    ) async throws -> RegisteredResource {
        let registered = try await resourceRegistry.register(
            uri: uri,
            name: name,
            description: description,
            mimeType: mimeType,
            onListChanged: resourceListChangedCallback,
            read: read
        )
        hasResources = true
        await notifyResourceListChanged()
        return registered
    }

    /// Registers a resource template with a closure handler.
    ///
    /// Example:
    /// ```swift
    /// try await server.registerResourceTemplate(
    ///     uriTemplate: "file:///{path}",
    ///     name: "file",
    ///     description: "Read a file by path"
    /// ) { uri, variables in
    ///     let path = variables["path"]!
    ///     let content = try String(contentsOfFile: "/" + path)
    ///     return .text(content, uri: uri)
    /// }
    /// ```
    ///
    /// - Throws: `MCPError.invalidParams` if a template with the same URI pattern is already registered.
    @discardableResult
    func registerResourceTemplate(
        uriTemplate: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        list: (@Sendable () async throws -> [Resource])? = nil,
        read: @escaping @Sendable (String, [String: String]) async throws -> Resource.Contents
    ) async throws -> RegisteredResourceTemplate {
        let registered = try await resourceRegistry.registerTemplate(
            uriTemplate: uriTemplate,
            name: name,
            description: description,
            mimeType: mimeType,
            list: list,
            onListChanged: resourceListChangedCallback,
            read: read
        )
        hasResources = true
        await notifyResourceListChanged()
        return registered
    }
}

// MARK: - Prompt Registration

public extension MCPServer {
    // MARK: DSL-Based Prompts

    /// Registers multiple prompts using a result builder.
    ///
    /// Example:
    /// ```swift
    /// try await server.register {
    ///     InterviewPrompt.self
    ///     CodeReviewPrompt.self
    ///     if includeAdvanced {
    ///         AdvancedPrompt.self
    ///     }
    /// }
    /// ```
    ///
    /// - Returns: An array of `RegisteredPrompt` for managing the prompts.
    /// - Throws: `MCPError.invalidParams` if any prompt name is already registered.
    @discardableResult
    func register(@PromptBuilder prompts: () -> [any PromptSpec.Type]) async throws -> [RegisteredPrompt] {
        let onListChanged = promptListChangedCallback
        var registeredPrompts: [RegisteredPrompt] = []
        for prompt in prompts() {
            let registered = try await promptRegistry.register(prompt, onListChanged: onListChanged)
            registeredPrompts.append(registered)
        }
        hasPrompts = true
        await notifyPromptListChanged()
        return registeredPrompts
    }

    /// Registers a single DSL-based prompt.
    ///
    /// Example:
    /// ```swift
    /// let prompt = try await server.register(InterviewPrompt.self)
    /// await prompt.disable()  // Temporarily disable
    /// await prompt.enable()   // Re-enable
    /// await prompt.remove()   // Permanently remove
    /// ```
    ///
    /// - Returns: A `RegisteredPrompt` for managing the prompt.
    /// - Throws: `MCPError.invalidParams` if a prompt with the same name is already registered.
    @discardableResult
    func register(_ prompt: (some PromptSpec).Type) async throws -> RegisteredPrompt {
        let registered = try await promptRegistry.register(prompt, onListChanged: promptListChangedCallback)
        hasPrompts = true
        await notifyPromptListChanged()
        return registered
    }

    // MARK: Closure-Based Prompts (Dynamic Registration)

    /// Registers a dynamically defined prompt with a closure handler.
    ///
    /// **When to use this method:**
    /// Use this for prompts discovered or generated at runtime, such as:
    /// - Prompts loaded from configuration files
    /// - Prompts generated from templates
    /// - Plugin-provided prompts
    ///
    /// **For compile-time known prompts:**
    /// If your prompt is known at compile time, use the `@Prompt` macro instead.
    /// The macro provides compile-time type safety:
    /// ```swift
    /// @Prompt
    /// struct InterviewPrompt {
    ///     static let name = "interview"
    ///     static let description = "Interview preparation"
    ///
    ///     @Argument(description: "Role to interview for")
    ///     var role: String
    ///
    ///     func render(context: HandlerContext) async throws -> [Prompt.Message] {
    ///         [.user(.text("Prepare questions for \(role) interview"))]
    ///     }
    /// }
    /// try await server.register(InterviewPrompt.self)
    /// ```
    ///
    /// Example:
    /// ```swift
    /// // Prompt definition from external config
    /// let promptConfig = loadPromptConfig()
    ///
    /// try await server.registerPrompt(
    ///     name: promptConfig.name,
    ///     description: promptConfig.description,
    ///     arguments: promptConfig.arguments
    /// ) { args, context in
    ///     let topic = args?["topic"] ?? "general"
    ///     return [.user(.text("Discuss: \(topic)"))]
    /// }
    /// ```
    ///
    /// - Throws: `MCPError.invalidParams` if a prompt with the same name is already registered.
    @discardableResult
    func registerPrompt(
        name: String,
        title: String? = nil,
        description: String? = nil,
        arguments: [Prompt.Argument]? = nil,
        handler: @escaping @Sendable ([String: String]?, HandlerContext) async throws -> [Prompt.Message]
    ) async throws -> RegisteredPrompt {
        let registered = try await promptRegistry.register(
            name: name,
            title: title,
            description: description,
            arguments: arguments,
            onListChanged: promptListChangedCallback,
            handler: handler
        )
        hasPrompts = true
        await notifyPromptListChanged()
        return registered
    }

    /// Registers a simple prompt with no arguments.
    ///
    /// Use this for simple prompts that don't need arguments or context access.
    /// For more complex prompts, use `registerPrompt(name:arguments:handler:)` or
    /// the `@Prompt` macro for DSL-based prompts.
    ///
    /// Example:
    /// ```swift
    /// try await server.registerPrompt(
    ///     name: "greeting",
    ///     description: "A friendly greeting"
    /// ) {
    ///     [.user(.text("Hello! How can I help you?"))]
    /// }
    /// ```
    ///
    /// - Throws: `MCPError.invalidParams` if a prompt with the same name is already registered.
    @discardableResult
    func registerPrompt(
        name: String,
        title: String? = nil,
        description: String? = nil,
        handler: @escaping @Sendable () async throws -> [Prompt.Message]
    ) async throws -> RegisteredPrompt {
        try await registerPrompt(
            name: name,
            title: title,
            description: description,
            arguments: nil
        ) { _, _ in
            try await handler()
        }
    }
}
