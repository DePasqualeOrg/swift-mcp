/// A registered tool providing enable/disable/remove operations.
///
/// This is a lightweight, immutable struct that routes all mutations through
/// the `ToolRegistry` actor. It's naturally `Sendable` without requiring locks.
///
/// Both DSL tools (defined with `@Tool` macro) and closure-based tools (dynamic
/// registration) return this type, providing consistent lifecycle management.
///
/// Example:
/// ```swift
/// // DSL tool
/// let tool = try await server.register(GetWeather.self)
/// await tool.disable()  // Temporarily hide from listings
///
/// // Closure tool
/// let echool = try await server.register(name: "echo", ...) { args, ctx in
///     args.message
/// }
/// await echool.remove()  // Permanently remove
/// ```
public struct RegisteredTool: Sendable {
    /// The tool name.
    public let name: String

    /// Reference to the registry for mutations.
    private let registry: ToolRegistry

    /// Optional callback to notify when the tool list changes.
    private let onListChanged: (@Sendable () async -> Void)?

    init(name: String, registry: ToolRegistry, onListChanged: (@Sendable () async -> Void)? = nil) {
        self.name = name
        self.registry = registry
        self.onListChanged = onListChanged
    }

    /// Whether the tool is currently enabled.
    public var isEnabled: Bool {
        get async { await registry.isToolEnabled(name) }
    }

    /// The tool definition.
    public var definition: Tool? {
        get async { await registry.toolDefinition(for: name) }
    }

    /// Enables the tool.
    public func enable() async {
        await registry.enableTool(name)
        await onListChanged?()
    }

    /// Disables the tool (excluded from listings, calls rejected).
    public func disable() async {
        await registry.disableTool(name)
        await onListChanged?()
    }

    /// Removes the tool from the registry.
    public func remove() async {
        await registry.removeTool(name)
        await onListChanged?()
    }
}
