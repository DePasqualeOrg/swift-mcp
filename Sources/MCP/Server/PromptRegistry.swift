import Foundation

// MARK: - PromptOutput Protocol

/// Types that can be returned from a prompt handler.
///
/// Conforming types can be automatically converted to `GetPrompt.Result`.
/// Built-in conformances include `String`, `Prompt.Message`, and `[Prompt.Message]`.
public protocol PromptOutput: Sendable {
    /// Converts to GetPrompt.Result.
    func toGetPromptResult(description: String?) -> GetPrompt.Result
}

extension String: PromptOutput {
    public func toGetPromptResult(description: String?) -> GetPrompt.Result {
        GetPrompt.Result(
            description: description,
            messages: [.user(.text(self))]
        )
    }
}

extension Prompt.Message: PromptOutput {
    public func toGetPromptResult(description: String?) -> GetPrompt.Result {
        GetPrompt.Result(description: description, messages: [self])
    }
}

extension [Prompt.Message]: PromptOutput {
    public func toGetPromptResult(description: String?) -> GetPrompt.Result {
        GetPrompt.Result(description: description, messages: self)
    }
}

// MARK: - PromptRegistry Actor

/// Registry for managing prompts.
///
/// Supports two types of prompt registration:
/// - **DSL prompts**: Using `@Prompt` macro for compile-time type safety
/// - **Closure prompts**: Using explicit arguments for runtime-discovered prompts
public actor PromptRegistry {
    /// Internal storage for prompts.
    struct PromptEntry: Sendable {
        /// The kind of prompt registration.
        enum Kind: Sendable {
            /// A DSL-based prompt using @Prompt macro.
            case dsl(any PromptSpec.Type)
            /// A closure-based prompt with explicit handler.
            case closure(handler: @Sendable ([String: String]?, HandlerContext) async throws -> [Prompt.Message])
        }

        var kind: Kind
        var definition: Prompt
        var isEnabled: Bool
    }

    /// Registered prompts keyed by name.
    private var prompts: [String: PromptEntry] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Creates a registry with prompts from a result builder.
    ///
    /// Example:
    /// ```swift
    /// let registry = PromptRegistry {
    ///     InterviewPrompt.self
    ///     CodeReviewPrompt.self
    /// }
    /// ```
    public init(@PromptBuilder prompts: () -> [any PromptSpec.Type]) {
        let promptList = prompts()
        self.prompts = Dictionary(uniqueKeysWithValues: promptList.map {
            ($0.promptDefinition.name, PromptEntry(kind: .dsl($0), definition: $0.promptDefinition, isEnabled: true))
        })
    }

    // MARK: - DSL Registration

    /// Registers a DSL-based prompt type.
    ///
    /// Use this for prompts defined with the `@Prompt` macro.
    ///
    /// - Parameters:
    ///   - prompt: The prompt type to register.
    ///   - onListChanged: Optional callback for list change notifications.
    /// - Returns: A `RegisteredPrompt` for managing the prompt.
    /// - Throws: `MCPError.invalidParams` if a prompt with the same name already exists.
    @discardableResult
    public func register<T: PromptSpec>(
        _ prompt: T.Type,
        onListChanged: (@Sendable () async -> Void)? = nil
    ) throws -> RegisteredPrompt {
        let definition = T.promptDefinition
        let name = definition.name

        guard prompts[name] == nil else {
            throw MCPError.invalidParams("Prompt '\(name)' is already registered")
        }

        prompts[name] = PromptEntry(
            kind: .dsl(prompt),
            definition: definition,
            isEnabled: true
        )

        return RegisteredPrompt(name: name, registry: self, onListChanged: onListChanged)
    }

    // MARK: - Closure Registration

    /// Registers a closure-based prompt with explicit arguments.
    ///
    /// Use this for prompts discovered or generated at runtime:
    /// - Prompts loaded from configuration files
    /// - Prompts generated from templates
    /// - Plugin-provided prompts
    ///
    /// For compile-time known prompts, use the `@Prompt` macro instead.
    ///
    /// - Parameters:
    ///   - name: The prompt name.
    ///   - title: Optional display title.
    ///   - description: Optional description.
    ///   - arguments: The prompt arguments.
    ///   - onListChanged: Optional callback for list change notifications.
    ///   - handler: The handler to render the prompt.
    /// - Returns: A `RegisteredPrompt` for managing the prompt.
    /// - Throws: `MCPError.invalidParams` if a prompt with the same name already exists.
    @discardableResult
    public func register(
        name: String,
        title: String? = nil,
        description: String? = nil,
        arguments: [Prompt.Argument]? = nil,
        onListChanged: (@Sendable () async -> Void)? = nil,
        handler: @escaping @Sendable ([String: String]?, HandlerContext) async throws -> [Prompt.Message]
    ) throws -> RegisteredPrompt {
        guard prompts[name] == nil else {
            throw MCPError.invalidParams("Prompt '\(name)' is already registered")
        }

        let definition = Prompt(
            name: name,
            title: title,
            description: description,
            arguments: arguments
        )

        prompts[name] = PromptEntry(
            kind: .closure(handler: handler),
            definition: definition,
            isEnabled: true
        )

        return RegisteredPrompt(name: name, registry: self, onListChanged: onListChanged)
    }

    // MARK: - Lookup

    /// Lists all enabled prompts.
    public func listPrompts() -> [Prompt] {
        prompts.values
            .filter { $0.isEnabled }
            .map { $0.definition }
    }

    /// Gets and renders a prompt.
    ///
    /// - Parameters:
    ///   - name: The prompt name.
    ///   - arguments: Arguments to pass to the prompt.
    ///   - context: Handler context for logging, progress, etc.
    /// - Returns: The rendered prompt result.
    /// - Throws: `MCPError.invalidParams` if the prompt doesn't exist or is disabled.
    public func getPrompt(
        _ name: String,
        arguments: [String: String]?,
        context: HandlerContext
    ) async throws -> GetPrompt.Result {
        guard let entry = prompts[name] else {
            throw MCPError.invalidParams("Unknown prompt: \(name)")
        }

        guard entry.isEnabled else {
            throw MCPError.invalidParams("Prompt '\(name)' is disabled")
        }

        switch entry.kind {
            case let .dsl(promptType):
                let instance = try promptType.parse(from: arguments)
                let output = try await instance.render(context: context)
                return output.toGetPromptResult(description: entry.definition.description)

            case let .closure(handler):
                let messages = try await handler(arguments, context)
                return GetPrompt.Result(description: entry.definition.description, messages: messages)
        }
    }

    /// Checks if a prompt exists.
    public func hasPrompt(_ name: String) -> Bool {
        prompts[name] != nil
    }

    // MARK: - Management (Internal)

    func isPromptEnabled(_ name: String) -> Bool {
        prompts[name]?.isEnabled ?? false
    }

    func promptDefinition(for name: String) -> Prompt? {
        prompts[name]?.definition
    }

    func enablePrompt(_ name: String) {
        prompts[name]?.isEnabled = true
    }

    func disablePrompt(_ name: String) {
        prompts[name]?.isEnabled = false
    }

    func removePrompt(_ name: String) {
        prompts.removeValue(forKey: name)
    }
}

// MARK: - RegisteredPrompt

/// A registered prompt providing enable/disable/remove operations.
///
/// This struct routes all operations through the PromptRegistry actor,
/// ensuring thread safety without requiring `@unchecked Sendable`.
public struct RegisteredPrompt: Sendable {
    /// The prompt name.
    public let name: String

    /// Reference to the registry for mutations.
    private let registry: PromptRegistry

    /// Optional callback to notify when the prompt list changes.
    private let onListChanged: (@Sendable () async -> Void)?

    init(name: String, registry: PromptRegistry, onListChanged: (@Sendable () async -> Void)? = nil) {
        self.name = name
        self.registry = registry
        self.onListChanged = onListChanged
    }

    /// Whether the prompt is currently enabled.
    public var isEnabled: Bool {
        get async { await registry.isPromptEnabled(name) }
    }

    /// The prompt definition.
    public var definition: Prompt? {
        get async { await registry.promptDefinition(for: name) }
    }

    /// Enables the prompt.
    public func enable() async {
        await registry.enablePrompt(name)
        await onListChanged?()
    }

    /// Disables the prompt.
    public func disable() async {
        await registry.disablePrompt(name)
        await onListChanged?()
    }

    /// Removes the prompt from the registry.
    public func remove() async {
        await registry.removePrompt(name)
        await onListChanged?()
    }
}
