// Copyright © Anthony DePasquale

import Foundation

/// A registry for managing tools - both `@Tool`-decorated types and closure-based tools.
///
/// `ToolRegistry` stores registered tools and provides:
/// - Tool definitions for `ListTools` responses
/// - Tool execution with automatic parsing
/// - Enable/disable and remove functionality for all tools
///
/// Example:
/// ```swift
/// // Create registry with result builder (DSL tools)
/// let registry = ToolRegistry {
///     GetWeather.self
///     CreateEvent.self
/// }
///
/// // Or register dynamically
/// let registry = ToolRegistry()
/// let tool = try registry.register(GetWeather.self)
/// await tool.disable()  // DSL tools can be disabled
///
/// // Register closure-based tools (dynamic registration)
/// let tool = try registry.registerClosure(
///     name: "echo",
///     description: "Echo the input",
///     inputSchema: toolConfig.schema  // Schema from external source
/// ) { (args: EchoArgs, context) in
///     args.message
/// }
/// ```
///
/// The registry handles parsing arguments into typed instances and
/// executing the tool. Input validation is performed by the Server
/// before calling the registry.
public actor ToolRegistry {
    /// All registered tools (both DSL and closure-based).
    private var tools: [String: ToolEntry] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Creates a registry with the specified tools.
    ///
    /// Example:
    /// ```swift
    /// let registry = ToolRegistry {
    ///     GetWeather.self
    ///     CreateEvent.self
    /// }
    /// ```
    public init(@ToolBuilder tools: () -> [any ToolSpec.Type]) {
        let toolList = tools()
        self.tools = Dictionary(uniqueKeysWithValues: toolList.map {
            ($0.toolDefinition.name, ToolEntry(kind: .dsl($0)))
        })
    }

    // MARK: - DSL Tool Registration

    /// Registers a DSL-based tool type.
    ///
    /// - Parameters:
    ///   - tool: The tool type to register.
    ///   - onListChanged: Optional callback for list change notifications.
    /// - Returns: A `RegisteredTool` for managing the tool.
    /// - Throws: `MCPError.invalidParams` if a tool with the same name already exists.
    @discardableResult
    public func register<T: ToolSpec>(
        _ tool: T.Type,
        onListChanged: (@Sendable () async -> Void)? = nil,
    ) throws -> RegisteredTool {
        let name = T.toolDefinition.name
        guard !hasTool(name) else {
            throw MCPError.invalidParams("Tool '\(name)' is already registered")
        }
        tools[name] = ToolEntry(kind: .dsl(tool))
        return RegisteredTool(name: name, registry: self, onListChanged: onListChanged)
    }

    // MARK: - Closure Tool Registration

    /// Registers a closure-based tool with typed input.
    ///
    /// Use this method for dynamic tool registration where the tool definition
    /// comes from an external source (config file, database, API, etc.).
    /// The `inputSchema` parameter is required because dynamic tools should
    /// provide their schema from the source of truth.
    ///
    /// - Parameters:
    ///   - name: The tool name.
    ///   - description: Optional description.
    ///   - inputSchema: The JSON Schema for the tool's input parameters.
    ///   - inputType: The Swift type to decode input into.
    ///   - outputSchema: Optional output schema for structured output.
    ///   - annotations: Tool annotations.
    ///   - onListChanged: Optional callback for list change notifications.
    ///   - handler: The handler closure.
    /// - Returns: A `RegisteredTool` for managing the tool.
    /// - Throws: `MCPError.invalidParams` if a tool with the same name already exists.
    @discardableResult
    public func registerClosure<Input: Codable & Sendable>(
        name: String,
        description: String? = nil,
        inputSchema: Value,
        inputType _: Input.Type = Input.self,
        outputSchema: Value? = nil,
        annotations: [AnnotationOption] = [],
        onListChanged: (@Sendable () async -> Void)? = nil,
        handler: @escaping @Sendable (Input, HandlerContext) async throws -> some ToolOutput,
    ) throws -> RegisteredTool {
        guard !hasTool(name) else {
            throw MCPError.invalidParams("Tool '\(name)' is already registered")
        }

        let definition = Tool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            annotations: AnnotationOption.buildAnnotations(from: annotations),
        )

        let closureHandler: @Sendable ([String: Value]?, HandlerContext) async throws -> CallTool.Result = { arguments, context in
            let input = try Self.decodeInput(arguments, as: Input.self)
            let output = try await handler(input, context)
            return try output.toCallToolResult()
        }

        tools[name] = ToolEntry(kind: .closure(definition: definition, handler: closureHandler))
        return RegisteredTool(name: name, registry: self, onListChanged: onListChanged)
    }

    /// Registers a closure-based tool with no input parameters.
    ///
    /// - Parameters:
    ///   - name: The tool name.
    ///   - description: Optional description.
    ///   - outputSchema: Optional output schema for structured output. Typically
    ///     passed in by `MCPServer.register(...)` from `MCPSchema.outputSchema(for: Output.self)`.
    ///   - annotations: Tool annotations.
    ///   - onListChanged: Optional callback for list change notifications.
    ///   - handler: The handler closure.
    /// - Returns: A `RegisteredTool` for managing the tool.
    /// - Throws: `MCPError.invalidParams` if a tool with the same name already exists.
    @discardableResult
    public func registerClosure(
        name: String,
        description: String? = nil,
        outputSchema: Value? = nil,
        annotations: [AnnotationOption] = [],
        onListChanged: (@Sendable () async -> Void)? = nil,
        handler: @escaping @Sendable (HandlerContext) async throws -> some ToolOutput,
    ) throws -> RegisteredTool {
        guard !hasTool(name) else {
            throw MCPError.invalidParams("Tool '\(name)' is already registered")
        }

        let definition = Tool(
            name: name,
            description: description,
            inputSchema: .object(["type": .string("object")]),
            outputSchema: outputSchema,
            annotations: AnnotationOption.buildAnnotations(from: annotations),
        )

        let closureHandler: @Sendable ([String: Value]?, HandlerContext) async throws -> CallTool.Result = { _, context in
            let output = try await handler(context)
            return try output.toCallToolResult()
        }

        tools[name] = ToolEntry(kind: .closure(definition: definition, handler: closureHandler))
        return RegisteredTool(name: name, registry: self, onListChanged: onListChanged)
    }

    // MARK: - Tool Lookup

    /// All tool definitions for `ListTools` response.
    ///
    /// Returns definitions for all enabled tools (both DSL and closure-based).
    public var definitions: [Tool] {
        tools.values
            .filter { $0.enabled }
            .map { $0.definition }
    }

    /// Checks if the registry handles a tool with the given name.
    ///
    /// - Parameter name: The tool name to check.
    /// - Returns: `true` if the registry contains the tool.
    public func hasTool(_ name: String) -> Bool {
        tools[name] != nil
    }

    // MARK: - Schema Verification

    /// Audits a set of expected tool names against the registry, reporting
    /// tools that lack an output schema and tools that aren't registered at
    /// all — two separate failure modes that would otherwise be conflated
    /// in a single list.
    ///
    /// The library does not enforce output-schema presence at registration
    /// time — that would break consumers whose tools aren't all migrated
    /// yet. This helper is opt-in: pass the names you expect to be covered
    /// and inspect the result. Typical usage guards the call with
    /// `#if DEBUG` and `fatalError`s on `hasIssues`, so the check runs
    /// during local builds but isn't responsible for crashing release
    /// binaries on a tool-migration mistake.
    ///
    /// The check uses the registry's stored `Tool.outputSchema`, populated
    /// at DSL-tool registration time via `MCPSchema.outputSchema(for: Output.self)`:
    /// 1. `StructuredOutput` types via `outputJSONSchema`.
    /// 2. `MediaWithMetadata<Metadata>` / `AssetWithMetadata<Metadata>`
    ///    instantiations via `StructuredMetadataCarrier`.
    ///
    /// A migrated media tool returning `MediaWithMetadata<ScreenshotMetadata>`
    /// therefore passes the check even though `MediaWithMetadata` itself
    /// does not conform to `StructuredOutput`.
    ///
    /// - Parameter expected: Tool names the caller expects to be migrated.
    ///   A tool not in `expected` is never reported here — the helper is
    ///   opt-in.
    /// - Returns: A `SchemaAudit` splitting the findings into
    ///   `missingSchema` (registered, but `outputSchema == nil`) and
    ///   `missingRegistration` (not in the registry at all).
    public func schemaAudit(expected: Set<String>) -> SchemaAudit {
        var missingSchema: [String] = []
        var missingRegistration: [String] = []
        for name in expected {
            guard let entry = tools[name] else {
                missingRegistration.append(name)
                continue
            }
            if entry.definition.outputSchema == nil {
                missingSchema.append(name)
            }
        }
        return SchemaAudit(
            missingSchema: missingSchema.sorted(),
            missingRegistration: missingRegistration.sorted(),
        )
    }

    /// Executes a tool.
    ///
    /// This method assumes input validation has already been performed
    /// by the Server. It parses the arguments into a typed instance
    /// and executes the tool.
    ///
    /// Tool lookup and validation happen on the actor. The actual execution
    /// runs off the actor's serial executor so that multiple tool calls
    /// can proceed concurrently.
    ///
    /// - Parameters:
    ///   - name: The tool name to execute.
    ///   - arguments: The tool arguments.
    ///   - context: The handler context for progress reporting and logging.
    /// - Returns: The tool execution result.
    /// - Throws: `MCPError.invalidParams` if the tool doesn't exist or is disabled,
    ///           or any error from parsing or execution.
    public func execute(
        _ name: String,
        arguments: [String: Value]?,
        context: HandlerContext,
    ) async throws -> CallTool.Result {
        let entry = try resolveEntry(name)

        // Run tool execution in a detached task so it runs on the global concurrent
        // executor instead of the actor's serial executor. This allows multiple
        // tool calls to proceed in parallel.
        return try await Task.detached {
            switch entry.kind {
                case let .dsl(toolType):
                    let instance = try toolType.parse(from: arguments)
                    let output = try await instance._perform(context: context)
                    return try output.toCallToolResult()

                case let .closure(_, handler):
                    return try await handler(arguments, context)
            }
        }.value
    }

    /// Looks up and validates a tool entry. Actor-isolated for safe dictionary access.
    private func resolveEntry(_ name: String) throws -> ToolEntry {
        guard let entry = tools[name] else {
            throw MCPError.invalidParams("Unknown tool: \(name)")
        }
        guard entry.enabled else {
            throw MCPError.invalidParams("Tool '\(name)' is disabled")
        }
        return entry
    }

    // MARK: - Tool Management (Internal)

    func isToolEnabled(_ name: String) -> Bool {
        tools[name]?.enabled ?? false
    }

    func toolDefinition(for name: String) -> Tool? {
        tools[name]?.definition
    }

    func enableTool(_ name: String) {
        tools[name]?.enabled = true
    }

    func disableTool(_ name: String) {
        tools[name]?.enabled = false
    }

    func removeTool(_ name: String) {
        tools.removeValue(forKey: name)
    }

    // MARK: - Private Helpers

    private static func decodeInput<T: Decodable>(_ arguments: [String: Value]?, as _: T.Type) throws -> T {
        guard let arguments else {
            // Try to decode from empty object
            return try JSONDecoder().decode(T.self, from: Data("{}".utf8))
        }

        // Convert Value dictionary to JSON data
        let value = Value.object(arguments)
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Schema Audit

/// Result of `ToolRegistry.schemaAudit(expected:)`. Splits the two failure
/// modes — registered-but-missing-a-schema vs. not-registered-at-all — that
/// a single `[String]` result would conflate.
///
/// Consumers typically call the audit behind `#if DEBUG` and fatal-error
/// on `hasIssues`, using `diagnosticMessage` for a ready-made multi-line
/// description of both lists.
public struct SchemaAudit: Sendable, Equatable {
    /// Names from the expected set that are registered but whose
    /// `outputSchema` is `nil`.
    public let missingSchema: [String]

    /// Names from the expected set that aren't registered at all.
    public let missingRegistration: [String]

    /// `true` when either list is non-empty — the "nothing to report" check.
    public var hasIssues: Bool {
        !missingSchema.isEmpty || !missingRegistration.isEmpty
    }

    /// Human-readable description of the non-empty lists, or `nil` when
    /// the audit is clean. Intended for `fatalError` / debug-assertion
    /// messages so consumers don't have to hand-roll the same branching
    /// format string across projects.
    public var diagnosticMessage: String? {
        guard hasIssues else { return nil }
        var lines: [String] = []
        if !missingRegistration.isEmpty {
            lines.append("Tools not registered: \(missingRegistration.joined(separator: ", "))")
        }
        if !missingSchema.isEmpty {
            lines.append("Tools without output schemas: \(missingSchema.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    public init(missingSchema: [String], missingRegistration: [String]) {
        self.missingSchema = missingSchema
        self.missingRegistration = missingRegistration
    }
}

// MARK: - Internal Types

/// Unified storage for both DSL and closure-based tools.
struct ToolEntry {
    /// The kind of tool (DSL or closure).
    enum Kind {
        case dsl(any ToolSpec.Type)
        case closure(
            definition: Tool,
            handler: @Sendable ([String: Value]?, HandlerContext) async throws -> CallTool.Result,
        )
    }

    let kind: Kind
    var enabled: Bool = true

    /// The tool definition for listings.
    var definition: Tool {
        switch kind {
            case let .dsl(toolType):
                toolType.toolDefinition
            case let .closure(definition, _):
                definition
        }
    }
}

// MARK: - Result Builder

/// A result builder for collecting tool types.
///
/// Example:
/// ```swift
/// let registry = ToolRegistry {
///     GetWeather.self
///     CreateEvent.self
///     if includeDelete {
///         DeleteEvent.self
///     }
/// }
/// ```
@resultBuilder
public struct ToolBuilder {
    public static func buildBlock(_ tools: [any ToolSpec.Type]...) -> [any ToolSpec.Type] {
        tools.flatMap { $0 }
    }

    public static func buildOptional(_ tool: [any ToolSpec.Type]?) -> [any ToolSpec.Type] {
        tool ?? []
    }

    public static func buildEither(first tool: [any ToolSpec.Type]) -> [any ToolSpec.Type] {
        tool
    }

    public static func buildEither(second tool: [any ToolSpec.Type]) -> [any ToolSpec.Type] {
        tool
    }

    public static func buildArray(_ tools: [[any ToolSpec.Type]]) -> [any ToolSpec.Type] {
        tools.flatMap { $0 }
    }

    public static func buildExpression(_ tool: any ToolSpec.Type) -> [any ToolSpec.Type] {
        [tool]
    }
}
