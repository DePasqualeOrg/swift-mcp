// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Foundation

/// The Model Context Protocol (MCP) allows servers to expose tools
/// that can be invoked by language models.
/// Tools enable models to interact with external systems, such as
/// querying databases, calling APIs, or performing computations.
/// Each tool is uniquely identified by a name and includes metadata
/// describing its schema.
///
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/
public struct Tool: Hashable, Codable, Sendable {
    /// The tool name (intended for programmatic or logical use)
    public let name: String
    /// A human-readable title for the tool, intended for UI display.
    /// If not provided, the `annotations.title` or `name` should be used for display.
    public let title: String?
    /// The tool description
    public let description: String?
    /// The tool input schema
    public let inputSchema: Value
    /// An optional JSON Schema object defining the structure of the tool's output
    /// returned in the `structuredContent` field of a `CallTool.Result`.
    public let outputSchema: Value?

    /// Reserved for clients and servers to attach additional metadata.
    public var _meta: [String: Value]?

    /// Optional icons representing this tool.
    public var icons: [Icon]?

    /// Execution-related properties for a tool.
    public struct Execution: Hashable, Codable, Sendable {
        /// The tool's preference for task-augmented execution.
        public enum TaskSupport: String, Hashable, Codable, Sendable {
            /// Clients MUST invoke the tool as a task
            case required
            /// Clients MAY invoke the tool as a task or normal request
            case optional
            /// Clients MUST NOT attempt to invoke the tool as a task (default)
            case forbidden
        }

        /// Indicates the tool's preference for task-augmented execution.
        /// If not present, defaults to "forbidden".
        public var taskSupport: TaskSupport?

        public init(taskSupport: TaskSupport? = nil) {
            self.taskSupport = taskSupport
        }
    }

    /// Execution-related properties for the tool.
    public var execution: Execution?

    /// Annotations that provide display-facing and operational information for a Tool.
    ///
    /// - Note: All properties in `ToolAnnotations` are **hints**.
    ///         They are not guaranteed to provide a faithful description of
    ///         tool behavior (including descriptive properties like `title`).
    ///
    ///         Clients should never make tool use decisions based on `ToolAnnotations`
    ///         received from untrusted servers.
    public struct Annotations: Hashable, Codable, Sendable, ExpressibleByNilLiteral {
        /// A human-readable title for the tool
        public var title: String?

        /// If true, the tool may perform destructive updates to its environment.
        /// If false, the tool performs only additive updates.
        /// (This property is meaningful only when `readOnlyHint == false`)
        ///
        /// When unspecified, the implicit default is `true`.
        public var destructiveHint: Bool?

        /// If true, calling the tool repeatedly with the same arguments
        /// will have no additional effect on its environment.
        /// (This property is meaningful only when `readOnlyHint == false`)
        ///
        /// When unspecified, the implicit default is `false`.
        public var idempotentHint: Bool?

        /// If true, this tool may interact with an "open world" of external
        /// entities. If false, the tool's domain of interaction is closed.
        /// For example, the world of a web search tool is open, whereas that
        /// of a memory tool is not.
        ///
        /// When unspecified, the implicit default is `true`.
        public var openWorldHint: Bool?

        /// If true, the tool does not modify its environment.
        ///
        /// When unspecified, the implicit default is `false`.
        public var readOnlyHint: Bool?

        /// Returns true if all properties are nil
        public var isEmpty: Bool {
            title == nil && readOnlyHint == nil && destructiveHint == nil && idempotentHint == nil
                && openWorldHint == nil
        }

        public init(
            title: String? = nil,
            readOnlyHint: Bool? = nil,
            destructiveHint: Bool? = nil,
            idempotentHint: Bool? = nil,
            openWorldHint: Bool? = nil,
        ) {
            self.title = title
            self.readOnlyHint = readOnlyHint
            self.destructiveHint = destructiveHint
            self.idempotentHint = idempotentHint
            self.openWorldHint = openWorldHint
        }

        /// Initialize an empty annotations object
        public init(nilLiteral _: ()) {}
    }

    /// Annotations that provide display-facing and operational information
    public var annotations: Annotations

    /// Initialize a tool with a name, description, input schema, and annotations
    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: Value,
        outputSchema: Value? = nil,
        _meta: [String: Value]? = nil,
        icons: [Icon]? = nil,
        execution: Execution? = nil,
        annotations: Annotations = nil,
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self._meta = _meta
        self.icons = icons
        self.execution = execution
        self.annotations = annotations
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case inputSchema
        case outputSchema
        case _meta
        case icons
        case execution
        case annotations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decode(Value.self, forKey: .inputSchema)
        outputSchema = try container.decodeIfPresent(Value.self, forKey: .outputSchema)
        _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
        icons = try container.decodeIfPresent([Icon].self, forKey: .icons)
        execution = try container.decodeIfPresent(Tool.Execution.self, forKey: .execution)
        annotations =
            try container.decodeIfPresent(Tool.Annotations.self, forKey: .annotations) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(outputSchema, forKey: .outputSchema)
        try container.encodeIfPresent(_meta, forKey: ._meta)
        try container.encodeIfPresent(icons, forKey: .icons)
        try container.encodeIfPresent(execution, forKey: .execution)
        if !annotations.isEmpty {
            try container.encode(annotations, forKey: .annotations)
        }
    }
}

// MARK: -

/// To discover available tools, clients send a `tools/list` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#listing-tools
public enum ListTools: Method {
    public static let name = "tools/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?
        /// Request metadata including progress token.
        public let _meta: RequestMeta?

        public init() {
            cursor = nil
            _meta = nil
        }

        public init(cursor: String? = nil, _meta: RequestMeta? = nil) {
            self.cursor = cursor
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let tools: [Tool]
        public let nextCursor: String?
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            tools: [Tool],
            nextCursor: String? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil,
        ) {
            self.tools = tools
            self.nextCursor = nextCursor
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case tools, nextCursor, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tools = try container.decode([Tool].self, forKey: .tools)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tools, forKey: .tools)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// To call a tool, clients send a `tools/call` request.
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#calling-tools
public enum CallTool: Method {
    public static let name = "tools/call"

    public struct Parameters: Hashable, Codable, Sendable {
        public let name: String
        /// The arguments to pass to the tool.
        /// When using `MCPServer`, arguments are automatically validated
        /// against the tool's `inputSchema` before the handler is called.
        public let arguments: [String: Value]?
        /// Task metadata for task-augmented requests.
        /// When present, the request becomes task-augmented and returns a `CreateTaskResult`
        /// instead of a normal result.
        public let task: TaskMetadata?
        /// Request metadata including progress token.
        public let _meta: RequestMeta?

        public init(
            name: String,
            arguments: [String: Value]? = nil,
            task: TaskMetadata? = nil,
            _meta: RequestMeta? = nil,
        ) {
            self.name = name
            self.arguments = arguments
            self.task = task
            self._meta = _meta
        }
    }

    /// On-the-wire shape of a tool result.
    ///
    /// `CallTool.Result` is the transport representation of a tool
    /// invocation's response and the return type of `ToolOutput.toCallToolResult()`.
    /// It is **not** a built-in tool return type – tool authors should return
    /// a value (primitive, array, optional, dictionary, `Void`, or
    /// `@Schemable @StructuredOutput` struct), `Media` /
    /// `MediaWithMetadata<T>`, or `Asset` / `AssetWithMetadata<T>` instead.
    /// Conform a custom type to `ToolOutput` when none of the built-in
    /// categories (Value, Media, Asset) fits and produce a
    /// `CallTool.Result` from there; constructing this type directly at a
    /// tool-body site bypasses the typed-return surface on purpose.
    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        /// A list of content objects that represent the unstructured result of the tool call.
        public let content: [ContentBlock]
        /// An optional JSON object that represents the structured result of the tool call.
        /// If the tool defined an `outputSchema`, this should conform to that schema.
        /// When using `MCPServer`, this is automatically validated against
        /// the tool's `outputSchema` after the handler returns.
        public let structuredContent: Value?
        /// Whether the tool call ended in an error.
        public let isError: Bool?
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            content: [ContentBlock],
            structuredContent: Value? = nil,
            isError: Bool? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil,
        ) {
            self.content = content
            self.structuredContent = structuredContent
            self.isError = isError
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case content, structuredContent, isError, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decode([ContentBlock].self, forKey: .content)
            structuredContent = try container.decodeIfPresent(Value.self, forKey: .structuredContent)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(structuredContent, forKey: .structuredContent)
            try container.encodeIfPresent(isError, forKey: .isError)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// When the list of available tools changes, servers that declared the listChanged capability SHOULD send a notification:
/// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/tools/#list-changed-notification
public struct ToolListChangedNotification: Notification {
    public static let name: String = "notifications/tools/list_changed"

    public typealias Parameters = NotificationParams

    public init() {}
}
